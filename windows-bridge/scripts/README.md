# windows-bridge 常駐サービス導入スクリプト

windows-bridge を「単一常駐 + 自動再起動 + ログ運用」付きで動かすためのスクリプト群です。
Mac の `mac-bridge/setup.sh` (launchd + KeepAlive) に対する Windows/WSL 側のパリティを提供します。

Bridge 本体 (`src/server.ts` / `src/index.ts`) のログ実装 (`console.log`) はそのままに、
サービス層 (プロセスマネージャ) でログ出力先とローテーションを担保する方針です。

| 環境 | スクリプト | プロセス管理 | ログ | ローテーション |
|---|---|---|---|---|
| WSL2 / Linux | `install-linux.sh` | systemd user unit | journald | journald が自動 |
| Windows ネイティブ | `install-windows.ps1` | Task Scheduler | ファイル (`bridge.out.log` / `bridge.err.log`) | 起動時に `.1` へ 1 世代 |

どちらも「ビルド -> 配置 -> ポート競合チェック -> 起動 -> 状態確認」を行い、
手動の `npm run dev` / `npm start` と二重起動してポート 8765 を取り合わないよう、
常駐経路を 1 つに統一することを目的としています。

ファイル:
- `buddyos-bridge.service` … systemd user unit テンプレート (install-linux.sh が実パスへ置換して配置)
- `install-linux.sh` … WSL2 / Linux 用インストーラ (bash, `set -euo pipefail`)
- `install-windows.ps1` … Windows ネイティブ用インストーラ (PowerShell)
- `run-bridge.cmd` … install-windows.ps1 が自動生成するランチャー (簡易ログローテート + node 起動)

> いずれも node `dist/index.js` を起動します。事前に各スクリプトが `npm run build` を実行します。
> ポートは既定 8765 (`config.ts` の `BUDDYOS_BRIDGE_PORT` 既定値)。環境変数で上書き可能。

---

## WSL2 / Linux (install-linux.sh)

systemd の user サービスとして常駐させます。`Restart=always` + `RestartSec=10` で
クラッシュ・正常終了どちらでも自動再起動します (launchd の KeepAlive / ThrottleInterval=10 相当)。

### 前提

- Node.js >= 20 (`node --version`)
- systemd が利用可能なこと。
  WSL2 で systemd を有効にするには `/etc/wsl.conf` に以下を追記し、PowerShell から `wsl --shutdown` 後に再ログイン:

  ```ini
  [boot]
  systemd=true
  ```

### 導入

```bash
cd windows-bridge
bash scripts/install-linux.sh
```

スクリプトは順に以下を行います:

1. `npm ci` (lock があれば) または `npm install` -> `npm run build`
2. `~/.config/systemd/user/buddyos-bridge.service` を配置 (テンプレートの `__NODE_BIN__` / `__WINDOWS_BRIDGE_DIR__` を実パスへ置換)
3. `systemctl --user daemon-reload`
4. `systemctl --user enable --now buddyos-bridge.service` (ログイン時自動起動 + 即時起動)
5. 状態確認とポート listen チェックを出力

### 運用コマンド

```bash
systemctl --user status   buddyos-bridge.service          # 状態確認
journalctl  --user -u      buddyos-bridge.service -f       # ログ追尾 (journald が自動ローテート)
systemctl --user restart  buddyos-bridge.service          # 再起動
systemctl --user stop     buddyos-bridge.service          # 停止
systemctl --user disable  buddyos-bridge.service          # 自動起動解除
```

### ログ

stdout/stderr は journald に集約されます (`journalctl --user -u buddyos-bridge`)。
保存量は journald の設定 (`/etc/systemd/journald.conf` の `SystemMaxUse` 等) に従い自動でローテート・上限管理されるため、
ファイルローテーション用の別スクリプトは不要です。

### ログイン前 (ブート直後) から常駐させたい

user サービスは既定ではログイン中のみ動きます。ログオフ後やブート直後から動かすには linger を有効化:

```bash
sudo loginctl enable-linger "$USER"
```

### 更新時

ソースを更新したら再度 `bash scripts/install-linux.sh` を実行してください (再ビルド -> ユニット再配置 -> restart)。

---

## Windows ネイティブ (install-windows.ps1)

Task Scheduler にタスクを登録し、ログオン時起動 + 異常終了時の自動再起動を行います。
ScheduledTasks モジュールがある環境では `-RestartCount` / `-RestartInterval` を付けて
launchd の KeepAlive に近い挙動にします。

> 管理者権限は不要です (現在ユーザーのタスクとして登録)。

### 前提

- Node.js >= 20 が PATH に通っていること (`node --version`)
- ポート 8765 が空いていること

### 導入

PowerShell で windows-bridge ルートから実行:

```powershell
cd windows-bridge
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1
```

ポートを変える場合:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1 -Port 9000
```

スクリプトは順に以下を行います:

1. `npm ci` / `npm install` -> `npm run build`
2. ポート競合チェック
3. ランチャー `scripts\run-bridge.cmd` を生成 (起動時にログを `.1` へローテート -> node 起動)
4. スケジュールタスク "BuddyOS Windows Bridge" を登録 (ログオン時起動 + 異常終了時再起動)
5. 即時起動 + listen チェックを出力

### 運用コマンド

```powershell
schtasks /Query  /TN "BuddyOS Windows Bridge" /V /FO LIST   # 状態確認
schtasks /Run    /TN "BuddyOS Windows Bridge"               # 手動起動
schtasks /End    /TN "BuddyOS Windows Bridge"               # 停止
schtasks /Delete /TN "BuddyOS Windows Bridge" /F            # 登録解除
```

### ログ

`%LOCALAPPDATA%\BuddyOS\Bridge\logs\` に出力されます:

- `bridge.out.log` … stdout
- `bridge.err.log` … stderr

ローテーションは `run-bridge.cmd` が担当し、起動のたびに既存ログを `.1` へ rename します (1 世代保持)。
世代管理を強化したい場合は NSSM や WinSW などのサービスラッパーへの移行を検討してください。

ログの確認例:

```powershell
Get-Content "$env:LOCALAPPDATA\BuddyOS\Bridge\logs\bridge.err.log" -Tail 40
```

### よくある問題

- node が見つからない: Node.js >= 20 をインストールし PATH を通す (`winget install OpenJS.NodeJS.LTS`)。
- ポート 8765 競合: 手動起動した Bridge を `Stop-Process -Id <PID>` で止めてから再実行。
  競合プロセスの特定は `Get-NetTCPConnection -LocalPort 8765 -State Listen`。
- 実行ポリシーで止まる: `-ExecutionPolicy Bypass` 付きで起動 (上記例)。
- `Missing closing ')'` などの構文エラー: `install-windows.ps1` は日本語を含むので BOM 付き UTF-8 で保存する。
  BOM が無いと Windows PowerShell 5.1 が ANSI (日本語環境では CP932) として読み違える。編集後も BOM を消さないこと。

### 更新時

ソースを更新したら再度スクリプトを実行してください (再ビルド -> タスク再登録 -> 起動)。

---

## 補足

- 環境変数 (ポート / 各エージェントモード等) は windows-bridge の `README.md` を参照。
  - Linux: `buddyos-bridge.service` の `Environment=` / `EnvironmentFile=` で指定可能。
  - Windows: タスク登録前に環境変数を設定するか、`run-bridge.cmd` を編集 (再生成で上書きされる点に注意)。
- ペアリング用の QR / `buddyos://pair?...` URL は起動時に stdout (ログ) に出力されます。
  常駐起動だと端末に出ないため、ログから URL を確認するか、初回だけ `npm run dev` で取得してください。
