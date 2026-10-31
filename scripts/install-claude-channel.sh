#!/bin/bash
# iPhone（BuddyOS）からターミナルの Claude Code に送れるようにする。
#
#  1. channel サーバ（buddy-channel.py）を ~/.buddyos/bin に置く
#  2. user スコープの MCP サーバ `buddy` として登録する（全プロジェクトで使える）
#  3. channel を有効にして起動する `buddy-claude` を ~/.local/bin に置く
#
# 以後はターミナルで `claude` の代わりに `buddy-claude` を使う（引数はそのまま渡る）。
#   --remove  で登録と buddy-claude を取り除く
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$HOME/.buddyos/bin"
WRAP="$HOME/.local/bin/buddy-claude"

if [ "${1:-}" = "--remove" ]; then
  claude mcp remove -s user buddy >/dev/null 2>&1 || true
  rm -f "$WRAP" "$BIN/buddy-channel.py"
  echo "removed buddy channel"; exit 0
fi

mkdir -p "$BIN" "$(dirname "$WRAP")"
cp "$REPO/scripts/buddy-channel.py" "$BIN/buddy-channel.py"
chmod 755 "$BIN/buddy-channel.py"

claude mcp remove -s user buddy >/dev/null 2>&1 || true
claude mcp add -s user buddy -- /usr/bin/python3 "$BIN/buddy-channel.py" >/dev/null
echo "MCP: $(claude mcp get buddy 2>/dev/null | grep -m1 -i -E 'command|scope' || echo registered)"

cat > "$WRAP" <<'W'
#!/bin/bash
# Claude Code を BuddyOS の channel 付きで起動する（iPhone から送れるようになる）。
exec claude --dangerously-load-development-channels server:buddy "$@"
W
chmod 755 "$WRAP"
echo "installed: $WRAP"
