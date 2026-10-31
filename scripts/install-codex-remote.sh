#!/bin/bash
# iPhone（BuddyOS）とターミナルの Codex で同じ会話を共有できるようにする。
#
# `buddy-codex` を ~/.local/bin に置く。中身は「共有 app-server（127.0.0.1:47620）が
# 動いていなければ起動し、`codex --remote` でそこへ繋ぐ」だけ。Bridge も同じ app-server に
# 繋ぐので、どちらから送っても両方にリアルタイムで流れる（mac-bridge の CodexSharedAppServer）。
#
# 以後はターミナルで `codex` の代わりに `buddy-codex` を使う（引数はそのまま渡る）。
#   buddy-codex                 新しい会話
#   buddy-codex resume <ID>     続きから
#   --remove  で buddy-codex を取り除く
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WRAP="$HOME/.local/bin/buddy-codex"
PROXY="$HOME/.buddyos/bin/buddy-codex-proxy.mjs"

if [ "${1:-}" = "--remove" ]; then
  rm -f "$WRAP" "$PROXY"
  echo "removed $WRAP"; exit 0
fi

mkdir -p "$(dirname "$WRAP")" "$(dirname "$PROXY")"
cp "$REPO/scripts/buddy-codex-proxy.mjs" "$PROXY"
cat > "$WRAP" <<'W'
#!/bin/bash
# Codex を BuddyOS と共有する app-server に繋いで起動する（iPhone から見る・送るができる）。
set -u
PORT=47620
TOKEN_FILE="$HOME/.buddyos/codex-app-server.token"
LOG="$HOME/.buddyos/codex-app-server.log"
MCP_TOKENS="$HOME/.buddyos/mcp-tokens.json"
VAULT="$HOME/.buddyos/codex-app-server.vault.json"

ready() { curl -s -m 1 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/readyz" 2>/dev/null | grep -q 200; }
# $PORT を待ち受けているのが pid $1 の app-server か（npm 版の codex は node ラッパーで、待ち受けるのはその子の本体）。
listening_is() {
  local p
  for p in $(/usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null); do
    [ "$p" = "$1" ] && return 0
    [ "$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')" = "$1" ] && return 0
  done
  return 1
}
# $PORT を待ち受けているのが、すべて自分の uid の app-server か。固定ポートなので、別のユーザーやアプリが
# 先に待ち受けていると、トークンと会話が偽のサーバーに渡る（/readyz は誰でも 200 を返せる）。
own_listener() {
  local me line pid uid found=1
  me="$(id -u)"
  pid=""
  while IFS= read -r line; do
    case "$line" in
      p*) pid="${line#p}" ;;
      u*) uid="${line#u}"
          [ "$uid" = "$me" ] || return 1
          case "$(ps -o command= -p "$pid" 2>/dev/null)" in
            *"app-server --listen ws://127.0.0.1:$PORT"*) found=0 ;;
            *) return 1 ;;
          esac ;;
    esac
  done < <(/usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -Fpu 2>/dev/null)
  return $found
}
# トークンは app-server を起動するたびに作り直す（0600 の一時ファイルに書いてから置き換える）。
new_token() {
  mkdir -p "$(dirname "$TOKEN_FILE")"
  local tmp="$TOKEN_FILE.$$.tmp"
  (umask 077; openssl rand -hex 32 > "$tmp") && mv -f "$tmp" "$TOKEN_FILE"
}

# 待ち受けはあるがまだ応答しない（Bridge が起動した直後など）。ここでトークンを作り直すと、もう読み込んだ
# app-server とずれて Bridge もこちらも繋がらなくなるので、作り直さずに待つ。応答しなければ共有しない。
if ! ready && /usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
  for _ in $(seq 1 40); do ready && break; sleep 0.25; done
  ready || { echo "buddy-codex: 共有 app-server が応答しません。共有せずに通常の codex で起動します" >&2; exec codex "$@"; }
fi
if ready && ! own_listener; then
  echo "buddy-codex: ポート $PORT を別のプロセスが使っています。共有せずに通常の codex で起動します" >&2
  exec codex "$@"
fi

if ! ready; then
  new_token
  # OAuth 連携 MCP のトークン（Bridge の McpTokenVault）を、Bridge が起動するときと同じ BUDDYOS_MCP_<名前>
  # で渡す（config.toml は bearer_token_env_var でこれを参照する）。値は画面にもログにも出さない。
  if [ -s "$MCP_TOKENS" ] && command -v python3 >/dev/null; then
    while IFS= read -r -d '' k && IFS= read -r -d '' v; do export "$k=$v"; done < <(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
# McpTokenVault.load と同じく、文字列以外が混じっていれば全体を無いものとみなす
if not isinstance(d, dict) or not all(isinstance(v, str) for v in d.values()):
    sys.exit(0)
for name, tok in d.items():
    k = "BUDDYOS_MCP_" + "".join(c if c.isalnum() else "_" for c in name.upper())
    if k.isascii() and "\0" not in tok:
        sys.stdout.write(k + "\0" + tok + "\0")
' "$MCP_TOKENS" 2>/dev/null)
  fi
  # 起動は HOME で nohup + & で切り離し、$! で pid を受け取る（Bridge の CodexSharedAppServer.start と同じ形）。
  SERVER_PID="$(cd "$HOME" && { nohup codex app-server --listen "ws://127.0.0.1:$PORT" \
    --ws-auth capability-token --ws-token-file "$TOKEN_FILE" >> "$LOG" 2>&1 < /dev/null & echo $!; })"
  for _ in $(seq 1 40); do ready && break; sleep 0.25; done
  ready || { echo "buddy-codex: 共有 app-server が起動しません（${LOG}）。通常の codex で起動します" >&2; exec codex "$@"; }
  own_listener || { echo "buddy-codex: ポート $PORT を別のプロセスが使っています。共有せずに通常の codex で起動します" >&2; exec codex "$@"; }
  # 渡したトークンの指紋（SHA-256。値は残さない）を pid と一緒に残す。無いと Bridge は「トークン未受け渡し」と
  # みなし、ターミナルが切れたあとに起動し直す。書くのはポートを待ち受けているのが自分の app-server のときだけ。
  # 別の起動（もう 1 つの buddy-codex・Bridge）が先に取ると ready はすぐ通り、自分のはまだ bind 前で生きているので
  # kill -0 では見分けられない（まもなく bind 失敗で消える pid で、先に書かれた正しい記録を上書きしてしまう）。
  if [ -s "$MCP_TOKENS" ] && [ -n "$SERVER_PID" ] && listening_is "$SERVER_PID" && command -v python3 >/dev/null; then
    python3 - "$SERVER_PID" "$VAULT" 2>/dev/null <<'PY' || true
import hashlib, json, os, sys
pid, path = int(sys.argv[1]), sys.argv[2]
vault = {k.decode(): hashlib.sha256(v).hexdigest() for k, v in os.environb.items() if k.startswith(b"BUDDYOS_MCP_")}
tmp = f"{path}.{os.getpid()}.tmp"
with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
    json.dump({"pid": pid, "vault": vault}, f, sort_keys=True)
os.replace(tmp, path)
PY
  fi
fi

[ -s "$TOKEN_FILE" ] || { echo "buddy-codex: 共有 app-server のトークンがありません。通常の codex で起動します" >&2; exec codex "$@"; }
export BUDDYOS_CODEX_TOKEN="$(cat "$TOKEN_FILE")"
# TUI と app-server の間に中継を挟み、開いている thread を Bridge に知らせる（iPhone の緑の印）。
# 中継は exec 後の TUI（= この pid）が消えたら自分で終わる。起動できなければ直結する（黙らずに stderr で知らせる）。
# 待ちはポートが書かれた時点・中継が落ちた時点で抜けるので、上限を長めにしても起動は遅くならない
# （node の初回起動が遅い環境向け。node が古く .mjs を読めずに即終了する環境でも毎回 5 秒は待たない）。
TARGET="$PORT"
PROXY="$HOME/.buddyos/bin/buddy-codex-proxy.mjs"
if [ ! -f "$PROXY" ]; then
  echo "buddy-codex: 中継（${PROXY}）がありません。中継なしで繋ぎます（iPhone の一覧に接続中の印は出ません）" >&2
elif ! command -v node >/dev/null; then
  echo "buddy-codex: node が見つかりません。中継なしで繋ぎます（iPhone の一覧に接続中の印は出ません）" >&2
else
  PF="$(mktemp -t buddy-codex-port)"; : > "$PF"
  BUDDY_CODEX_CWD="$PWD" nohup node "$PROXY" "$PORT" "$$" "$PF" >/dev/null 2>&1 < /dev/null &
  PROXY_PID=$!
  for _ in $(seq 1 50); do [ -s "$PF" ] && break; kill -0 "$PROXY_PID" 2>/dev/null || break; sleep 0.1; done
  if [ -s "$PF" ]; then
    TARGET="$(cat "$PF")"
  elif kill -0 "$PROXY_PID" 2>/dev/null; then
    echo "buddy-codex: 中継が 5 秒以内に起動しませんでした。中継なしで繋ぎます（iPhone の一覧に接続中の印は出ません）" >&2
  else
    echo "buddy-codex: 中継が起動直後に終了しました（node が古い等）。中継なしで繋ぎます（iPhone の一覧に接続中の印は出ません）" >&2
  fi
  rm -f "$PF"
fi
REMOTE=(--remote "ws://127.0.0.1:$TARGET" --remote-auth-token-env BUDDYOS_CODEX_TOKEN)
case "${1:-}" in
  resume|fork) sub="$1"; shift; exec codex "$sub" "${REMOTE[@]}" "$@" ;;
  *) exec codex "${REMOTE[@]}" "$@" ;;
esac
W
chmod 755 "$WRAP"
echo "installed: $WRAP"
