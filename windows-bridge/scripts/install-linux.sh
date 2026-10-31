#!/usr/bin/env bash
#
# BuddyOS Windows Bridge: WSL2 / Linux 上で systemd user サービスとして常駐導入する。
#
# Mac の mac-bridge/setup.sh と同じ思想:
#   ビルド -> ユニット配置 -> ポート競合チェック -> 起動 -> 状態確認出力
# の順で「単一常駐 + 自動再起動 (Restart=always)」に一本化する。
#
# 手動の `npm run dev` / `npm start` とサービスを二重起動するとポート 8765 を
# 取り合うので、導入後はこのサービスへ一本化すること。
# ソースを更新したら再度このスクリプトを実行する (再ビルド -> restart)。
#
set -euo pipefail

# scripts/ の 1 つ上が windows-bridge ルート
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$(cd "$HERE/.." && pwd)"

UNIT_NAME="buddyos-bridge.service"
UNIT_SRC="$HERE/$UNIT_NAME"
UNIT_DST_DIR="$HOME/.config/systemd/user"
UNIT_DST="$UNIT_DST_DIR/$UNIT_NAME"
# config.ts の numberEnv("BUDDYOS_BRIDGE_PORT", 8765) と一致させる
PORT="${BUDDYOS_BRIDGE_PORT:-8765}"

echo "==> windows-bridge: $BRIDGE_DIR"

# --- 前提チェック -----------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "!! node が見つかりません。Node.js >=20 をインストールしてください。"
  echo "   WSL なら例: curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt-get install -y nodejs"
  exit 1
fi
NODE_BIN="$(command -v node)"
echo "==> node: $NODE_BIN ($(node --version))"

if ! command -v systemctl >/dev/null 2>&1; then
  echo "!! systemctl が見つかりません。"
  echo "   WSL2 で systemd を使うには /etc/wsl.conf に次を追記して 'wsl --shutdown' で再起動:"
  echo "       [boot]"
  echo "       systemd=true"
  exit 1
fi

# systemd が user モードで動いているか (WSL で systemd 無効だと失敗する)
if ! systemctl --user show-environment >/dev/null 2>&1; then
  echo "!! systemd の --user インスタンスに接続できません。"
  echo "   WSL2 では /etc/wsl.conf の [boot] systemd=true を設定し 'wsl --shutdown' 後に再ログインしてください。"
  exit 1
fi

# --- ビルド -----------------------------------------------------------------
echo "==> 依存をインストール (package-lock があれば ci、無ければ install)"
if [ -f "$BRIDGE_DIR/package-lock.json" ]; then
  ( cd "$BRIDGE_DIR" && npm ci )
else
  ( cd "$BRIDGE_DIR" && npm install )
fi

echo "==> ビルド (npm run build -> dist/index.js)"
( cd "$BRIDGE_DIR" && npm run build )

if [ ! -f "$BRIDGE_DIR/dist/index.js" ]; then
  echo "!! ビルド後も dist/index.js が見つかりません。ビルド出力を確認してください。"
  exit 1
fi

# --- 既存サービス停止 + ポート競合チェック ----------------------------------
echo "==> 既存サービスがあれば停止"
systemctl --user stop "$UNIT_NAME" 2>/dev/null || true

# サービス管理外のインスタンス (手動 npm dev など) がポートを握っていないか確認
STRAY=""
if command -v ss >/dev/null 2>&1; then
  # listen 中のプロセス PID を抜き出す
  STRAY="$(ss -ltnpH "sport = :${PORT}" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -n1 | cut -d= -f2 || true)"
elif command -v lsof >/dev/null 2>&1; then
  STRAY="$(lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN -t 2>/dev/null | head -n1 || true)"
fi
if [ -n "$STRAY" ]; then
  echo "!! ポート ${PORT} を別プロセス (PID: ${STRAY}) が使用中です。"
  echo "   手動起動した Bridge を止めてから、もう一度このスクリプトを実行してください:"
  echo "       kill ${STRAY}"
  exit 1
fi

# --- ユニット配置 (テンプレートのプレースホルダを実パスへ置換) ---------------
echo "==> systemd user unit を配置 -> $UNIT_DST"
mkdir -p "$UNIT_DST_DIR"
# __NODE_BIN__ / __WINDOWS_BRIDGE_DIR__ を絶対パスに差し替える。
# パスに & や | が含まれても安全なよう、区切り文字に | を使い、置換値はそのまま埋める。
sed \
  -e "s|__NODE_BIN__|${NODE_BIN}|g" \
  -e "s|__WINDOWS_BRIDGE_DIR__|${BRIDGE_DIR}|g" \
  "$UNIT_SRC" > "$UNIT_DST"

# --- 起動 -------------------------------------------------------------------
echo "==> daemon-reload + enable --now (ログイン時自動起動 + 即時起動)"
systemctl --user daemon-reload
systemctl --user enable --now "$UNIT_NAME"

# 起動を見届ける (Restart=always のため失敗しても再試行されるが、初回成否を確認)
sleep 2

echo ""
echo "==> サービス状態:"
systemctl --user --no-pager --full status "$UNIT_NAME" || true

LISTENING="no"
if command -v ss >/dev/null 2>&1; then
  ss -ltn "sport = :${PORT}" 2>/dev/null | grep -q ":${PORT}" && LISTENING="yes"
elif command -v lsof >/dev/null 2>&1; then
  lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1 && LISTENING="yes"
fi

echo ""
if [ "$LISTENING" = "yes" ]; then
  echo "==> OK: Bridge が起動し ポート ${PORT} を listen 中"
else
  echo "!! まだ ポート ${PORT} を listen していません。下記ログを確認してください:"
  echo "     journalctl --user -u ${UNIT_NAME} -e"
fi

cat <<EOF

完了。
  状態確認 : systemctl --user status ${UNIT_NAME}
  ログ     : journalctl --user -u ${UNIT_NAME} -f   (journald が自動ローテート)
  再起動   : systemctl --user restart ${UNIT_NAME}
  停止     : systemctl --user stop ${UNIT_NAME}
  自動起動解除: systemctl --user disable ${UNIT_NAME}

  ログイン前 (ブート直後) から常駐させたい場合:
     sudo loginctl enable-linger \$USER
  ※ WSL では systemd=true が前提。詳細は scripts/README.md を参照。

以後は手動の \`npm run dev\` / \`npm start\` は使わず、この常駐サービスに一本化してください。
ソース更新時はこのスクリプトを再実行 (再ビルド -> restart)。
EOF
