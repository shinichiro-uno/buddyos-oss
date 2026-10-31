#!/bin/bash
# iPhone（BuddyOS）とターミナルの Grok で同じ会話を共有できるようにする。
#
# ~/.grok/config.toml の [cli] に `use_leader = true` を足す。ターミナルの grok は共有の leader
# （1 つの常駐プロセスで複数の画面が同じ会話を見る、Grok 公式の仕組み）に乗るようになり、
# Bridge も同じ leader に繋ぐので、ターミナルで打った内容と返事が iPhone にも流れる。
# 書き換える前に config.toml.bak-<日時> を残す。BuddyOS が足した行には印を付け、外すときはその行だけを消す。
#   --remove  で BuddyOS が足した行を取り除く（利用者が自分で書いた use_leader は触らない）
set -euo pipefail
CONF="$HOME/.grok/config.toml"
MARK="# BuddyOS: iPhone とターミナルで会話を共有"

if [ "${1:-}" = "--remove" ]; then
  if [ -f "$CONF" ] && grep -qF "$MARK" "$CONF"; then
    cp "$CONF" "$CONF.bak-$(date +%Y%m%d%H%M%S)"
    grep -vF "$MARK" "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
  fi
  echo "removed use_leader from $CONF"
  exit 0
fi

mkdir -p "$(dirname "$CONF")"
touch "$CONF"
if grep -qE '^[[:space:]]*use_leader[[:space:]]*=' "$CONF"; then
  echo "use_leader は既に設定されています（変更しません）: ${CONF}"
  exit 0
fi
cp "$CONF" "$CONF.bak-$(date +%Y%m%d%H%M%S)"
python3 - "$CONF" "$MARK" <<'PY'
import sys
path, mark = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
line = f"use_leader = true  {mark}"
for i, l in enumerate(lines):
    if l.strip() == "[cli]":
        lines.insert(i + 1, line)
        break
else:
    lines = ["[cli]", line, ""] + lines
open(path, "w").write("\n".join(lines) + "\n")
PY
echo "installed use_leader in ${CONF}（開いているターミナルの grok は起動し直すと反映されます）"
