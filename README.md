# WSL バックアップスクリプト v2.0

WSL (Windows Subsystem for Linux) のディレクトリを Windows ファイルシステム（NTFS）にバックアップする PowerShell スクリプトです。

## 特徴

### 基本機能

- **高速ミラーリング**: robocopy を使用した Windows ネイティブの高速転送（マルチスレッド対応）
- **柔軟な除外設定**: `.mirrorignore` ファイルで簡単に除外パターンを設定
- **アーカイブ作成**: パーミッションを保持した圧縮 tar.gz アーカイブ
- **自動クリーンアップ**: 古いアーカイブ・ログの自動削除

### セキュリティ機能

- **設定バリデーション**: スキーマベースの厳密な設定値検証
- **パストラバーサル防止**: ソースパスの安全性検証
- **ログマスキング**: 機密情報（パス等）の自動マスキング

### 堅牢性機能

- **二重実行防止**: アトミックなロックファイル操作
- **タイムアウト機能**: 処理全体のタイムアウト設定
- **統一終了コード**: エラー種別に応じた終了コード
- **WSLヘルスチェック**: バックアップ前のWSL状態確認
- **ディスク容量チェック**: 必要な空き容量の事前確認
- **アーカイブ整合性検証**: 作成したアーカイブの gzip 検証
- **チェックサム保存**: SHA256 による長期整合性検証

### 実用性機能

- **進捗表示**: リアルタイムの進捗バー
- **変更レポート**: 新規・変更・削除ファイルの一覧出力
- **リストア機能**: アーカイブからの復元
- **タスクスケジューラー連携**: 自動実行の設定
- **通知機能**: Windows 通知、Webhook（Slack / Discord / Teams 等）
- **帯域制限**: ネットワーク負荷の制御

## 必要な環境

- Windows 10/11
- PowerShell 5.1 以上
- WSL (Windows Subsystem for Linux)
- WSL 内に `tar`、`gzip` コマンド

### オプション

- **テスト実行**: `Pester` モジュール
- **高機能通知**: `BurntToast` モジュール

```powershell
# オプションモジュールのインストール
Install-Module -Name Pester -Force -SkipPublisherCheck
Install-Module -Name BurntToast -Scope CurrentUser
```

## クイックスタート

### 1. 設定ファイルの編集

`config.psd1` を編集して設定をカスタマイズ:

```powershell
@{
    WslDistro = 'Ubuntu'
    Sources = @('/home/username/projects')
    DestRoot = 'C:\Backup\WSL'
}
```

### 2. バックアップの実行

```powershell
# 通常のバックアップ
.\backup-wsl.ps1

# ドライランモード（確認のみ）
.\backup-wsl.ps1 -DryRun
```

## コマンドライン引数

### バックアップモード

| 引数 | 説明 |
|------|------|
| `-SkipArchive` | アーカイブ作成をスキップ（ミラーリングのみ） |
| `-DryRun` | 実際には実行せず、何が行われるかを表示 |
| `-Source <path>` | バックアップするソースを指定（設定より優先） |
| `-TimeoutMinutes <n>` | タイムアウト時間（デフォルト: 120分） |

### リストアモード

| 引数 | 説明 |
|------|------|
| `-Restore` | リストアモードを有効化 |
| `-RestoreArchive <path>` | リストアするアーカイブファイル |
| `-RestoreTarget <path>` | リストア先のWSLパス |
| `-ListArchives` | 利用可能なアーカイブの一覧表示 |

### スケジュールモード

| 引数 | 説明 |
|------|------|
| `-RegisterScheduledTask` | タスクスケジューラーに登録 |
| `-UnregisterScheduledTask` | タスクスケジューラーから削除 |
| `-ScheduleTime <HH:mm>` | 実行時刻（デフォルト: 02:00） |

### その他

| 引数 | 説明 |
|------|------|
| `-TestExclusions` | 除外パターンのテスト |

## 使用例

```powershell
# 通常のバックアップ
.\backup-wsl.ps1

# ミラーリングのみ（アーカイブなし）
.\backup-wsl.ps1 -SkipArchive

# ドライランモード
.\backup-wsl.ps1 -DryRun

# 特定のディレクトリのみ
.\backup-wsl.ps1 -Source "/home/user/important"

# タイムアウト設定（60分）
.\backup-wsl.ps1 -TimeoutMinutes 60

# アーカイブ一覧表示
.\backup-wsl.ps1 -ListArchives

# リストア
.\backup-wsl.ps1 -Restore -RestoreArchive "C:\Backup\archive.tar.gz" -RestoreTarget "/home/user/restore"

# タスクスケジューラーに登録（毎日3:00に実行）
.\backup-wsl.ps1 -RegisterScheduledTask -ScheduleTime "03:00"

# 除外パターンのテスト
.\backup-wsl.ps1 -TestExclusions
```

## 設定ファイル（config.psd1）

スクリプトと同じディレクトリに配置する PowerShell Data 形式の設定ファイルです。

### 設定項目一覧

#### 基本設定

| 項目 | 型 | デフォルト | 説明 |
|------|-----|---------|------|
| `WslDistro` | string | `Ubuntu` | WSLディストリビューション名（必須） |
| `Sources` | array | - | バックアップ元ディレクトリ（必須） |
| `DestRoot` | string | - | バックアップ先ルート（必須） |

#### 保持設定

| 項目 | 型 | デフォルト | 説明 |
|------|-----|---------|------|
| `KeepCount` | int | `15` | アーカイブ保持個数（0=無制限） |
| `LogKeepCount` | int | `30` | ログ保持個数（0=無制限） |

#### 実行設定

| 項目 | 型 | デフォルト | 説明 |
|------|-----|---------|------|
| `AutoElevate` | bool | `$true` | 管理者権限への自動昇格 |
| `ThreadCount` | int | `0` | robocopy スレッド数（0=自動） |
| `BandwidthLimitMbps` | int | `0` | 帯域制限 Mbps（0=無制限） |

#### ディスク・検証設定

| 項目 | 型 | デフォルト | 説明 |
|------|-----|---------|------|
| `RequiredFreeSpaceGB` | int | `10` | 必要空き容量（GB、0=チェックしない） |
| `VerifyArchive` | bool | `$true` | アーカイブ整合性検証 |
| `SaveChecksums` | bool | `$true` | SHA256 チェックサム保存 |

#### 通知設定

| 項目 | 型 | デフォルト | 説明 |
|------|-----|---------|------|
| `ShowNotification` | bool | `$true` | Windows 通知表示 |
| `NotificationWebhook` | string | `''` | Webhook URL（Slack / Discord 等） |

#### レポート設定

| 項目 | 型 | デフォルト | 説明 |
|------|-----|---------|------|
| `GenerateChangeReport` | bool | `$true` | 変更レポート生成 |

### 設定例

```powershell
@{
    # 基本設定
    WslDistro = 'Ubuntu'
    Sources = @(
        '/home/user/projects'
        '/home/user/.config'
    )
    DestRoot = 'C:\Backup\WSL'

    # 保持個数
    KeepCount = 30
    LogKeepCount = 60

    # 検証
    VerifyArchive = $true
    SaveChecksums = $true

    # Slack通知（オプション）
    NotificationWebhook = 'https://hooks.slack.com/services/xxx/yyy/zzz'
}
```

## 除外パターン（.mirrorignore）

スクリプトと同じディレクトリに `.mirrorignore` ファイルを配置すると、ミラーリング時に指定パターンを除外できます。アーカイブ（tar.gz）には除外は適用されず、ソース全体がバックアップされます。

```txt
# ディレクトリ（末尾に / をつける）
.venv/
node_modules/
.git/
__pycache__/

# ファイル（ワイルドカード使用可）
*.pyc
*.tmp

# ロックされる可能性のあるファイル
*.db
*.db-journal

# IDE/エディタ
.idea/
.vscode/
*.swp
```

## ディレクトリ構造

```
backup-wsl/
├── backup-wsl.ps1          # メインスクリプト
├── config.psd1             # 設定ファイル
├── .mirrorignore           # 除外パターン
├── logs/                   # ログファイル
│   ├── backup_*.log        # メインログ
│   ├── robocopy_*.log      # robocopyログ
│   ├── changes_*.txt       # 変更レポート
│   └── tar_errors_*.log    # tarエラーログ
└── tests/                  # テストファイル
    └── backup-wsl.Tests.ps1

バックアップ先（DestRoot）/
├── mirror/                 # ミラーコピー
│   └── projects/           # ソースディレクトリのコピー
└── archive/                # アーカイブ
    ├── projects_20260215_020000.tar.gz   # アーカイブ
    ├── checksums.json                    # チェックサム
    └── backup-history.json               # バックアップ履歴
```

## 終了コード

| コード | 名前 | 説明 |
|-------|------|------|
| 0 | Success | 正常終了 |
| 1 | LockError | ロック取得失敗（二重実行） |
| 2 | WslError | WSL エラー |
| 3 | DiskSpaceError | ディスク容量不足 |
| 4 | SourceNotFound | ソースが見つからない |
| 5 | PermissionError | 権限エラー |
| 6 | ConfigError | 設定エラー |
| 7 | ValidationError | バリデーションエラー |
| 8 | TimeoutError | タイムアウト |
| 10 | MirrorError | ミラーリングエラー |
| 11 | ArchiveError | アーカイブエラー |
| 12 | RestoreError | リストアエラー |
| 13 | ScheduleError | スケジュールエラー |

## タスクスケジューラーへの登録

バックアップを毎日自動実行するには、Windows タスクスケジューラーに登録します。

### 登録

管理者権限の PowerShell で実行してください。

```powershell
# 毎日 02:00 に実行（デフォルト）
.\backup-wsl.ps1 -RegisterScheduledTask

# 実行時刻を指定（例: 毎日 05:30）
.\backup-wsl.ps1 -RegisterScheduledTask -ScheduleTime "05:30"
```

登録されるタスクの設定:

| 項目 | 値 |
|------|-----|
| タスク名 | `WSL-Backup` |
| トリガー | 毎日（指定時刻） |
| 実行アカウント | `SYSTEM` |
| 実行レベル | 最上位の特権 |
| 実行時間制限 | 4 時間 |
| バッテリー駆動時 | 実行する |
| アイドル条件 | なし |
| スケジュール時刻に PC がオフだった場合 | 次回起動時に実行 |

### 登録状況の確認

```powershell
# PowerShell で確認
Get-ScheduledTask -TaskName 'WSL-Backup' | Format-List

# 次回実行時刻の確認
Get-ScheduledTaskInfo -TaskName 'WSL-Backup' | Select-Object NextRunTime, LastRunTime, LastTaskResult
```

または、`taskschd.msc`（タスクスケジューラ GUI）を開き、「WSL-Backup」を検索してください。

### 登録解除

```powershell
.\backup-wsl.ps1 -UnregisterScheduledTask
```

### 注意事項

- 登録・解除には **管理者権限** が必要です。`AutoElevate = $true`（デフォルト）なら自動で昇格を求められます。
- 既に同名のタスクが存在する場合は、自動的に上書き更新されます。
- タスクは `-WindowStyle Hidden` で実行されるため、バックアップ中にウィンドウは表示されません。結果はログファイルと通知で確認できます。

## テスト

Pester を使用したユニットテスト:

```powershell
# Pesterのインストール
Install-Module -Name Pester -Force -SkipPublisherCheck

# テストの実行
Invoke-Pester -Path .\tests\backup-wsl.Tests.ps1

# 詳細出力
Invoke-Pester -Path .\tests\backup-wsl.Tests.ps1 -Output Detailed
```

## トラブルシューティング

### バックアップが既に実行中

```
エラー: バックアップが既に実行中です。
```

解決方法:
1. 他のバックアッププロセスが実行中でないか確認
2. ロックファイルを手動で削除:
   ```powershell
   Remove-Item "$env:TEMP\backup-wsl-Ubuntu.lock" -Force
   ```

### WSL が応答しない

```
ERROR: WSL health check failed
```

解決方法:
```powershell
# WSLの状態確認
wsl -l -v

# WSLの再起動
wsl --shutdown
wsl -d Ubuntu
```

### ディスク容量不足

```
ERROR: Insufficient disk space
```

解決方法:
1. `RequiredFreeSpaceGB` を調整
2. 古いアーカイブを手動で削除
3. `KeepCount` を小さく設定

### 設定エラー

```
Configuration errors:
  - Required configuration 'Sources' is missing
```

解決方法:
設定ファイル（`config.psd1`）で必須項目（`WslDistro`、`Sources`、`DestRoot`）が設定されているか確認

## 更新履歴

### v2.0.0

- 設定ファイルを `config.psd1` に統一
- 設定バリデーション機能の追加
- アトミックなロックファイル操作
- タイムアウト機能
- 統一終了コード
- リストア機能
- Webhook 通知
- タスクスケジューラー連携
- 変更レポート生成
- チェックサム保存
- 帯域制限
- Pester テスト追加

### v1.0.0

- 初回リリース
- ミラーリングとアーカイブ
- 基本的なログ機能

## ライセンス

MIT License - 詳細は [LICENSE](LICENSE) ファイルを参照してください。
