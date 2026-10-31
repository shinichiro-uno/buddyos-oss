#!/bin/bash
# iPhone（BuddyOS）から、ターミナルで開いている Antigravity（agy）の会話へ送れるようにする。
#
# agy の PreInvocation hook（モデルを呼ぶ直前に会話へメッセージを差し込める、agy 公式の仕組み）を
# ~/.gemini/config/hooks.json に "buddyos-inbox" として足す。Bridge は iPhone から送られた文を
# ~/.buddyos/agy-inbox/<会話ID>.json に置き、hook がそれを次の段階で会話に入れる。
# 受け取り箱が空なら hook は何も出さない（= agy の通常の動き。ターミナルの agy の動きは変わらない）。
# agy が入力待ちで止まっている間はモデルを呼ばないので、ターミナルで何か送るまで届かない。
# 書き換える前に hooks.json.bak-<日時> を残す。外すときは "buddyos-inbox" だけを消す。
#   --remove  で hook とスクリプトを取り除く
set -euo pipefail
HOOKS="$HOME/.gemini/config/hooks.json"
SCRIPT="$HOME/.buddyos/bin/buddy-agy-inbox.sh"

edit_hooks() {
  python3 - "$HOOKS" "$1" "$SCRIPT" <<'PY'
import json, os, sys
path, action, script = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    data = json.load(open(path))
except FileNotFoundError:
    data = {}
if action == "remove":
    data.pop("buddyos-inbox", None)
else:
    data["buddyos-inbox"] = {
        "PreInvocation": [{"type": "command", "command": "'" + script.replace("'", "'\\''") + "'", "timeout": 10}]
    }
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump(data, open(path, "w"), indent=2, ensure_ascii=False)
open(path, "a").write("\n")
PY
}

if [ "${1:-}" = "--remove" ]; then
  if [ -f "$HOOKS" ] && grep -q '"buddyos-inbox"' "$HOOKS"; then
    cp "$HOOKS" "$HOOKS.bak-$(date +%Y%m%d%H%M%S)"
    edit_hooks remove
  fi
  rm -f "$SCRIPT"
  echo "removed buddyos-inbox from ${HOOKS}"
  exit 0
fi

mkdir -p "$(dirname "$SCRIPT")"
cat > "$SCRIPT" <<'S'
#!/bin/sh
# BuddyOS: iPhone から送った文を、ターミナルの agy の会話に差し込む（PreInvocation hook）。
# Bridge が ~/.buddyos/agy-inbox/<会話ID>.json に hook の出力（injectSteps）をそのまま置く。無ければ何も出さない。
in=$(cat)
cid=$(printf '%s' "$in" | sed -n 's/.*"conversationId" *: *"\([0-9a-fA-F-]*\)".*/\1/p' | head -1)
[ -n "$cid" ] || exit 0
f="$HOME/.buddyos/agy-inbox/$cid.json"
[ -s "$f" ] || exit 0
t="$f.$$"
mv "$f" "$t" 2>/dev/null || exit 0
cat "$t"
rm -f "$t"
S
chmod +x "$SCRIPT"
if [ -f "$HOOKS" ]; then cp "$HOOKS" "$HOOKS.bak-$(date +%Y%m%d%H%M%S)"; fi
edit_hooks add
echo "installed buddyos-inbox in ${HOOKS}"
