#!/bin/bash
# ターミナルで開いた Claude Code セッションを BuddyOS に「見せる」ための hooks を
# ~/.claude/settings.json に追記する。既存の hooks は一切触らず、buddyos 用エントリだけを
# 追加・更新する（何度実行しても同じ結果になる）。
#
#   --dry-run   書き込まず、マージ後の JSON を表示する
#   --remove    buddyos 用エントリだけを取り除く
#
# 仕組み:
#   SessionStart は buddy-register.py（command hook）で Bridge に登録する。
#   それ以外も command hook の buddy-hook.sh が stdin の hook JSON を Bridge の /claude/hook へ POST する。
#   api-key とポートは hook の実行時に ~/.buddyos から読む（settings.json に鍵を書かない。
#   鍵の再生成や Bridge のポート変更にもそのまま追従する）。POST 先は 127.0.0.1 のみで、
#   bridge.pid の Bridge がその番号で待ち受けているときだけ送る（止まっている間は何も送らない）。
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
API_KEY_FILE="$HOME/.buddyos/api-key"
MODE="${1:-install}"

# SessionStart: buddy-register.py が stdin の hook JSON に claude 本体の pid と
# cross-session messaging の受け箱（CLAUDE_CODE_MESSAGING_SOCKET）を足して登録する。
# 同じスクリプトを /buddy コマンドからも呼ぶ（すでに動いているセッションを後から登録）。
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$HOME/.buddyos/bin"
REGISTER="$BIN/buddy-register.py"
HOOK="$BIN/buddy-hook.sh"
COMMAND_MD="$HOME/.claude/commands/buddy.md"
START_CMD="python3 '$REGISTER' 2>/dev/null || true"
HOOK_CMD="'$HOOK'"
# buddy.md が BuddyOS の書いたもの（buddy-register.py を呼ぶ）か、まだ無いか。同じ名前の自作のコマンドは
# 書き換えも削除もしない。
ours_md() { [ ! -e "$COMMAND_MD" ] || grep -q 'buddy-register.py' "$COMMAND_MD" 2>/dev/null; }
# /buddy-voice: いま動いているセッションのまま、アプリ内ターミナルのペインの音声会話に入る・出る
# （~/.buddyos/bin/buddy-voice はデスクトップが置く。docs/TERMINAL_VOICE_2026-10-19.md）。
VOICE_MD="$HOME/.claude/commands/buddy-voice.md"
VOICE_BIN="$BIN/buddy-voice"
ours_voice_md() { [ ! -e "$VOICE_MD" ] || grep -q 'buddy-voice --toggle' "$VOICE_MD" 2>/dev/null; }
# /buddy-team: ターミナルの AI が司会になり、ほかの AI の CLI を話し合いに呼ぶ（docs/BUDDY_TEAM_2026-10-20.md）。
# 手足は ~/.buddyos/bin/buddy-team.mjs（Node だけで動く）。Claude Code のコマンドと、Codex・agy・Grok・OpenCode の
# スキルは buddy-team.mjs install が置く（自作の同じ名前のものは触らない）。Node が無ければ入れない（どのみち動かない）。
TEAM_BIN="$BIN/buddy-team.mjs"
team_node() { PATH="$PATH:/opt/homebrew/bin:/usr/local/bin" command -v node; }

if [ "$MODE" = "--remove" ]; then
  # 取り除くだけなので api-key は要らない（~/.buddyos を消した後でも外せるように）
  rm -f "$REGISTER" "$HOOK"
  if ours_md; then rm -f "$COMMAND_MD"; else echo "注意: $COMMAND_MD は BuddyOS のものではないので残します" >&2; fi
  if ours_voice_md; then rm -f "$VOICE_MD"; fi
  if [ -f "$TEAM_BIN" ] && NODE="$(team_node)"; then "$NODE" "$TEAM_BIN" uninstall >/dev/null || true; fi
  rm -f "$TEAM_BIN"
elif [ "$MODE" != "--dry-run" ]; then
  [ -f "$API_KEY_FILE" ] || { echo "ABORT: $API_KEY_FILE がありません（Bridge を一度起動してください）"; exit 1; }
  mkdir -p "$BIN" "$(dirname "$COMMAND_MD")"
  cp "$REPO/scripts/buddy-register.py" "$REGISTER"
  chmod 755 "$REGISTER"
  # channel（buddy-claude 用。install-claude-channel.sh が置く）が入っていれば新しい版に入れ替える
  # （許可の中継に対応した版。古いままだと iPhone から許可確認に答えられない）。
  if [ -f "$BIN/buddy-channel.py" ] && [ -f "$REPO/scripts/buddy-channel.py" ]; then
    cp "$REPO/scripts/buddy-channel.py" "$BIN/buddy-channel.py"
    chmod 755 "$BIN/buddy-channel.py"
  fi
  # 行バッチごと・ツール実行ごとに発火するので python ではなく sh + curl で軽く送る。
  # stdout に何か出すと Claude Code が hook の出力として解釈するので、何も出さず常に exit 0。
  # 鍵は argv（ps から見える）に載せず、fd 3 のヘッダとして curl に渡す。
  cat > "$HOOK" <<'SH'
#!/bin/sh
# Claude Code の hook（stdin の JSON）を BuddyOS Bridge の $1（/claude/hook 等）へ転送する。
# install-claude-hooks.sh が生成。Bridge が起動した claude（BUDDYOS_SPAWNED=1）は送らない。
[ "${BUDDYOS_SPAWNED:-}" = 1 ] && exit 0
D="$HOME/.buddyos"
# 送り先は動いている Bridge だけ。bridge.port が無い、または bridge.pid のプロセス（自分のもの）が
# その番号で待ち受けていなければ何も送らない（決め打ちの 8765 に送ると、Bridge が止まっている間に
# その番号を先に取った別のプロセスへ鍵と会話が渡る）。
PORT="${BUDDYOS_BRIDGE_PORT:-$(cat "$D/bridge.port" 2>/dev/null)}"
PID="$(cat "$D/bridge.pid" 2>/dev/null)"
case "$PORT" in ''|*[!0-9]*) exit 0 ;; esac
case "$PID" in ''|*[!0-9]*|0*) exit 0 ;; esac
kill -0 "$PID" 2>/dev/null || exit 0
/usr/sbin/lsof -nP -a -p "$PID" -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | grep -qx "$PID" || exit 0
KEY="$(cat "$D/api-key" 2>/dev/null)" || exit 0
P="$1"
# BuddyOS のアプリ内ターミナルの中なら、どのペインかを名乗る（タブの「作業中・終わった」の印に使う）。
if [ -n "${BUDDYOS_PANE_ID:-}" ]; then set -- -H "X-BuddyOS-Pane: $BUDDYOS_PANE_ID"; else set --; fi
curl -s -o /dev/null -m 3 -H 'Content-Type: application/json' -H @/dev/fd/3 "$@" \
  --data-binary @- "http://127.0.0.1:$PORT$P" >/dev/null 2>&1 3<<EOF
Authorization: Bearer $KEY
EOF
exit 0
SH
  chmod 755 "$HOOK"
  if ! ours_md; then
    echo "注意: $COMMAND_MD は BuddyOS のものではないので書き換えません（/buddy での接続は使えません）" >&2
  else
  cat > "$COMMAND_MD" <<MD
---
description: このセッションを BuddyOS（iPhone）に接続する
allowed-tools: Bash(python3 $REGISTER:*)
---
!\`python3 $REGISTER --command\`

上の BuddyOS の結果を 1 行でそのまま伝えてください。それ以外の作業はしないでください。
MD
  echo "installed: $COMMAND_MD"
  fi
  if ours_voice_md; then
  cat > "$VOICE_MD" <<MD
---
description: このペインの音声会話に入る / 出る（BuddyOS のアプリ内ターミナル）
allowed-tools: Bash($VOICE_BIN --toggle:*)
---
!\`$VOICE_BIN --toggle\`

上の buddy-voice の結果を 1 行でそのまま伝えてください。それ以外の作業はしないでください。
MD
  echo "installed: $VOICE_MD"
  fi
  if NODE="$(team_node)"; then
    "$NODE" "$REPO/scripts/buddy-team.mjs" install || echo "注意: buddy-team を入れられませんでした" >&2
  fi
fi

python3 - "$SETTINGS" "$MODE" "$START_CMD" "$HOOK_CMD" <<'PY'
import glob, json, re, sys, os, time
settings_path, mode, start_cmd, hook_cmd = sys.argv[1:5]
MARK = "buddyos"   # 自分のエントリを見分ける印（hooks[].__buddyos__ / command 内の識別子）

def cmd_hook(cmd):
    return {"type": "command", "command": cmd, "timeout": 5, "__buddyos__": True}

def fwd_hook(path):
    return cmd_hook(f"{hook_cmd} {path} 2>/dev/null || true")

def is_ours(h):
    # 旧版の http hook（url に /claude/hook 等）も引き続き自分のものとして取り除く
    if h.get("__buddyos__"): return True
    u = h.get("url", ""); c = h.get("command", "")
    return ("/claude/hook" in u or "/claude/session-end" in u
            or "/claude/session-start" in c or "buddy-register.py" in c or "buddy-hook.sh" in c)

KEY_RE = re.compile(r"Bearer [A-Za-z0-9\-._~+/]+=*")

def strip_key(d):
    # 旧版は api-key を http hook の headers と SessionStart の command に平文で書いていた。
    # d（settings の JSON）の自分のエントリからそれを取り除き、取り除いたかを返す
    found = False
    for groups in (d.get("hooks") or {}).values():
        for g in groups or []:
            for h in g.get("hooks", []):
                if not is_ours(h): continue
                hd = h.get("headers")
                if isinstance(hd, dict) and "Authorization" in hd:
                    del hd["Authorization"]; found = True
                c = h.get("command", "")
                if KEY_RE.search(c):
                    h["command"] = KEY_RE.sub("Bearer <removed>", c); found = True
    return found

wanted = {
    "SessionStart":       cmd_hook(start_cmd),
    "UserPromptSubmit":   fwd_hook("/claude/hook"),
    "MessageDisplay":     fwd_hook("/claude/hook"),
    "PreToolUse":         fwd_hook("/claude/hook"),
    "PostToolUse":        fwd_hook("/claude/hook"),
    "PostToolUseFailure": fwd_hook("/claude/hook"),
    "SubagentStart":      fwd_hook("/claude/hook"),   # サブエージェントの開始（agent_id / agent_type）
    "SubagentStop":       fwd_hook("/claude/hook"),   # サブエージェントの終了（last_assistant_message）
    "Stop":               fwd_hook("/claude/hook"),
    "StopFailure":        fwd_hook("/claude/hook"),   # API エラーで終わったターン（Stop は来ない）
    # ターミナルに選択肢（許可確認・AskUserQuestion・計画の承認）が出た。iPhone / デスクトップにカードを出す。
    # buddy-hook.sh は何も出力しないので、ターミナルの選択肢はそのまま出る（先に答えた方が効く）。
    "PermissionRequest":  fwd_hook("/claude/hook"),
    "Notification":       fwd_hook("/claude/hook"),
    "SessionEnd":        fwd_hook("/claude/session-end"),
}

data, raw = {}, None
if os.path.exists(settings_path):
    with open(settings_path, "rb") as f: raw = f.read()
    data = json.loads(raw)
hooks = data.setdefault("hooks", {})

# 1) 自分のエントリを全イベントから取り除く（冪等化）
for ev, groups in list(hooks.items()):
    kept = []
    for g in groups or []:
        g["hooks"] = [h for h in g.get("hooks", []) if not is_ours(h)]
        if g["hooks"]: kept.append(g)
    if kept: hooks[ev] = kept
    else: hooks.pop(ev, None)

# 2) install なら足す（matcher 無しのグループを 1 つ追加。他人のグループには触らない）
if mode != "--remove":
    for ev, h in wanted.items():
        hooks.setdefault(ev, []).append({"hooks": [h]})

out = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
if mode == "--dry-run":
    print(out); sys.exit(0)

# 旧版は api-key を settings.json に平文で書いていた。過去のバックアップは本人だけが読めるようにし、
# 鍵が残っているものを一覧する（消すかどうかは本人が決める）。失敗しても hooks の更新は止めない
leaked = []
for bak in sorted(glob.glob(glob.escape(settings_path) + ".bak-*")):
    if os.path.islink(bak) or not os.path.isfile(bak): continue   # リンク先（別のファイル）の権限は変えない
    try: os.chmod(bak, 0o600)
    except OSError as e: print(f"警告: {bak} を 0600 にできません（{e}）", file=sys.stderr)
    try:
        with open(bak, "rb") as f:
            if strip_key(json.load(f)): leaked.append(bak)
    except Exception: pass   # 読めない・形の違うものは判定しない
orig = json.loads(raw) if raw is not None else None
migrated = orig is not None and strip_key(orig)
if leaked or migrated:
    print("警告: 旧版は api-key を settings.json に平文で書いていました。"
          + ("settings.json からは取り除きます（今回のバックアップにも残しません）。" if migrated else ""), file=sys.stderr)
    if leaked:
        print("  鍵が残っている過去のバックアップ（不要なら削除してください）:", file=sys.stderr)
        for p in leaked: print("    " + p, file=sys.stderr)
    print("  ~/.claude を dotfiles や同期ツールで持ち出していたなら、鍵も作り直してください"
          "（~/.buddyos/api-key を消して Bridge を再起動。iPhone は再ペアリングが要る場合あり）", file=sys.stderr)
if mode == "--remove" and raw is None:
    print("removed buddyos hooks →", settings_path, "(なし)"); sys.exit(0)

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
if raw is not None:
    # バックアップは最初から 0600 で作る。旧版の鍵は取り除いた形で残す（それ以外は元のバイト列のまま）
    bak = settings_path + f".bak-{time.strftime('%Y%m%d-%H%M%S')}"
    fd = os.open(bak, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write((json.dumps(orig, ensure_ascii=False, indent=2) + "\n").encode() if migrated else raw)
# 書きかけで止まっても settings.json が壊れないよう、同じフォルダの一時ファイルに書いてから置き換える
# （dotfiles のリンクはリンクのまま、リンク先を置き換える。権限も元のまま）
target = os.path.realpath(settings_path)
perm = (os.stat(target).st_mode & 0o777) if os.path.exists(target) else 0o644
tmp = f"{target}.{os.getpid()}.tmp"
try:
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, perm), "w") as f:
        f.write(out); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp, perm)
    os.replace(tmp, target)
except BaseException:
    try: os.unlink(tmp)
    except OSError: pass
    raise
print(("removed" if mode == "--remove" else "installed"), "buddyos hooks →", settings_path)
print("events:", ", ".join(k for k in hooks if any(is_ours(h) for g in hooks[k] for h in g.get("hooks", []))) or "(none)")
PY
