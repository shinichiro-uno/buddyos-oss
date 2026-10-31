#!/usr/bin/env bash
#
# BuddyOS Bridge を launchd 常駐サービス（LaunchAgent）として導入・更新する。
#
# やること:
#   1. swift build -c release で事前ビルド (以後 launchd は再ビルドしない。
#      `swift run -c release` だとクラッシュ→KeepAlive 再起動のたび依存解決+差分ビルドで数秒ハングする)
#   2. .build/release/BridgeApp を ~/.buddyos/bin/ へコピーして署名
#      (repo の .build を launchd が直接参照すると、開発中の swift build で常駐バイナリが
#       すり替わり挙動がドリフトするため、実行体を分離する)
#   3. plist テンプレート (LaunchAgents/bridge.plist.template。__LABEL__・__HOME__ を置換) を ~/Library/LaunchAgents/ へ配置
#      (バイナリ直起動。zsh 経由をやめ PATH は EnvironmentVariables で明示)
#   4. launchctl bootout → bootstrap で再ロード (RunAtLoad + KeepAlive)
#   5. /health エンドポイント疎通確認
#
# ラベル: `<ID の頭>.bridge`。ID の頭は BUDDYOS_ID_PREFIX、無ければビルドした Bridge の既定
#   （`BridgeApp --print-id-prefix`。公開版は dev.buddyos.oss）。
#
# 使い方:
#   mac-bridge/scripts/setup-launchd.sh              # 導入・更新 (何度でも再実行可)
#   launchctl bootout gui/$UID/<label>               # 停止（<label> は最後に表示される）
#   launchctl print gui/$UID/<label>                 # 状態確認
#   ログ: ~/Library/Logs/BuddyOS/bridge.{out,err}.log
#
# 署名: BUDDYOS_CODESIGN_IDENTITY（既定は "-" = ad-hoc 署名）。
#   ad-hoc 署名はリビルドごとに cdhash が変わり、マイク/音声認識などの TCC 許可がリセットされる。
#   Keychain にある自分のコード署名用の証明書の名前を BUDDYOS_CODESIGN_IDENTITY に入れると、
#   designated requirement が証明書アンカーになり、リビルド後も TCC 許可が持続する。
#   （古い名前の CODESIGN_IDENTITY も読む。）
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"   # mac-bridge/
PLIST_SRC="$HERE/LaunchAgents/bridge.plist.template"
BIN_DIR="$HOME/.buddyos/bin"
BIN_DST="$BIN_DIR/BridgeApp"
# 開発用の常駐ブリッジは 8764 固定 (plist の BUDDYOS_BRIDGE_PORT と一致させること。desktop の supervisor は 8765)
PORT=8764

echo "==> (1/5) リリースバイナリをビルド"
( cd "$HERE" && swift build -c release )

# ラベルはビルドした Bridge に聞く（BUDDYOS_ID_PREFIX があればそれ。形が違えば Bridge の既定）。
PREFIX="$("$HERE/.build/release/BridgeApp" --print-id-prefix)"
[ -n "$PREFIX" ] || { echo "!! ID の頭を決められません (BUDDYOS_ID_PREFIX を指定してください)"; exit 1; }
LABEL="${PREFIX}.bridge"
PLIST_DST="$HOME/Library/LaunchAgents/${LABEL}.plist"
echo "    label: $LABEL"

echo "==> (2/5) 既存サービスを停止してバイナリを配置 -> $BIN_DST"
# bootout: 稼働中バイナリの上書きを避けるため、コピー前に必ず止める
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
# 旧 API (load/unload) で登録された残骸も念のため外す
launchctl unload "$PLIST_DST" 2>/dev/null || true

# launchd 管理外のインスタンス (手動 swift run 等) がポートを握っていないか確認。
# 二重起動するとポートを取り合い片方が落ちるため、起動経路をこのサービスに一本化する。
STRAY="$(lsof -nP -iTCP:${PORT} -sTCP:LISTEN -t 2>/dev/null || true)"
if [ -n "$STRAY" ]; then
  echo "!! ポート ${PORT} を別プロセス (PID: ${STRAY}) が使用中です。"
  echo "   手動起動した Bridge を止めてから、もう一度このスクリプトを実行してください:"
  echo "       kill ${STRAY}"
  exit 1
fi

mkdir -p "$BIN_DIR"
# rm→cp: 稼働中だった inode への上書き (SIGKILL の原因) と cdhash キャッシュ不整合を避ける
rm -f "$BIN_DST"
cp "$HERE/.build/release/BridgeApp" "$BIN_DST"

echo "==> (2.5/5) 署名"
IDENTITY="${BUDDYOS_CODESIGN_IDENTITY:-${CODESIGN_IDENTITY:--}}"
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$BIN_DST"
  echo "    signed: ad-hoc (TCC の許可はリビルドごとにリセットされます。BUDDYOS_CODESIGN_IDENTITY で証明書を指定できます)"
# --options runtime (hardened runtime) は将来の公証の要件を先取り。
# timestamp は公証の必須要件 (ネット接続が要る。つながらなければ ad-hoc に落とす)。
elif codesign --force --sign "$IDENTITY" --options runtime --timestamp "$BIN_DST" 2>/dev/null; then
  echo "    signed: $IDENTITY"
  codesign --verify --strict "$BIN_DST" && echo "    verify: OK"
else
  echo "!! 署名失敗 (証明書が無い・timestamp サーバ到達不可?)。ad-hoc で続行します (TCC 再プロンプトの可能性)"
  codesign --force --sign - "$BIN_DST"
fi

echo "==> (3/5) launchd plist を生成 (__LABEL__・__HOME__ 置換) -> $PLIST_DST"
mkdir -p "$HOME/Library/LaunchAgents"
# launchd の StandardOut/ErrorPath（~/Library/Logs/BuddyOS）。launchd はフォルダを作らないので先に作る。
mkdir -p -m 700 "$HOME/Library/Logs/BuddyOS"
chmod 700 "$HOME/Library/Logs/BuddyOS"
# launchd は ProgramArguments/EnvironmentVariables の $HOME を展開しないので、ここで実パスに置換する
sed -e "s|__LABEL__|$LABEL|g" -e "s|__HOME__|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"
plutil -lint "$PLIST_DST" >/dev/null

echo "==> (4/5) launchd サービスを起動 (RunAtLoad + KeepAlive)"
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"

echo "==> (5/5) /health 疎通確認"
# mac の /health は Bearer apiKey 必須 (401 = プロセスは生きているが鍵が無い/違う)。
# 鍵は curl の引数 (ps から見える) に載せず、fd 3 のヘッダとして渡す。
# 送るのは、その番号で待ち受けているのが今入れた BridgeApp のときだけ (別のプロセスに鍵を渡さない)。
API_KEY_FILE="$HOME/.buddyos/api-key"
listener_is_ours() {
  local pid
  pid="$(lsof -nP -iTCP:${PORT} -sTCP:LISTEN -t 2>/dev/null | head -1)"
  [ -n "$pid" ] && [ "$(ps -p "$pid" -o comm= 2>/dev/null)" = "$BIN_DST" ]
}
health_code() {
  if [ -s "$API_KEY_FILE" ] && listener_is_ours; then
    curl -s -o /dev/null -w '%{http_code}' --max-time 2 -H @/dev/fd/3 \
      "http://127.0.0.1:${PORT}/health" 3<<EOF 2>/dev/null || true
Authorization: Bearer $(cat "$API_KEY_FILE")
EOF
  else
    curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${PORT}/health" 2>/dev/null || true
  fi
}
OK=""
for _ in $(seq 1 10); do
  CODE="$(health_code)"
  if [ "$CODE" = "200" ]; then
    OK=1
    break
  fi
  # 401 でも「サーバは応答している」= 起動自体は成功 (鍵不一致だけ警告して続行)
  if [ "$CODE" = "401" ]; then
    echo "!! /health が 401 (プロセスは稼働中。~/.buddyos/api-key と不一致の可能性)"
    OK=1
    break
  fi
  sleep 1
done
if [ -n "$OK" ]; then
  echo "==> OK: Bridge が起動し http://127.0.0.1:${PORT}/health に応答"
else
  echo "!! /health が応答しません。~/Library/Logs/BuddyOS/bridge.err.log を確認してください"
  exit 1
fi

cat <<EOF

完了。
  状態確認 : launchctl print gui/$(id -u)/${LABEL}
  ログ     : ~/Library/Logs/BuddyOS/bridge.out.log / bridge.err.log / bridge-ws.log
  停止     : launchctl bootout gui/$(id -u)/${LABEL}
  更新時   : このスクリプトを再実行 (再ビルド→バイナリ差し替え→reload)

以後は手動の \`swift run BridgeApp\` は使わず、この常駐サービスに一本化してください。
EOF
