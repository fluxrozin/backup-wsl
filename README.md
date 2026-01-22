# WSL バックアップスクリプト v2.0

WSL (Windows Subsystem for Linux) のディレクトリを Windows ファイルシステム（NTFS）にバックアップする商用レベルのPowerShellスクリプトです。

## 特徴

### 基本機能

- **高速ミラーリング**: robocopy を使用した Windows ネイティブの高速転送（マルチスレッド対応）
- **柔軟な除外設定**: `.mirrorignore` ファイルで簡単に除外パターンを設定
- **アーカイブ作成**: パーミッションを保持した圧縮 tar.gz アーカイブ
- **自動クリーンアップ**: 古いアーカイブ・ログの自動削除

### セキュリティ機能

- **設定バリデーション**: スキーマベースの厳密な設定値検証
- **パストラバーサル防止**: ソースパスの安全性検証
- **ログマスキング**: 機密情報（パス、パスワード等）の自動マスキング
- **暗号化オプション**: AES-256-CBC によるアーカイブ暗号化

### 堅牢性機能

- **二重実行防止**: アトミックなロックファイル操作
- **タイムアウト機能**: 処理全体のタイムアウト設定
- **統一終了コード**: エラー種別に応じた終了コード
- **WSLヘルスチェック**: バックアップ前のWSL状態確認
- **ディスク容量チェック**: 必要な空き容量の事前確認
- **アーカイブ整合性検証**: 作成したアーカイブの検証
- **チェックサム保存**: SHA256による長期整合性検証

### 効率性機能

- **増分アーカイブ**: 変更ファイルのみをアーカイブ
- **圧縮レベル設定**: 速度と圧縮率のバランス調整
- **帯域制限**: ネットワーク負荷の制御

### 実用性機能

- **進捗表示**: リアルタイムの進捗バー
- **変更レポート**: 新規・変更・削除ファイルの一覧出力
- **リストア機能**: アーカイブからの復元
- **タスクスケジューラー連携**: 自動実行の設定
- **通知機能**: Windows通知、Webhook、メール通知

## 必要な環境

- Windows 10/11
- PowerShell 5.1 以上
- WSL (Windows Subsystem for Linux)
- WSL内に `tar`、`gzip` コマンド
- （暗号化使用時）WSL内に `openssl` コマンド

### オプション

- **TOML設定**: `PSToml` モジュール
- **YAML設定**: `powershell-yaml` モジュール
- **テスト実行**: `Pester` モジュール
- **高機能通知**: `BurntToast` モジュール

```powershell
# オプションモジュールのインストール
Install-Module -Name PSToml -Scope CurrentUser
Install-Module -Name powershell-yaml -Scope CurrentUser
Install-Module -Name Pester -Force -SkipPublisherCheck
Install-Module -Name BurntToast -Scope CurrentUser
```

## クイックスタート

### 1. 設定ファイルの作成

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
| `-Incremental` | 増分アーカイブを作成 |
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

# 増分アーカイブ
.\backup-wsl.ps1 -Incremental

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

## 設定ファイル

### 対応形式（優先順位順）

1. `config.json` - JSON形式（標準）
2. `config.psd1` - PowerShell Data形式（標準、コメント可）
3. `config.toml` - TOML形式（要モジュール）
4. `config.yaml` / `config.yml` - YAML形式（要モジュール）

### 設定項目一覧

#### 基本設定

| 項目 | 型 | デフォルト | 説明 |
|------|-----|---------|------|
| `WslDistro` | string | `Ubuntu` | WSLディストリビューション名 |
| `Sources` | array | - | バックアップ元ディレクトリ（必須） |
| `DestRoot` | string | - | バックアップ先ルート（必須） |

#### 保持期間設定

| 項目 | 型 | デフォルト | 説明 |
|------|-----|---------|------|
| `KeepDays` | int | `15` | アーカイブ保持日数（0=無制限） |
| `LogKeepDays` | int | `30` | ログ保持日数（0=無制限） |

#### 実行設定

| 項目 | 型 | デフォルト | 説明 |
|------|-----|---------|------|
| `AutoElevate` | bool | `$true` | 管理者権限への自動昇格 |
| `ThreadCount` | int | `0` | robocopyスレッド数（0=自動） |
| `BandwidthLimitMbps` | int | `0` | 帯域制限（0=無制限） |

#### 検証設定

| 項目 | 型 | デフォルト | 説明 |
|------|-----|---------|------|
| `RequiredFreeSpaceGB` | int | `10` | 必要空き容量（GB） |
| `VerifyArchive` | bool | `$true` | アーカイブ整合性検証 |
| `SaveChecksums` | bool | `$true` | チェックサム保存 |

#### アーカイブ設定

| 項目 | 型 | デフォルト | 説明 |
|------|-----|---------|------|
| `CompressionLevel` | int | `6` | 圧縮レベル（1-9） |
| `IncrementalBaseDays` | int | `7` | 増分バックアップ基準日数 |

#### 暗号化設定

| 項目 | 型 | デフォルト | 説明 |
|------|-----|---------|------|
| `EnableEncryption` | bool | `$false` | 暗号化有効化 |
| `EncryptionPassword` | string | - | 暗号化パスワード |

#### 通知設定

| 項目 | 型 | デフォルト | 説明 |
|------|-----|---------|------|
| `ShowNotification` | bool | `$true` | Windows通知表示 |
| `NotificationWebhook` | string | - | Webhook URL |
| `NotificationEmail` | string | - | メール通知先 |
| `SmtpServer` | string | - | SMTPサーバー |
| `SmtpPort` | int | `587` | SMTPポート |
| `SmtpFrom` | string | - | 送信元アドレス |

#### レポート設定

| 項目 | 型 | デフォルト | 説明 |
|------|-----|---------|------|
| `GenerateChangeReport` | bool | `$true` | 変更レポート生成 |

### 設定例（PSD1形式）

```powershell
@{
    # 基本設定
    WslDistro = 'Ubuntu'
    Sources = @(
        '/home/user/projects'
        '/home/user/.config'
    )
    DestRoot = 'C:\Backup\WSL'

    # 保持期間
    KeepDays = 30
    LogKeepDays = 60

    # 圧縮設定
    CompressionLevel = 6
    VerifyArchive = $true

    # 暗号化（オプション）
    EnableEncryption = $true
    EncryptionPassword = 'your-secure-password'

    # Slack通知（オプション）
    NotificationWebhook = 'https://hooks.slack.com/services/xxx/yyy/zzz'
}
```

### 設定例（JSON形式）

```json
{
  "WslDistro": "Ubuntu",
  "Sources": ["/home/user/projects"],
  "DestRoot": "C:\\Backup\\WSL",
  "KeepDays": 30,
  "CompressionLevel": 6,
  "EnableEncryption": false,
  "NotificationWebhook": ""
}
```

## 除外パターン（.mirrorignore）

スクリプトと同じディレクトリに `.mirrorignore` ファイルを作成:

```txt
# ディレクトリ（末尾に / をつける）
.venv/
node_modules/
.git/
__pycache__/

# ファイル（ワイルドカード使用可）
*.pyc
*.tmp
*.log

# 機密ファイル
.env
*.pem
*.key
credentials.json
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

バックアップ先/
├── mirror/                 # ミラーコピー
│   └── projects/           # ソースディレクトリのコピー
├── archive/                # アーカイブ
│   ├── projects_full_*.tar.gz      # フルバックアップ
│   ├── projects_incr_*.tar.gz      # 増分バックアップ
│   ├── checksums.json              # チェックサム
│   └── backup-history.json         # バックアップ履歴
```

## 終了コード

| コード | 名前 | 説明 |
|-------|------|------|
| 0 | Success | 正常終了 |
| 1 | LockError | ロック取得失敗（二重実行） |
| 2 | WslError | WSLエラー |
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

## テスト

Pesterを使用したユニットテスト:

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

### WSLが応答しない

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
3. `KeepDays` を短く設定

### 設定エラー

```
Configuration errors:
  - Required configuration 'Sources' is missing
```

解決方法:
設定ファイルで必須項目（`Sources`、`DestRoot`）が設定されているか確認

### 暗号化アーカイブのリストア

```powershell
# パスワードを入力してリストア
.\backup-wsl.ps1 -Restore -RestoreArchive "archive.tar.gz.enc" -RestoreTarget "/restore"
```

## セキュリティに関する注意

1. **設定ファイルの保護**: `EncryptionPassword` を設定する場合、ファイルのアクセス権限を制限してください
2. **機密ファイルの除外**: `.mirrorignore` で機密ファイルを除外設定してください
3. **ログの確認**: ログファイルには機密情報がマスキングされますが、定期的に確認してください

## 更新履歴

### v2.0.0

- 設定バリデーション機能の追加
- アトミックなロックファイル操作
- タイムアウト機能
- 統一終了コード
- 増分アーカイブ対応
- 暗号化オプション
- リストア機能
- Webhook/メール通知
- タスクスケジューラー連携
- 変更レポート生成
- チェックサム保存
- 帯域制限
- Pesterテスト追加

### v1.0.0

- 初回リリース
- ミラーリングとアーカイブ
- 基本的なログ機能

## ライセンス

MIT License - 詳細は [LICENSE](LICENSE) ファイルを参照してください。
