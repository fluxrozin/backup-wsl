# WSL バックアップスクリプト

WSL (Windows Subsystem for Linux) のディレクトリを Windows ファイルシステム（NTFS）にバックアップするシンプルで軽量なスクリプトです。

## 特徴

- **構造化**: 関数ベースの設計で保守性が高い
- **高速**: robocopy を使用した Windows ネイティブの高速転送（マルチスレッド対応）
- **柔軟**: `.mirrorignore` ファイルで簡単に除外パターンを設定
- **安全**: パーミッションを保持したアーカイブ作成、機密ファイルの自動除外
- **自動化**: 古いアーカイブ・ログの自動クリーンアップ
- **監査可能**: 詳細なログ機能で実行履歴を完全に記録
- **自動権限昇格**: ファイル操作で権限エラーが発生した場合、自動的に管理者権限で再試行
- **堅牢**: 二重実行防止、ディスク容量チェック、WSLヘルスチェック、アーカイブ整合性検証
- **外部設定ファイル**: `config.json`（標準）または `config.psd1`（標準）、`config.toml`、`config.yaml` で設定を分離管理
- **複数ソース対応**: 複数のディレクトリを一度にバックアップ可能
- **ドライランモード**: 実行前に何が行われるかを確認可能
- **通知機能**: バックアップ完了時にWindows通知を表示

ミラーリングとアーカイブの両方の機能を提供し、WSL環境のプロジェクトを安全にバックアップできます。

## スクリプト

**`backup-wsl.ps1`** - Windows側から実行するPowerShellスクリプト

- Windows（PowerShell）から実行
- robocopyを使用（Windowsネイティブで高速）
- `\\wsl.localhost\`経由でWSLファイルシステムにアクセス
- `.mirrorignore` ファイルで除外パターンを簡単に設定可能
- 関数ベースの構造化された実装

## 機能

### 3ステップのシンプルなバックアップ処理

1. **ミラーバックアップ**: robocopy を使用してソースディレクトリの同期コピーを作成
   - 増分バックアップ（変更されたファイルのみ転送）
   - `.mirrorignore` ファイルで除外パターンを指定可能
   - Windows で無効な文字を含むファイルを自動除外
   - マルチスレッド転送（スレッド数は自動または手動設定可能）
   - シンボリックリンクのエラーは自動スキップ

2. **アーカイブバックアップ**: パーミッションを保持した圧縮 tar.gz アーカイブを作成
   - タイムスタンプ付きアーカイブファイル（`projects_YYYYMMDD_HHMMSS.tar.gz`）
   - 読み取れないファイルは自動スキップ（`--ignore-failed-read`）
   - WSL経由で実行し、Linuxのパーミッションを保持
   - アーカイブ作成後の整合性検証（オプション）

3. **クリーンアップ**: 古いアーカイブ・ログの自動削除
   - アーカイブ保持期間を設定可能（デフォルト: 15日）
   - ログ保持期間を設定可能（デフォルト: 30日）
   - `KeepDays = 0` で無効化可能

### 堅牢性機能

- **二重実行防止**: ロックファイルにより同時実行を防止
- **WSLヘルスチェック**: バックアップ前にWSLが正常に動作しているか確認
- **ディスク容量チェック**: 必要な空き容量があるか事前確認
- **アーカイブ整合性検証**: 作成したアーカイブが破損していないか検証
- **リトライ機構**: 一時的なエラー時に自動リトライ
- **パス安全性検証**: パストラバーサル攻撃を防止

### ログ機能

バックアップ実行の詳細ログを記録します：

- 実行日時、処理時間（各ステップと全体）
- 転送ファイル数、ディレクトリ数、転送バイト数
- robocopyとtarのエラー・警告の詳細
- 削除失敗した除外ディレクトリの監査ログ
- 実行サマリー（成功/失敗、統計情報）
- すべてのログは `logs/` ディレクトリに保存

## 必要な環境

- Windows 10/11
- PowerShell 5.1 以上（通常は標準搭載）
- WSL (Windows Subsystem for Linux)
- WSL内に `tar` および `gzip` コマンド（アーカイブ作成用）

**オプション（外部モジュールが必要な形式を使用する場合）：**
- TOML形式: `PSToml` モジュール（`Install-Module -Name PSToml -Scope CurrentUser`）
- YAML形式: `powershell-yaml` モジュール（`Install-Module -Name powershell-yaml -Scope CurrentUser`）

## 設定

### 設定ファイル（推奨）

設定ファイルは以下の形式をサポートしています（優先順位順）：

1. **JSON形式**（`config.json`）- **標準モジュールで読み込み可能、推奨**
2. **PSD1形式**（`config.psd1`）- **標準モジュールで読み込み可能**（PowerShell 5以降）
3. **TOML形式**（`config.toml`）- 外部モジュール必要
4. **YAML形式**（`config.yaml` / `config.yml`）- 外部モジュール必要

#### JSON形式（推奨・標準）

```json
{
  "WslDistro": "Ubuntu",
  "Sources": [
    "/home/username/projects",
    "/home/username/.config"
  ],
  "DestRoot": "C:\\Users\\username\\Backup\\Projects_wsl",
  "KeepDays": 15,
  "LogKeepDays": 30,
  "AutoElevate": true,
  "ThreadCount": 0,
  "ShowNotification": true,
  "VerifyArchive": true,
  "RequiredFreeSpaceGB": 10
}
```

#### PSD1形式（標準・コメント可）

```powershell
@{
    # WSLディストリビューション名（wsl -l -v で確認可能）
    WslDistro = 'Ubuntu'

    # バックアップソース（複数指定可能）
    Sources = @(
        '/home/username/projects'
        '/home/username/.config'
    )

    # Windows側のバックアップ先ルートディレクトリ
    DestRoot = 'C:\Users\username\Backup\Projects_wsl'

    # アーカイブを保持する日数（0 = すべて保持）
    KeepDays = 15

    # ログファイルを保持する日数（0 = すべて保持）
    LogKeepDays = 30

    # 管理者権限が必要な場合、自動的に昇格するか
    AutoElevate = $true

    # robocopyのスレッド数（0 = 自動、CPUコア数に基づいて決定）
    ThreadCount = 0

    # バックアップ完了時にWindows通知を表示するか
    ShowNotification = $true

    # アーカイブ作成後に整合性検証を行うか
    VerifyArchive = $true

    # 必要な空きディスク容量（GB）（0 = チェックしない）
    RequiredFreeSpaceGB = 10
}
```

#### TOML形式

```toml
# WSLディストリビューション名（wsl -l -v で確認可能）
WslDistro = 'Ubuntu'

# バックアップソース（複数指定可能）
Sources = [
    '/home/username/projects',
    '/home/username/.config'
]

# Windows側のバックアップ先ルートディレクトリ
DestRoot = 'C:\\Users\\username\\Backup\\Projects_wsl'

# アーカイブを保持する日数（0 = すべて保持）
KeepDays = 15

# ログファイルを保持する日数（0 = すべて保持）
LogKeepDays = 30

# 管理者権限が必要な場合、自動的に昇格するか
AutoElevate = true

# robocopyのスレッド数（0 = 自動、CPUコア数に基づいて決定）
ThreadCount = 0

# バックアップ完了時にWindows通知を表示するか
ShowNotification = true

# アーカイブ作成後に整合性検証を行うか
VerifyArchive = true

# 必要な空きディスク容量（GB）（0 = チェックしない）
RequiredFreeSpaceGB = 10
```

#### YAML形式

```yaml
# WSLディストリビューション名（wsl -l -v で確認可能）
WslDistro: Ubuntu

# バックアップソース（複数指定可能）
Sources:
  - /home/username/projects
  - /home/username/.config

# Windows側のバックアップ先ルートディレクトリ
DestRoot: C:\Users\username\Backup\Projects_wsl

# アーカイブを保持する日数（0 = すべて保持）
KeepDays: 15

# ログファイルを保持する日数（0 = すべて保持）
LogKeepDays: 30

# 管理者権限が必要な場合、自動的に昇格するか
AutoElevate: true

# robocopyのスレッド数（0 = 自動、CPUコア数に基づいて決定）
ThreadCount: 0

# バックアップ完了時にWindows通知を表示するか
ShowNotification: true

# アーカイブ作成後に整合性検証を行うか
VerifyArchive: true

# 必要な空きディスク容量（GB）（0 = チェックしない）
RequiredFreeSpaceGB: 10
```

**注意事項：**

- **JSON形式とPSD1形式は標準モジュールで読み込めます**（外部モジュール不要）
- TOML形式を使用する場合: `Install-Module -Name PSToml -Scope CurrentUser`
- YAML形式を使用する場合: `Install-Module -Name powershell-yaml -Scope CurrentUser`

### 設定項目の説明

| 設定項目               | 説明                                       | デフォルト値 |
| ---------------------- | ------------------------------------------ | ------------ |
| `WslDistro`            | WSLディストリビューション名                | `Ubuntu`     |
| `Sources`              | バックアップするソースディレクトリ（配列） | -            |
| `DestRoot`             | Windows側のバックアップ先                  | -            |
| `KeepDays`             | アーカイブを保持する日数                   | `15`         |
| `LogKeepDays`          | ログファイルを保持する日数                 | `30`         |
| `AutoElevate`          | 管理者権限への自動昇格                     | `$true`      |
| `ThreadCount`          | robocopyのスレッド数（0=自動）             | `0`          |
| `ShowNotification`     | 完了通知の表示                             | `$true`      |
| `VerifyArchive`        | アーカイブ整合性検証                       | `$true`      |
| `RequiredFreeSpaceGB`  | 必要な空きディスク容量（GB）               | `10`         |

### WSLディストリビューション名の確認方法

```powershell
wsl -l -v
```

### 除外パターンの設定（.mirrorignore）

`backup-wsl.ps1` と同じディレクトリに `.mirrorignore` ファイルを作成することで、ミラーリングから除外するファイルやディレクトリを指定できます。

#### 書式

- ディレクトリを除外する場合: 末尾に `/` を付ける（例: `.venv/`）
- ファイルを除外する場合: ワイルドカード使用可能（例: `*.pyc`）
- コメント: `#` で始まる行は無視される

#### 例

```txt
# Python
.venv/
__pycache__/
*.pyc

# Node.js
node_modules/

# Git
.git/

# ロックされる可能性のあるファイル
*.db

# 機密ファイル（セキュリティ上の理由で除外）
*.pem
*.key
.env
credentials.json
```

### 注意事項

- `WslDistro` は正確なディストリビューション名を指定（大文字小文字を区別）
- `KeepDays`: `0` に設定するとアーカイブの自動削除を無効化
- `AutoElevate`: `$true` の場合、管理者権限が必要なときに自動的に昇格します

## 使用方法

### 基本的な使い方

1. PowerShellを開く（通常のユーザー権限で実行可能）

2. スクリプトの実行ポリシーを確認（必要に応じて変更）：

```powershell
Get-ExecutionPolicy
# もし Restricted の場合は、以下を実行（管理者権限が必要）：
# Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

1. バックアップを実行：

```powershell
.\backup-wsl.ps1
```

または、PowerShellから直接：

```powershell
powershell -ExecutionPolicy Bypass -File .\backup-wsl.ps1
```

### コマンドライン引数

| 引数             | 説明                                                             |
| ---------------- | ---------------------------------------------------------------- |
| `-SkipArchive`   | アーカイブ作成をスキップ（ミラーリングのみ実行）                 |
| `-DryRun`        | 実際には実行せず、何が行われるかを表示                           |
| `-Source <path>` | バックアップするソースディレクトリを指定（設定ファイルより優先） |

### 使用例

```powershell
# 通常のバックアップ
.\backup-wsl.ps1

# アーカイブ作成をスキップ（ミラーリングのみ）
.\backup-wsl.ps1 -SkipArchive

# ドライランモード（何が実行されるか確認）
.\backup-wsl.ps1 -DryRun

# 特定のディレクトリのみバックアップ
.\backup-wsl.ps1 -Source "/home/aoki/important-project"

# 組み合わせ
.\backup-wsl.ps1 -DryRun -SkipArchive
```

## ディレクトリ構造

スクリプトは以下の構造を作成します：

```txt
# バックアップ先（DEST_ROOT）
DEST_ROOT/
├── mirror/                 # ソースディレクトリの同期ミラー
│   ├── projects/           # 複数ソースの場合はサブディレクトリに分離
│   └── config/
└── archive/                # 圧縮アーカイブファイル
    ├── projects_YYYYMMDD_HHMMSS.tar.gz
    └── config_YYYYMMDD_HHMMSS.tar.gz

# スクリプトフォルダ
backup-wsl/
├── backup-wsl.ps1          # スクリプト本体
├── config.json             # 設定ファイル（JSON形式、標準・推奨）
├── config.psd1             # 設定ファイル（PSD1形式、標準）
├── config.toml             # 設定ファイル（TOML形式、オプション）
└── config.yaml             # 設定ファイル（YAML形式、オプション）
├── .mirrorignore           # 除外パターン設定
└── logs/                   # ログファイル（スクリプトフォルダに保存）
    ├── backup_YYYYMMDD_HHMMSS.log          # メインログ
    ├── robocopy_YYYYMMDD_HHMMSS.log        # robocopyログ
    ├── tar_errors_YYYYMMDD_HHMMSS.log      # tarエラーログ
    └── cleanup_audit_YYYYMMDD_HHMMSS.log   # クリーンアップ監査ログ
```

## 出力

スクリプトは簡潔な進捗情報を表示します：

- バックアップ開始情報（ソース、宛先）
- WSLヘルスチェック、ディスク容量チェックの結果
- ミラーリングの結果（終了コード）
- アーカイブ作成の状態とサイズ
- 整合性検証の結果
- 古いアーカイブのクリーンアップ状態

### 実行例

```txt
設定ファイルを読み込みました: C:\...\config.json
WSL Backup: /home/username/projects -> C:\Users\username\Backup\Projects_wsl
Checking WSL health...
[1.1/1] Mirroring /home/username/projects...
  OK (exit=2)
[2.1/1] Creating archive for /home/username/projects...
  OK: projects_20260121_095841.tar.gz (12345.6 MB)
  Verifying archive...
  Integrity check: OK
[3/3] Cleanup...
  Deleted 2 old archive(s)
Done.
```

### ドライランモードの出力例

```txt
=== DRY RUN MODE ===
実際には何も変更されません。

WSL Backup: /home/username/projects -> C:\Users\username\Backup\Projects_wsl
Checking WSL health...
[DryRun] [2026-01-21 10:00:00] [INFO] === Step 1: Mirroring Started ===
[DryRun] [2026-01-21 10:00:00] [INFO] Would run robocopy from \\wsl.localhost\... to C:\...
...
```

## エラーハンドリング

- robocopy の終了コード 0-7 は成功とみなします（8以上は警告）
- 警告は表示されますが、バックアッププロセスは停止しません
- robocopy の状態に関係なくアーカイブ作成は実行されます
- tar コマンドは `--ignore-failed-read` オプションを使用し、読み取れないファイルは自動スキップされます
- 一時的なエラーは自動リトライされます

## トラブルシューティング

### WSLファイルシステムにアクセスできない

エラー: "Source directory does not exist" または "WSL health check failed"

解決方法：

1. WSLディストリビューション名が正しいか確認：

   ```powershell
   wsl -l -v
   ```

2. WSLが実行中か確認：

   ```powershell
   wsl -d Ubuntu echo "WSL is running"
   ```

3. ソースパスがWSL内に存在するか確認：

   ```powershell
   wsl -d Ubuntu -e bash -c "test -d '/home/username/projects' && echo 'Directory exists'"
   ```

### バックアップが既に実行中

エラー: "バックアップが既に実行中です"

解決方法：

1. 他のバックアッププロセスが実行中でないか確認
2. 前回のバックアップが異常終了した場合、ロックファイルを手動で削除：

   ```powershell
   Remove-Item "$env:TEMP\backup-wsl-Ubuntu.lock" -Force
   ```

### ディスク容量不足

エラー: "Insufficient disk space"

解決方法：

1. バックアップ先のディスク容量を確認
2. `config.json`（または使用している設定ファイル）の `RequiredFreeSpaceGB` を調整
3. 古いアーカイブを手動で削除

### robocopy エラーコード 8以上

このエラーは、一部のファイルが転送できなかったことを示します。一般的な原因：

- Windows ファイルシステムのパス長制限
- 無効な文字を含むファイル（自動的に除外されます）
- 権限の問題
- ディスク容量不足
- シンボリックリンクの問題

スクリプトは適切に処理し、バックアップを続行します。

### PowerShell実行ポリシーのエラー

エラー: "cannot be loaded because running scripts is disabled"

解決方法：

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

または、実行時にバイパス：

```powershell
powershell -ExecutionPolicy Bypass -File .\backup-wsl.ps1
```

## 補足情報

### アーカイブサイズ

アーカイブは Linux ファイルのパーミッションを保持し、完全な復元に適しています。通常、ソースディレクトリの30-50%程度のサイズ（圧縮後）になります。

### 読み取れないファイル

一部のファイル（ロックされているデータベースファイルなど）は読み取れない場合があります。`backup-wsl.ps1` は `--ignore-failed-read` オプションを使用しているため、これらのファイルは自動的にスキップされ、バックアップは続行されます。

### 管理者権限の自動取得

スクリプトは通常のユーザー権限で実行できますが、ディレクトリ作成などで管理者権限が必要な場合、自動的に管理者権限で実行します。

**動作の仕組み：**

1. **権限チェック**: スクリプトの最初で、ディレクトリ作成に必要な権限があるかチェックします
2. **自動的な権限昇格**: 権限が不足している場合、同じスクリプトを管理者権限で再実行します
3. **コマンドライン引数の保持**: `-SkipArchive`、`-DryRun`、`-Source` などの引数は再実行時にも保持されます

**重要な制限事項：**

- 管理者権限への昇格が可能なのは、ユーザーがAdministratorsグループのメンバーの場合のみです
- `AutoElevate = $false` に設定すると、管理者権限が必要な場合でも自動昇格しません

### Windows通知

バックアップ完了時にWindows通知を表示できます。`BurntToast` モジュールがインストールされている場合はそれを使用し、なければ標準の通知APIを使用します。

```powershell
# BurntToastのインストール（オプション）
Install-Module -Name BurntToast -Scope CurrentUser
```

## ライセンス

MIT License - 詳細は [LICENSE](LICENSE) ファイルを参照してください。
