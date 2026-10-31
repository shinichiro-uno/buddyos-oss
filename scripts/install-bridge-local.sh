#!/bin/bash
# ビルド済みの mac-bridge（.build/release/BridgeApp）を、launchd の実体と desktop 同梱の staging 先へ入れる。
# 先に: cd mac-bridge && swift build -c release
# 戻すときは、表示される backup を LIVE に cp して launchctl load し直す。
#
# 署名: BUDDYOS_CODESIGN_IDENTITY（既定は "-" = ad-hoc）。配布用の証明書で署名するときはその名前を入れる。
# LaunchAgent のラベル: `<ID の頭>.bridge`（BUDDYOS_ID_PREFIX、無ければビルドした Bridge の既定）。
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
NEW="$REPO/mac-bridge/.build/release/BridgeApp"
[ -f "$NEW" ] || { echo "ABORT: release ビルドがありません: $NEW"; exit 1; }
PREFIX="$("$NEW" --print-id-prefix 2>/dev/null)" || PREFIX=""
[ -n "$PREFIX" ] || { echo "ABORT: ID の頭を決められません (BUDDYOS_ID_PREFIX を指定してください)"; exit 1; }
PLIST="$HOME/Library/LaunchAgents/${PREFIX}.bridge.plist"
# launchd が実際に動かすパスと待ち受けの番号は plist から読む（mac-bridge/scripts/setup-launchd.sh が書く。
# 読めなければその既定: ~/.buddyos/bin/BridgeApp と 8764）。
LIVE="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST" 2>/dev/null)" || LIVE=""
[ -n "$LIVE" ] || LIVE="$HOME/.buddyos/bin/BridgeApp"
PORT="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:BUDDYOS_BRIDGE_PORT' "$PLIST" 2>/dev/null)" || PORT=""
case "$PORT" in ''|*[!0-9]*) PORT=8764 ;; esac
ERR_LOG="$HOME/Library/Logs/BuddyOS/bridge.err.log"
STAGE="$REPO/desktop/resources/bin/mac/BridgeApp"
IDENTITY="${BUDDYOS_CODESIGN_IDENTITY:--}"
STAMP=$(date +%Y%m%d-%H%M%S)

if [ "$IDENTITY" = "-" ]; then
  echo "  ad-hoc で署名（BUDDYOS_CODESIGN_IDENTITY で証明書を指定できます）"
  codesign --force --sign - "$NEW" || { echo "ABORT: 署名失敗"; exit 1; }
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$NEW" 2>/dev/null \
    || { echo "  timestamp なしで署名（ローカル実行用）"; codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$NEW" || { echo "ABORT: 署名失敗"; exit 1; }; }
fi

# デスクトップも止めて二重起動を避ける
osascript -e 'tell application "BuddyOS" to quit' 2>/dev/null; sleep 2
launchctl unload "$PLIST" 2>/dev/null; sleep 1
pkill -f "BridgeApp$" 2>/dev/null; sleep 1

[ -f "$LIVE" ] && cp -p "$LIVE" "$LIVE.prev-$STAMP" && echo "  backup: $LIVE.prev-$STAMP"
# rm→cp（setup-launchd.sh と同じ。動いていた inode への上書きと cdhash キャッシュのずれを避ける）
mkdir -p "$(dirname "$LIVE")" && rm -f "$LIVE" && cp -p "$NEW" "$LIVE" && chmod 755 "$LIVE"
mkdir -p "$(dirname "$STAGE")" && cp -p "$NEW" "$STAGE"

launchctl load "$PLIST" 2>/dev/null; sleep 4
pid=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1)
if [ -z "$pid" ]; then
  echo "$PORT を誰も LISTEN していません"; tail -15 "$ERR_LOG" 2>/dev/null
  echo "戻す: cp -p '$LIVE.prev-$STAMP' '$LIVE' && launchctl load '$PLIST'"
  exit 1
fi
echo "  $PORT LISTEN: PID $pid → $(ps -o comm= -p "$pid")"
open /Applications/BuddyOS.app; sleep 6
echo "  BridgeApp 本数: $(pgrep -f 'BridgeApp$' | wc -l | tr -d ' ') （1 が正常）"
# 端末認証 v3（spec/PROTOCOL-v3.md Appendix A）: LaunchAgent で動く Bridge には管理鍵が無い。
# 端末の管理（招待・承認・外す）は、メニューバーの「QR を表示」か、デスクトップの「Bridge を起動し直す」で行う。
echo "  注意: LaunchAgent の Bridge では端末の管理ができません。QR はメニューバーから、管理はデスクトップの「Bridge を起動し直す」から。"
