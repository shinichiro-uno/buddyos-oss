#requires -Version 5.1
<#
.SYNOPSIS
    BuddyOS Windows Bridge を Windows ネイティブの常駐サービスとして
    Task Scheduler に登録する (Mac の launchd 常駐に相当)。

.DESCRIPTION
    Mac の mac-bridge/setup.sh と同じ思想で
        ビルド -> ログ準備(簡易ローテート) -> ポート競合チェック ->
        スケジュールタスク登録 -> 起動 -> 状態確認出力
    を行う。

    登録するタスクの挙動:
      - ログオン時に自動起動 (At Logon)
      - 異常終了時に自動再起動 (RestartCount/RestartInterval。launchd の KeepAlive 相当)
      - node dist\index.js を起動し、stdout/stderr をログファイルへリダイレクト

    ログのローテート:
      Task Scheduler 自体にはログローテーションが無く、Node も console.log のみのため、
      ラッパー (run-bridge.cmd を生成) が「起動のたびに旧ログを .1 へ rename する」
      簡易ローテートを行う (1 世代保持)。journald のような世代管理が必要なら
      ログ基盤 (例: NSSM + winsw 等) への移行を検討すること。

    注意:
      - このスクリプトは Windows 上でしか検証できないテンプレートです。
        実行前に内容を確認してください。
      - 管理者権限は不要 (現在ユーザーのスケジュールタスクとして登録)。
      - Node.js >=20 が PATH に必要。ポート 8765 が空いている必要があります。

.PARAMETER Port
    Bridge の listen ポート。既定 8765 (config.ts の BUDDYOS_BRIDGE_PORT 既定値と一致)。
    環境変数 BUDDYOS_BRIDGE_PORT が設定されていればそちらを優先。

.PARAMETER TaskName
    登録するスケジュールタスク名。既定 "BuddyOS Windows Bridge"。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1

.EXAMPLE
    # ポートを変えて登録
    powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1 -Port 9000
#>

[CmdletBinding()]
param(
    [int]    $Port     = $(if ($env:BUDDYOS_BRIDGE_PORT) { [int]$env:BUDDYOS_BRIDGE_PORT } else { 8765 }),
    [string] $TaskName = "BuddyOS Windows Bridge"
)

# bash の set -euo pipefail に相当: エラーで停止
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# scripts\ の 1 つ上が windows-bridge ルート
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BridgeDir = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$EntryJs   = Join-Path $BridgeDir "dist\index.js"

# ログは %LOCALAPPDATA%\BuddyOS\Bridge\logs に出す
$LogDir    = Join-Path $env:LOCALAPPDATA "BuddyOS\Bridge\logs"
$OutLog    = Join-Path $LogDir "bridge.out.log"
$ErrLog    = Join-Path $LogDir "bridge.err.log"
# 起動のたびに旧ログを .1 へ rename する簡易ローテートを行うラッパー
$WrapperCmd = Join-Path $ScriptDir "run-bridge.cmd"

Write-Host "==> windows-bridge: $BridgeDir"

# --- 前提チェック -----------------------------------------------------------
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Host "!! node が見つかりません。Node.js >=20 をインストールし PATH を通してください。"
    Write-Host "   https://nodejs.org/ または winget install OpenJS.NodeJS.LTS"
    exit 1
}
$NodeExe = $node.Source
Write-Host "==> node: $NodeExe ($(node --version))"

$npm = Get-Command npm -ErrorAction SilentlyContinue
if (-not $npm) {
    Write-Host "!! npm が見つかりません。Node.js のインストールを確認してください。"
    exit 1
}

# --- ビルド -----------------------------------------------------------------
Write-Host "==> 依存をインストール (package-lock があれば ci、無ければ install)"
Push-Location $BridgeDir
try {
    if (Test-Path (Join-Path $BridgeDir "package-lock.json")) {
        & npm ci
    } else {
        & npm install
    }
    if ($LASTEXITCODE -ne 0) { throw "npm install/ci に失敗しました (exit $LASTEXITCODE)" }

    Write-Host "==> ビルド (npm run build -> dist\index.js)"
    & npm run build
    if ($LASTEXITCODE -ne 0) { throw "npm run build に失敗しました (exit $LASTEXITCODE)" }
}
finally {
    Pop-Location
}

if (-not (Test-Path $EntryJs)) {
    Write-Host "!! ビルド後も $EntryJs が見つかりません。ビルド出力を確認してください。"
    exit 1
}

# --- ポート競合チェック -----------------------------------------------------
# タスク管理外のインスタンス (手動 npm dev など) がポートを握っていないか確認
$listener = $null
try {
    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
} catch {
    # 古い OS で Get-NetTCPConnection が無い場合は netstat にフォールバック
    $line = (netstat -ano | Select-String ":$Port\s" | Select-String "LISTENING" | Select-Object -First 1)
    if ($line) { Write-Host "!! ポート $Port が使用中の可能性があります (netstat): $line" }
}
if ($listener) {
    # 注意: $pid は PowerShell の自動変数 (現在プロセスの PID) なので使わない
    $ownerPid = $listener.OwningProcess
    $pname = (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue).ProcessName
    Write-Host "!! ポート $Port を別プロセス (PID: $ownerPid, $pname) が使用中です。"
    Write-Host "   手動起動した Bridge を止めてから、もう一度このスクリプトを実行してください:"
    Write-Host "       Stop-Process -Id $ownerPid"
    exit 1
}

# --- ログディレクトリ + ローテートラッパー生成 ------------------------------
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# run-bridge.cmd: 起動のたびに旧ログを .1 へ rename (1 世代) してから node を exec する。
# Task Scheduler から「これ 1 本」を起動させることで stdout/stderr をファイルへ確実に向ける。
$wrapperBody = @"
@echo off
REM === 自動生成: install-windows.ps1 が再生成する。手で編集しても上書きされる。 ===
REM BuddyOS Windows Bridge ランチャー (簡易ログローテート 1 世代 + node 起動)
setlocal

set "OUT=$OutLog"
set "ERR=$ErrLog"

REM 起動のたびに旧ログを .1 へ退避 (前回の .1 は破棄)
if exist "%OUT%" (
  if exist "%OUT%.1" del /q "%OUT%.1"
  move /y "%OUT%" "%OUT%.1" >nul
)
if exist "%ERR%" (
  if exist "%ERR%.1" del /q "%ERR%.1"
  move /y "%ERR%" "%ERR%.1" >nul
)

cd /d "$BridgeDir"
REM stdout -> bridge.out.log, stderr -> bridge.err.log
"$NodeExe" "$EntryJs" 1>>"%OUT%" 2>>"%ERR%"
"@
Set-Content -Path $WrapperCmd -Value $wrapperBody -Encoding ASCII
Write-Host "==> ランチャーを生成 -> $WrapperCmd"
Write-Host "==> ログ出力先 -> $OutLog / $ErrLog (起動時に .1 へ 1 世代ローテート)"

# --- スケジュールタスク登録 -------------------------------------------------
Write-Host "==> 既存タスクがあれば削除して登録し直す"
schtasks /Query /TN "$TaskName" 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    schtasks /End    /TN "$TaskName" 2>$null | Out-Null
    schtasks /Delete /TN "$TaskName" /F | Out-Null
}

# ScheduledTasks モジュールが使えるなら、再起動ポリシー付きで登録する (推奨)。
# 無い古い環境では schtasks /Create にフォールバックする (再起動ポリシーは付かない)。
$haveSchedMod = Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue
if ($haveSchedMod) {
    Write-Host "==> ScheduledTasks モジュールで登録 (ログオン時起動 + 異常終了時 再起動)"
    $action  = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$WrapperCmd`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    # launchd の KeepAlive 相当: 異常終了で 1 分後に再起動、回数上限なしに近い大きめの値。
    # ExecutionTimeLimit 0 = 無制限 (常駐プロセスなのでタイムアウトさせない)。
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
    # 対話ユーザーとして実行 (ユーザーの PATH/エージェント設定を継承)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask -TaskName "$TaskName" `
        -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description "BuddyOS Windows Bridge (Node WebSocket bridge for the BuddyOS iOS app)" `
        -Force | Out-Null
} else {
    Write-Host "==> ScheduledTasks モジュールが無いため schtasks /Create で登録 (再起動ポリシーは付与されません)"
    schtasks /Create /TN "$TaskName" /SC ONLOGON /RL LIMITED /F `
        /TR "cmd.exe /c `"$WrapperCmd`"" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "schtasks /Create に失敗しました (exit $LASTEXITCODE)" }
    Write-Host "   ※ 異常終了時の自動再起動が必要なら ScheduledTasks モジュール対応 OS で再登録してください。"
}

# --- 起動 -------------------------------------------------------------------
Write-Host "==> タスクを今すぐ起動"
schtasks /Run /TN "$TaskName" | Out-Null

Start-Sleep -Seconds 2

# --- 状態確認 ---------------------------------------------------------------
$listening = $false
try {
    $listening = [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
} catch {
    $listening = [bool](netstat -ano | Select-String ":$Port\s" | Select-String "LISTENING")
}

Write-Host ""
if ($listening) {
    Write-Host "==> OK: Bridge が起動し ポート $Port を listen 中"
} else {
    Write-Host "!! まだ ポート $Port を listen していません。下記ログを確認してください:"
    Write-Host "     Get-Content `"$ErrLog`" -Tail 40"
}

Write-Host ""
Write-Host "完了。"
Write-Host "  状態確認 : schtasks /Query /TN `"$TaskName`" /V /FO LIST"
Write-Host "  ログ     : $OutLog / $ErrLog  (起動時に .1 へ 1 世代ローテート)"
Write-Host "  手動起動 : schtasks /Run  /TN `"$TaskName`""
Write-Host "  停止     : schtasks /End  /TN `"$TaskName`""
Write-Host "  登録解除 : schtasks /Delete /TN `"$TaskName`" /F"
Write-Host ""
Write-Host "以後は手動の 'npm run dev' / 'npm start' は使わず、この常駐タスクに一本化してください。"
Write-Host "ソース更新時はこのスクリプトを再実行 (再ビルド -> 再登録 -> 起動)。"
