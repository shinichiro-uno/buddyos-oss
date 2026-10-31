#!/bin/bash
# iPhone（BuddyOS）とターミナルの OpenCode で同じ会話を共有できるようにする。
#
# `buddy-opencode` を ~/.local/bin に置く。中身は「Bridge が起動している opencode serve に
# `opencode attach` で繋ぐ」だけ。Bridge も同じ serve に繋ぐので、どちらから送っても両方にリアルタイムで流れる。
# Bridge（BuddyOS）が動いていないときは、普通の `opencode` で起動する。
#
# 以後はターミナルで `opencode` の代わりに `buddy-opencode` を使う（引数はそのまま渡る）。
#   --remove  で buddy-opencode を取り除く
set -euo pipefail
WRAP="$HOME/.local/bin/buddy-opencode"

if [ "${1:-}" = "--remove" ]; then
  rm -f "$WRAP"; echo "removed $WRAP"; exit 0
fi

mkdir -p "$(dirname "$WRAP")"
cat > "$WRAP" <<'W'
#!/bin/bash
# OpenCode を BuddyOS の serve に繋いで起動する（iPhone から見る・送るができる）。
set -u
INFO="$HOME/.buddyos/opencode-serve.json"
TERMS="$HOME/.buddyos/opencode-terminals"
URL=""
PASS=""
if [ -s "$INFO" ] && command -v python3 >/dev/null; then
  # 1 行目に url、2 行目に serve のパスワード（Bridge が起動のたびに作る。0600 のファイルにだけ置かれる）。
  { IFS= read -r URL; IFS= read -r PASS; } < <(python3 -c '
import json, os, sys
try:
    d = json.load(open(sys.argv[1])); os.kill(int(d["pid"]), 0)
    print(d["url"]); print(d.get("password", ""))
except Exception:
    pass' "$INFO") || true
fi
if [ -z "$URL" ]; then
  echo "buddy-opencode: BuddyOS の Bridge が動いていないので、普通の opencode で起動します。" >&2
  exec opencode "$@"
fi
# サブコマンド（run / models / serve など）は serve を介さずそのまま実行
if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
  exec opencode "$@"
fi
# 起動中だけ「ターミナルで開いている」印を置く（Bridge が一覧で緑にする）。終了で消える。
mkdir -p "$TERMS"
# cwd は JSON として書く（" や \ を含むフォルダ名でも Bridge が読めるように）。URL がある = python3 はある。
python3 -c 'import json, sys; sys.stdout.write(json.dumps({"cwd": sys.argv[1]}))' "$PWD" > "$TERMS/$$.json"
trap 'rm -f "$TERMS/$$.json"' EXIT
# パスワードは引数（ps で見える）ではなく環境変数で、attach の起動にだけ渡す。
OPENCODE_SERVER_PASSWORD="$PASS" OPENCODE_SERVER_USERNAME=opencode opencode attach "$URL" --dir "$PWD" "$@"
W
chmod +x "$WRAP"
echo "installed $WRAP"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "注意: ~/.local/bin が PATH にありません";; esac
