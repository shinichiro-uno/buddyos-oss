#!/usr/bin/env bash
#
# 互換シム: 実体は scripts/setup-launchd.sh へ移動した (事前ビルドしたバイナリを launchd から直接起動する)。
# plist が __HOME__ 置換テンプレートになったため、この旧スクリプトの「plist を素で cp する」
# 手順はもう使えない。既存の導入手順 (./setup.sh) を壊さないよう委譲だけ残す。
#
exec "$(cd "$(dirname "$0")" && pwd)/scripts/setup-launchd.sh" "$@"
