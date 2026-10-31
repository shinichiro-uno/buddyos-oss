#!/usr/bin/env python3
"""ターミナルの Claude Code セッションを BuddyOS Bridge の台帳に載せる。

2 通りで呼ばれる:
  - SessionStart hook（stdin に hook の JSON）: 起動・resume のたびに自動で登録
  - /buddy コマンド（--command）: すでに動いているセッションを後から登録

登録する内容は session_id / cwd / claude 本体の pid / cross-session messaging の受け箱
（CLAUDE_CODE_MESSAGING_SOCKET）。受け箱のトークンは送らない（Bridge からの投稿は
他セッションからのメッセージとして、受け手の承認ルールに従わせる）。

Bridge が起動した claude（BUDDYOS_SPAWNED=1）は登録しない。依存は標準ライブラリのみ。
"""
import json
import os
import subprocess
import sys
import urllib.request

HOME = os.path.expanduser("~")


def claude_pid():
    """親をたどって claude 本体の pid を探す（hook / ! コマンドは一時シェル経由で動く）。"""
    p = os.getppid()
    for _ in range(8):
        out = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(p)],
                             capture_output=True, text=True).stdout.split(None, 1)
        if len(out) < 2:
            return None
        if "claude" in os.path.basename(out[1].strip()):
            return p
        p = int(out[0])
    return None


def read_text(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def bridge_port():
    """動いている Bridge の待ち受け番号。buddy-hook.sh / buddy-channel.py と同じ決め方
    （env → bridge.port。ずれると SessionStart の登録先と他の hook の送り先が食い違う）。
    bridge.port が無い、または bridge.pid のプロセス（自分のもの）がその番号で待ち受けていなければ None。
    決め打ちの 8765 には送らない（Bridge が止まっている間にその番号を先に取った別のプロセスへ鍵と会話が渡る）。"""
    d = os.path.join(HOME, ".buddyos")
    port = os.environ.get("BUDDYOS_BRIDGE_PORT") or read_text(os.path.join(d, "bridge.port"))
    pid = read_text(os.path.join(d, "bridge.pid"))
    if not (port.isascii() and port.isdigit() and pid.isascii() and pid.isdigit()) or int(pid) <= 0:
        return None
    try:
        os.kill(int(pid), 0)   # 生きていて、自分が signal を送れる（= 同じユーザーの）プロセスか
    except OSError:
        return None
    try:
        out = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", pid, f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
                             capture_output=True, text=True, timeout=3).stdout
    except Exception:
        return None
    return port if pid in out.split() else None


def main():
    command_mode = "--command" in sys.argv
    if os.environ.get("BUDDYOS_SPAWNED") == "1":
        return 0

    data = {}
    if not command_mode:
        try:
            data = json.load(sys.stdin)
        except Exception:
            data = {}
    data.setdefault("session_id", os.environ.get("CLAUDE_CODE_SESSION_ID", ""))
    data.setdefault("cwd", os.getcwd())
    pid = claude_pid()
    if pid:
        data["pid"] = pid
    sock = os.environ.get("CLAUDE_CODE_MESSAGING_SOCKET")
    if sock:
        data["inbox_socket"] = sock

    if not data.get("session_id"):
        print("BuddyOS: session_id が取れませんでした")
        return 1

    try:
        with open(os.path.join(HOME, ".buddyos", "api-key")) as f:
            api_key = f.read().strip()
    except OSError:
        print("BuddyOS: ~/.buddyos/api-key がありません（Bridge を一度起動してください）")
        return 1
    port = bridge_port()
    if not port:
        # hook のときは何も出さない（SessionStart の出力は会話に入る）
        if command_mode:
            print("BuddyOS: Bridge が動いていません（BuddyOS を起動してから、もう一度試してください）")
        return 1

    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/claude/session-start",
        data=json.dumps(data).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"})
    try:
        urllib.request.urlopen(req, timeout=3).read()
    except Exception as e:
        if command_mode:
            print(f"BuddyOS: Bridge に繋がりませんでした（{e}）")
        return 1

    if command_mode:
        inbox = "iPhone から送れます" if sock else "閲覧のみ（受け箱が無いため送信不可）"
        print(f"BuddyOS: このセッション（{data['session_id'][:8]}…）を接続しました。{inbox}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
