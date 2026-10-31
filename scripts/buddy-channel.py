#!/usr/bin/env python3
"""BuddyOS の Claude Code channel サーバ（MCP stdio）。

ターミナルで動いている Claude Code に、iPhone（BuddyOS）から送ったメッセージを届ける。
Claude Code がこのスクリプトを MCP サーバとして起動し、`claude/channel` を宣言すると、
`notifications/claude/channel` で送った内容が <channel source="buddy"> としてセッションに入る
（待機中なら即ターン開始、応答中なら次のターンに回る）。

受信は Bridge（127.0.0.1）への long-poll。依存は標準ライブラリのみ。
channel は `claude --dangerously-load-development-channels server:buddy`（= buddy-claude）で
起動したときだけ有効。フラグ無しで起動された場合は poll しない（Bridge が「送信不可」と判断できる）。

許可の中継（`claude/channel/permission`）も受ける。ターミナルに許可確認が出ると
`notifications/claude/channel/permission_request` が届くので Bridge に知らせ（iPhone にカードが出る）、
iPhone で選んだ答えを poll の permissions で受けて `notifications/claude/channel/permission` で返す。
ターミナルの選択肢はそのまま出ていて、先に答えた方が効く（Claude Code 2.1.285 で実測）。
"""
import json, os, subprocess, sys, threading, time, urllib.parse, urllib.request

HOME = os.path.expanduser("~")
SESSION_ID = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
# claude 本体（= 親プロセス）が書く pid ファイル。/clear や /resume で sessionId が書き直される。
PID_FILE = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or f"{HOME}/.claude", "sessions", f"{os.getppid()}.json")
write_lock = threading.Lock()
generation = 0  # poll の世代。session が切り替わるたびに進め、古い session の poll_loop を抜けさせる
current_sid = SESSION_ID  # 今の session（/clear・/resume で変わる）。許可の依頼をどの session として知らせるか


def log(msg):
    sys.stderr.write(f"[buddy-channel] {msg}\n"); sys.stderr.flush()


def send(obj):
    line = json.dumps(obj, ensure_ascii=False)
    with write_lock:
        sys.stdout.write(line + "\n"); sys.stdout.flush()


def read_text(path, default=""):
    try:
        with open(path) as f: return f.read().strip()
    except OSError:
        return default


def current_session(default):
    """親 claude の今の session_id。/clear や /resume で session_id は変わるが、MCP サーバは
    再起動されず環境変数も起動時のままなので、pid ファイルから読み直す。読めなければ default。"""
    try:
        with open(PID_FILE) as f:
            sid = json.load(f).get("sessionId")
    except (OSError, ValueError, AttributeError):
        return default
    return sid if isinstance(sid, str) and sid else default


def bridge_url(path):
    """動いている Bridge の URL。bridge.port が無い、または bridge.pid のプロセス（自分のもの）が
    その番号で待ち受けていなければ None（何も送らない）。決め打ちの 8765 には送らない
    （Bridge が止まっている間にその番号を先に取った別のプロセスへ鍵と会話が渡る）。"""
    port = os.environ.get("BUDDYOS_BRIDGE_PORT") or read_text(f"{HOME}/.buddyos/bridge.port")
    pid = read_text(f"{HOME}/.buddyos/bridge.pid")
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
    return f"http://127.0.0.1:{port}{path}" if pid in out.split() else None


def report_permission(params):
    """許可の依頼を Bridge に知らせる（iPhone / デスクトップにカードが出る）。失敗してもターミナルでは選べる。"""
    body = dict(params or {}, session=current_session(current_sid))
    url = bridge_url("/claude/channel/permission")
    if not url:
        log("permission report skipped: bridge not running")
        return
    try:
        req = urllib.request.Request(
            url, data=json.dumps(body).encode(), method="POST",
            headers={"Authorization": f"Bearer {read_text(f'{HOME}/.buddyos/api-key')}",
                     "Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=5).read()
        log(f"permission request {body.get('request_id')} -> bridge")
    except Exception as e:
        log(f"permission report failed: {e}")


def channel_enabled():
    """親（claude 本体）が channel フラグ付きで起動されたか。"""
    try:
        args = subprocess.run(["ps", "-o", "args=", "-p", str(os.getppid())],
                              capture_output=True, text=True, timeout=3).stdout
    except Exception:
        return False
    return "--dangerously-load-development-channels" in args or "--channels" in args


def poll_loop(sid, gen):
    """sid 宛ての long-poll。session が切り替わったら（generation が進んだら）今の poll を最後に抜ける
    （その poll で届いた分は捨てずに渡す）。"""
    query = "/claude/channel/poll?" + urllib.parse.urlencode({"session": sid})
    while generation == gen:
        # 毎回確かめる（Bridge の再起動で番号が変わる・止まっている間は送らない）
        url = bridge_url(query)
        if not url:
            time.sleep(3)
            continue
        key = read_text(f"{HOME}/.buddyos/api-key")
        started = time.monotonic()
        try:
            req = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}"})
            with urllib.request.urlopen(req, timeout=40) as r:
                body = json.loads(r.read() or b"{}")
            for text in body.get("messages", []):
                send({"jsonrpc": "2.0", "method": "notifications/claude/channel",
                      "params": {"content": text, "meta": {"sender": "iphone"}}})
                log(f"delivered {len(text)} chars")
            for p in body.get("permissions", []):
                send({"jsonrpc": "2.0", "method": "notifications/claude/channel/permission",
                      "params": {"request_id": p.get("request_id"), "behavior": p.get("behavior")}})
                log(f"permission {p.get('request_id')} -> {p.get('behavior')}")
            # SessionEnd(clear) の forget で空がすぐ返ったときは、新しい session_id が
            # pid ファイルに書かれて watch_session が張り替えるのを少し待つ（古い session に張り直し続けない）
            if not body.get("messages") and not body.get("permissions") and time.monotonic() - started < 5:
                time.sleep(1)
        except Exception as e:  # Bridge 再起動中など。少し待って続ける
            log(f"poll error: {e}")
            time.sleep(3)


def watch_session(sid):
    """pid ファイルを 1 秒おきに見て、session が切り替わったら（/clear・/resume）新しい sid で poll を張る。
    旧 sid の long-poll（最大 25 秒）が返るのは待たない（旧 sid の SessionEnd が Bridge に届かず台帳に
    残った場合でも、新しい session がすぐ送信可能になる）。"""
    global generation, current_sid
    current_sid = sid
    threading.Thread(target=poll_loop, args=(sid, generation), daemon=True).start()
    while True:
        time.sleep(1)
        cur = current_session(sid)
        if cur != sid:
            log(f"session switched {sid[:8]} -> {cur[:8]}")
            sid = cur
            current_sid = cur
            generation += 1
            threading.Thread(target=poll_loop, args=(sid, generation), daemon=True).start()


INSTRUCTIONS = (
    'Messages from the user\'s iPhone (BuddyOS app) arrive as <channel source="buddy" sender="iphone">. '
    "Treat them exactly like a prompt the user typed in this terminal. "
    "The user reads your normal output on the phone, so just answer normally — no reply tool is needed."
)


def main():
    polling = False
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        method, mid = msg.get("method"), msg.get("id")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "protocolVersion": msg.get("params", {}).get("protocolVersion", "2025-06-18"),
                "capabilities": {"tools": {}, "experimental": {"claude/channel": {}, "claude/channel/permission": {}}},
                "serverInfo": {"name": "buddy", "version": "0.1.0"},
                "instructions": INSTRUCTIONS,
            }})
        elif method == "notifications/initialized":
            if polling:
                continue
            sid = current_session(SESSION_ID)
            if not sid:
                log("CLAUDE_CODE_SESSION_ID が無いので受信しない")
            elif not channel_enabled():
                log("channel フラグ無しで起動されたので受信しない（buddy-claude で起動すると有効）")
            else:
                polling = True
                threading.Thread(target=watch_session, args=(sid,), daemon=True).start()
                log(f"listening session={sid[:8]}")
        elif method == "notifications/claude/channel/permission_request":
            # Bridge への POST は待たせない（stdin の読み取りを止めない）。
            threading.Thread(target=report_permission, args=(msg.get("params"),), daemon=True).start()
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": []}})
        elif method == "ping":
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"unknown method {method}"}})


if __name__ == "__main__":
    main()
