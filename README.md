# WSL バックアップスクリプト

WSL (Windows Subsystem for Linux) のディレクトリを Windows ファイルシステム（NTFS）にバックアップするシンプルで軽量なスクリプトです。

## 特徴

- **シンプル**: 約200行の軽量な実装
- **高速**: robocopy を使用した Windows ネイティブの高速転送
- **柔軟**: `.mirrorignore` ファイルで簡単に除外パターンを設定
- **安全**: パーミッションを保持したアーカイブ作成
- **自動化**: 古いアーカイブの自動クリーンアップ
- **監査可能**: 詳細なログ機能で実行履歴を完全に記録

ミラーリングとアーカイブの両方の機能を提供し、WSL環境のプロジェクトを安全にバックアップできます。

## スクリプト

**`backup-wsl.ps1`** - Windows側から実行するPowerShellスクリプト

- Windows（PowerShell）から実行
- robocopyを使用（Windowsネイティブで高速）
- `\\wsl.localhost\`経由でWSLファイルシステムにアクセス
- `.mirrorignore` ファイルで除外パターンを簡単に設定可能
- シンプルで軽量な実装（約120行）

## 機能

### 3ステップのシンプルなバックアップ処理

1. **ミラーバックアップ**: robocopy を使用してソースディレクトリの同期コピーを作成
   - 増分バックアップ（変更されたファイルのみ転送）
   - `.mirrorignore` ファイルで除外パターンを指定可能
   - Windows で無効な文字を含むファイルを自動除外
   - マルチスレッド転送（`/MT`オプション）で高速
   - シンボリックリンクのエラーは自動スキップ

2. **アーカイブバックアップ**: パーミッションを保持した圧縮 tar.gz アーカイブを作成
   - タイムスタンプ付きアーカイブファイル（`projects_YYYYMMDD_HHMMSS.tar.gz`）
   - 読み取れないファイルは自動スキップ（`--ignore-failed-read`）
   - WSL経由で実行し、Linuxのパーミッションを保持

3. **クリーンアップ**: 古いアーカイブの自動削除
   - 保持期間を設定可能（デフォルト: 15日）
   - `KeepDays = 0` で無効化可能

4. **ログ機能**: バックアップ実行の詳細ログを記録
   - 実行日時、処理時間（各ステップと全体）
   - 転送ファイル数、ディレクトリ数、転送バイト数
   - robocopyとtarのエラー・警告の詳細
   - 削除失敗した除外ディレクトリの監査ログ
   - 実行サマリー（成功/失敗、統計情報）
   - すべてのログは `logs/` ディレクトリに保存

5. **アーカイブスキップ機能**: タスクスケジューラ実行時にアーカイブ作成をスキップ
   - `-SkipArchive` コマンドライン引数でアーカイブ作成を無効化
   - ミラーバックアップのみを実行し、高速化を実現
   - ログに「SKIPPED」として記録

## 実装予定機能

以下の機能を今後追加予定です：

- **進捗表示機能**: バックアップ処理の詳細な進捗情報を表示
  - 転送中のファイル名、転送速度、残り時間などの表示
  - より詳細な進捗バーとパーセンテージ表示

## 必要な環境

- Windows 10/11
- PowerShell 5.1 以上（通常は標準搭載）
- WSL (Windows Subsystem for Linux)
- WSL内に `tar` および `gzip` コマンド（アーカイブ作成用）

## 設定

`backup-wsl.ps1` 内の `$Config` ハッシュテーブルを編集してください：

```powershell
$Config = @{
    WslDistro   = "Ubuntu"                              # WSLディストリビューション名
    SourceDir   = "/home/username/projects"             # WSL内のソースディレクトリ
    DestRoot    = "C:\Users\username\Backup\Projects_wsl"  # Windows側のバックアップ先
    KeepDays    = 15                                    # アーカイブを保持する日数（0 = すべて保持）
    SkipArchive = $false                                # アーカイブ作成をスキップするか（$true = スキップ）
}
```

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
```

### 注意事項

- `WslDistro` は正確なディストリビューション名を指定（大文字小文字を区別）
- `KeepDays`: `0` に設定するとアーカイブの自動削除を無効化
- `SkipArchive`: `$true` に設定するとアーカイブ作成をスキップ（ミラーバックアップのみ実行）

## 使用方法

1. PowerShellを開く（管理者権限は不要）

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

### アーカイブ作成をスキップ

タスクスケジューラなどで定期的にミラーバックアップのみを実行する場合、アーカイブ作成をスキップして高速化できます。

#### 方法1: 設定ファイルで設定

`backup-wsl.ps1` の `$Config` で `SkipArchive = $true` に設定：

```powershell
$Config = @{
    # ... 他の設定 ...
    SkipArchive = $true  # アーカイブ作成をスキップ
}
```

#### 方法2: コマンドライン引数で指定

```powershell
.\backup-wsl.ps1 -SkipArchive
```

このオプションを使用すると：

- ミラーバックアップのみを実行（高速）
- アーカイブ作成をスキップ
- クリーンアップは通常通り実行
- ログには「SKIPPED」として記録

## ディレクトリ構造

スクリプトは `DEST_ROOT` 配下に以下の構造を作成します：

```txt
DEST_ROOT/
├── mirror/                 # ソースディレクトリの同期ミラー
├── archive/                # 圧縮アーカイブファイル
│   └── projects_YYYYMMDD_HHMMSS.tar.gz
└── logs/                   # ログファイル
    ├── backup_YYYYMMDD_HHMMSS.log          # メインログ
    ├── robocopy_YYYYMMDD_HHMMSS.log        # robocopyログ
    ├── tar_errors_YYYYMMDD_HHMMSS.log      # tarエラーログ
    └── cleanup_audit_YYYYMMDD_HHMMSS.log   # クリーンアップ監査ログ
```

## 出力

スクリプトは簡潔な進捗情報を表示します：

- バックアップ開始情報（ソース、宛先）
- ミラーリングの結果（終了コード）
- アーカイブ作成の状態とサイズ
- 古いアーカイブのクリーンアップ状態

### 実行例

```txt
WSL Backup: /home/username/projects -> C:\Users\username\Backup\Projects_wsl
[1/3] Mirroring...
  OK (exit=2)
[2/3] Creating archive...
  OK: projects_20260121_095841.tar.gz (12345.6 MB)
[3/3] Cleanup...
  Deleted 2 old archive(s)
Done.
```

**注意：** 一部のファイル（シンボリックリンクやロックされているファイル）でエラーが表示されることがありますが、これらは自動的にスキップされ、バックアップは正常に続行されます。

## ログ機能

スクリプトは各バックアップ実行の詳細なログを `logs/` ディレクトリに記録します。

### ログファイルの種類

- **`backup_YYYYMMDD_HHMMSS.log`**: メインログファイル
  - 実行日時、処理時間（各ステップと全体）
  - 転送ファイル数、ディレクトリ数、転送バイト数
  - エラー・警告の詳細
  - 実行サマリー

- **`robocopy_YYYYMMDD_HHMMSS.log`**: robocopyの詳細ログ
  - 転送されたファイルの一覧
  - robocopyの統計情報

- **`tar_errors_YYYYMMDD_HHMMSS.log`**: tarコマンドのエラー・警告
  - 読み取れなかったファイルの一覧

- **`cleanup_audit_YYYYMMDD_HHMMSS.log`**: クリーンアップ監査ログ
  - 削除に失敗した除外ディレクトリの記録

### ログの内容

各ログファイルには以下の情報が含まれます：

- **実行情報**: 開始時刻、終了時刻、総処理時間
- **ステップ別処理時間**: ミラーリング、アーカイブ作成、クリーンアップの各処理時間
- **転送統計**: ファイル数、ディレクトリ数、転送バイト数
- **エラー・警告**: 発生したエラーや警告の詳細
- **サマリー**: 実行結果の要約と統計情報

ログファイルはUTF-8エンコーディングで保存され、後で監査や分析に使用できます。

## パフォーマンス

### backup-wsl.ps1 の特徴

- robocopyはWindowsネイティブで高速
- Windowsファイルシステムへの直接アクセスでオーバーヘッドが少ない
- マルチスレッド転送（`/MT`オプション）で並列処理が可能
- `.mirrorignore` ファイルで簡単に除外パターンを設定可能
- 詳細なログ機能で実行履歴を完全に記録
- シンプルで軽量な実装（約200行）

## エラーハンドリング

- robocopy の終了コード 0-7 は成功とみなします（8以上は警告）
- 警告は表示されますが、バックアッププロセスは停止しません
- robocopy の状態に関係なくアーカイブ作成は実行されます
- tar コマンドは `--ignore-failed-read` オプションを使用し、読み取れないファイルは自動スキップされます

## トラブルシューティング

### WSLファイルシステムにアクセスできない

エラー: "Source directory does not exist"

解決方法：

1. WSLディストリビューション名が正しいか確認：

   ```powershell
   wsl -l -v
   ```

2. WSLが実行中か確認：

   ```powershell
   wsl -d $WSL_DISTRO echo "WSL is running"
   ```

3. ソースパスがWSL内に存在するか確認：

   ```powershell
   wsl -d $WSL_DISTRO -e bash -c "test -d '$SOURCE_DIR' && echo 'Directory exists'"
   ```

### robocopy エラーコード 8以上

このエラーは、一部のファイルが転送できなかったことを示します。一般的な原因：

- Windows ファイルシステムのパス長制限
- 無効な文字を含むファイル（自動的に除外されます）
- 権限の問題
- ディスク容量不足
- シンボリックリンクの問題（`lib64` など）

スクリプトは適切に処理し、バックアップを続行します。エラーメッセージを確認してください。

### robocopy エラーコード 123

エラー123は、コピー先ディレクトリに無効な文字が含まれているファイル/ディレクトリが存在する場合に発生します。

解決方法：

1. コピー先ディレクトリ（`mirror`）を手動で削除またはリネーム
2. スクリプトを再実行

### シンボリックリンクのエラー（エラーコード 3）

`.venv/lib64` などのシンボリックリンクが「指定されたパスが見つかりません」というエラーになることがあります。これは正常な動作で、シンボリックリンクは自動的にスキップされます。バックアップは続行されます。

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

一部のファイル（ロックされているデータベースファイルなど）は読み取れない場合があります。`backup-wsl.ps1` は `--ignore-failed-read` オプションを使用しているため、これらのファイルは自動的にスキップされ、バックアップは続行されます。エラーメッセージが表示されますが、バックアッププロセスは停止しません。詳細は `logs/tar_errors_*.log` に記録されます。

### 除外ディレクトリの削除失敗

除外対象のディレクトリ（`.git` など）がミラー先に残っている場合、スクリプトは事前に削除を試みます。削除に失敗した場合（ファイルが使用中など）は、エラーを表示せずに処理を続行しますが、詳細は `logs/cleanup_audit_*.log` に記録されます。

## ライセンス

MIT License - 詳細は [LICENSE](LICENSE) ファイルを参照してください。
