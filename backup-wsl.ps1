#Requires -Version 5.1
<#
.SYNOPSIS
    WSL/Windows バックアップスクリプト
.DESCRIPTION
    WSLおよびWindowsのディレクトリをミラーリング＆アーカイブ保存
    - WSLソース（/始まり）→ tar.gz アーカイブ（権限情報保持）
    - Windowsソース（C:\始まり）→ zip アーカイブ
    - WSL/Windowsの混在ソースをサポート
    - 複数ソースディレクトリのサポート
    - 外部設定ファイル（config.psd1）対応
    - ドライランモード、二重実行防止、整合性検証など堅牢な設計
    - リストア機能対応
    - Webhook通知、タスクスケジューラー連携
.PARAMETER SkipArchive
    アーカイブ作成をスキップします。ミラーバックアップのみを実行します。
.PARAMETER DryRun
    実際には実行せず、何が行われるかを表示します。
.PARAMETER Source
    バックアップするソースディレクトリを指定します（設定ファイルより優先）。
.PARAMETER Restore
    リストアモードを有効にします。-RestoreTarget と組み合わせて使用します。
.PARAMETER RestoreTarget
    リストア先のディレクトリを指定します。
.PARAMETER RestoreArchive
    リストアに使用するアーカイブファイルを指定します。
.PARAMETER ListArchives
    利用可能なアーカイブの一覧を表示します。
.PARAMETER RegisterScheduledTask
    タスクスケジューラーにバックアップタスクを登録します。
.PARAMETER UnregisterScheduledTask
    タスクスケジューラーからバックアップタスクを削除します。
.PARAMETER ScheduleTime
    スケジュール実行時刻を指定します（デフォルト: 02:00）。
.PARAMETER TestExclusions
    除外パターンのテストモードを有効にします。
.PARAMETER TimeoutMinutes
    バックアップ処理全体のタイムアウト時間（分）を指定します。
.NOTES
    Windows側から実行
    Version: 2.0.0
#>

[CmdletBinding(DefaultParameterSetName = 'Backup')]
param(
    [Parameter(ParameterSetName = 'Backup')]
    [switch]$SkipArchive,

    [Parameter(ParameterSetName = 'Backup')]
    [Parameter(ParameterSetName = 'Restore')]
    [switch]$DryRun,

    [Parameter(ParameterSetName = 'Backup')]
    [string]$Source,

    [Parameter(ParameterSetName = 'Restore', Mandatory = $true)]
    [switch]$Restore,

    [Parameter(ParameterSetName = 'Restore')]
    [string]$RestoreTarget,

    [Parameter(ParameterSetName = 'Restore')]
    [string]$RestoreArchive,

    [Parameter(ParameterSetName = 'ListArchives')]
    [switch]$ListArchives,

    [Parameter(ParameterSetName = 'Schedule')]
    [switch]$RegisterScheduledTask,

    [Parameter(ParameterSetName = 'Unschedule')]
    [switch]$UnregisterScheduledTask,

    [Parameter(ParameterSetName = 'Schedule')]
    [string]$ScheduleTime = '02:00',

    [Parameter(ParameterSetName = 'TestExclusions')]
    [switch]$TestExclusions,

    [Parameter(ParameterSetName = 'Backup')]
    [int]$TimeoutMinutes = 120
)

# ============================================================================
# 終了コード定数
# ============================================================================

$Script:ExitCodes = @{
    Success         = 0
    LockError       = 1
    WslError        = 2
    DiskSpaceError  = 3
    SourceNotFound  = 4
    PermissionError = 5
    ConfigError     = 6
    ValidationError = 7
    TimeoutError    = 8
    MirrorError     = 10
    ArchiveError    = 11
    RestoreError    = 12
    ScheduleError   = 13
}

# ============================================================================
# 定数
# ============================================================================

$Script:Constants = @{
    RobocopySuccessMaxExitCode = 7
    DefaultKeepCount           = 15
    DefaultLogKeepCount        = 30
    LogDateFormat              = 'yyyy-MM-dd HH:mm:ss'
    TimestampFormat            = 'yyyyMMdd_HHmmss'
    LockFileName               = 'backup-wsl.lock'
    ConfigFileName             = 'config.psd1'
    MinRequiredFreeSpaceGB     = 1
    HistoryFileName            = 'backup-history.json'
    ChecksumFileName           = 'checksums.json'
    Version                    = '2.1.0'
}

# ============================================================================
# 設定スキーマ（バリデーション用）
# ============================================================================

$Script:ConfigSchema = @{
    WslDistro            = @{
        Type     = 'string'
        Required = $false
        Pattern  = '^[a-zA-Z0-9_-]+$'
        Default  = 'Ubuntu'
        Message  = 'WslDistro must contain only alphanumeric characters, underscores, and hyphens'
    }
    Sources              = @{
        Type     = 'array'
        Required = $true
        MinItems = 1
        Message  = 'Sources must be a non-empty array of paths or @{ Path = "..."; Name = "..." } entries'
    }
    DestRoot             = @{
        Type     = 'string'
        Required = $true
        Message  = 'DestRoot must be a valid Windows path'
    }
    KeepCount            = @{
        Type    = 'int'
        Min     = 0
        Max     = 9999
        Default = 15
        Message = 'KeepCount must be between 0 and 9999'
    }
    LogKeepCount         = @{
        Type    = 'int'
        Min     = 0
        Max     = 9999
        Default = 30
        Message = 'LogKeepCount must be between 0 and 9999'
    }
    AutoElevate          = @{
        Type    = 'bool'
        Default = $true
    }
    ThreadCount          = @{
        Type    = 'int'
        Min     = 0
        Max     = 128
        Default = 0
        Message = 'ThreadCount must be between 0 and 128'
    }
    BandwidthLimitMbps   = @{
        Type    = 'int'
        Min     = 0
        Max     = 10000
        Default = 0
        Message = 'BandwidthLimitMbps must be between 0 (unlimited) and 10000'
    }
    RequiredFreeSpaceGB  = @{
        Type    = 'int'
        Min     = 0
        Max     = 10000
        Default = 10
        Message = 'RequiredFreeSpaceGB must be between 0 and 10000'
    }
    VerifyArchive        = @{
        Type    = 'bool'
        Default = $true
    }
    SaveChecksums        = @{
        Type    = 'bool'
        Default = $true
    }
    ShowNotification     = @{
        Type    = 'bool'
        Default = $true
    }
    NotificationWebhook  = @{
        Type    = 'string'
        Default = ''
    }
    GenerateChangeReport = @{
        Type    = 'bool'
        Default = $true
    }
}

# ============================================================================
# 設定バリデーション
# ============================================================================

function Test-ConfigValue {
    param(
        [string]$Key,
        $Value,
        [hashtable]$Schema
    )

    $rule = $Schema[$Key]
    if (-not $rule) {
        return @{ Valid = $true; Value = $Value }
    }

    # 型チェック
    switch ($rule.Type) {
        'string' {
            if ($Value -isnot [string]) {
                if ($null -eq $Value -and -not $rule.Required) {
                    return @{ Valid = $true; Value = $rule.Default }
                }
                return @{ Valid = $false; Message = "$Key must be a string" }
            }
            if ($rule.Pattern -and $Value -notmatch $rule.Pattern) {
                return @{ Valid = $false; Message = $rule.Message }
            }
        }
        'int' {
            $intValue = $Value -as [int]
            if ($null -eq $intValue) {
                if ($null -eq $Value) {
                    return @{ Valid = $true; Value = $rule.Default }
                }
                return @{ Valid = $false; Message = "$Key must be an integer" }
            }
            if ($null -ne $rule.Min -and $intValue -lt $rule.Min) {
                return @{ Valid = $false; Message = $rule.Message }
            }
            if ($null -ne $rule.Max -and $intValue -gt $rule.Max) {
                return @{ Valid = $false; Message = $rule.Message }
            }
            return @{ Valid = $true; Value = $intValue }
        }
        'bool' {
            if ($Value -is [bool]) {
                return @{ Valid = $true; Value = $Value }
            }
            if ($Value -eq 'true' -or $Value -eq '$true' -or $Value -eq 1) {
                return @{ Valid = $true; Value = $true }
            }
            if ($Value -eq 'false' -or $Value -eq '$false' -or $Value -eq 0) {
                return @{ Valid = $true; Value = $false }
            }
            if ($null -eq $Value) {
                return @{ Valid = $true; Value = $rule.Default }
            }
            return @{ Valid = $false; Message = "$Key must be a boolean" }
        }
        'array' {
            if ($Value -is [array] -or $Value -is [System.Collections.ArrayList]) {
                if ($rule.MinItems -and $Value.Count -lt $rule.MinItems) {
                    return @{ Valid = $false; Message = $rule.Message }
                }
                return @{ Valid = $true; Value = @($Value) }
            }
            if ($null -eq $Value -and -not $rule.Required) {
                return @{ Valid = $true; Value = @() }
            }
            return @{ Valid = $false; Message = "$Key must be an array" }
        }
    }

    return @{ Valid = $true; Value = $Value }
}

function Test-BackupConfig {
    param([hashtable]$Config)

    $errors = @()
    $validated = @{}

    foreach ($key in $Script:ConfigSchema.Keys) {
        $rule = $Script:ConfigSchema[$key]
        $value = $Config[$key]

        # 必須チェック
        if ($rule.Required -and ($null -eq $value -or $value -eq '')) {
            $errors += "Required configuration '$key' is missing"
            continue
        }

        # バリデーション
        $result = Test-ConfigValue -Key $key -Value $value -Schema $Script:ConfigSchema
        if (-not $result.Valid) {
            $errors += $result.Message
        } else {
            $validated[$key] = $result.Value
        }
    }

    # 追加のバリデーション: DestRootのパス形式
    if ($validated.DestRoot) {
        if ($validated.DestRoot -notmatch '^[A-Za-z]:\\') {
            $errors += 'DestRoot must be an absolute Windows path (e.g., C:\Backup)'
        }
    }

    return @{
        Valid     = $errors.Count -eq 0
        Errors    = $errors
        Validated = $validated
    }
}

# ============================================================================
# 設定読み込み
# ============================================================================

function Import-BackupConfig {
    param([string]$ConfigPath)

    $defaultConfig = @{
        WslDistro            = 'Ubuntu'
        Sources              = @()
        DestRoot             = ''
        KeepCount            = $Script:Constants.DefaultKeepCount
        LogKeepCount         = $Script:Constants.DefaultLogKeepCount
        AutoElevate          = $true
        ThreadCount          = 0
        BandwidthLimitMbps   = 0
        RequiredFreeSpaceGB  = 10
        VerifyArchive        = $true
        SaveChecksums        = $true
        ShowNotification     = $true
        NotificationWebhook  = ''
        GenerateChangeReport = $true
    }

    if (Test-Path $ConfigPath) {
        try {
            $userConfig = Import-PowerShellDataFile -Path $ConfigPath

            # 設定をマージ
            foreach ($key in $userConfig.Keys) {
                $defaultConfig[$key] = $userConfig[$key]
            }

            Write-Host "設定ファイルを読み込みました: $ConfigPath" -ForegroundColor Gray
        } catch {
            Write-Host "警告: 設定ファイルの読み込みに失敗しました: $_" -ForegroundColor Yellow
            return @{ Config = $defaultConfig; Valid = $false; Errors = @("Failed to load config: $_") }
        }
    } else {
        Write-Host "設定ファイルが見つかりません: $ConfigPath" -ForegroundColor Yellow
        return @{ Config = $defaultConfig; Valid = $false; Errors = @("Config file not found: $ConfigPath") }
    }

    # バリデーション
    $validation = Test-BackupConfig -Config $defaultConfig

    return @{
        Config = $defaultConfig
        Valid  = $validation.Valid
        Errors = $validation.Errors
    }
}

# ============================================================================
# 管理者権限チェック
# ============================================================================

function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Administrator {
    param(
        [string]$ScriptPath,
        [string[]]$Arguments
    )

    if (Test-Administrator) {
        return $false
    }

    Write-Host '管理者権限が必要です。管理者権限で再実行します...' -ForegroundColor Yellow
    Write-Host 'UACダイアログが表示されたら「はい」をクリックしてください。' -ForegroundColor Yellow

    $argString = "-ExecutionPolicy Bypass -File `"$ScriptPath`""
    foreach ($arg in $Arguments) {
        $argString += " $arg"
    }

    try {
        Start-Process powershell -Verb RunAs -ArgumentList $argString -Wait
        exit $Script:ExitCodes.Success
    } catch {
        Write-Host "管理者権限の取得に失敗しました: $_" -ForegroundColor Red
        return $true
    }
}

# ============================================================================
# ロックファイル管理（アトミック操作）
# ============================================================================

function Get-LockFilePath {
    return Join-Path $env:TEMP 'backup-wsl.lock'
}

function Test-BackupLock {
    param([string]$LockFilePath)

    if (-not (Test-Path $LockFilePath)) {
        return $false
    }

    try {
        $lockContent = Get-Content $LockFilePath -Raw -ErrorAction Stop | ConvertFrom-Json
        $process = Get-Process -Id $lockContent.PID -ErrorAction SilentlyContinue

        if ($process -and $process.Id -eq $lockContent.PID) {
            # プロセスが存在し、同じマシンからのロックか確認
            if ($lockContent.Computer -eq $env:COMPUTERNAME) {
                return $true
            }
        }

        # 古いロックファイルを削除
        Remove-Item $LockFilePath -Force -ErrorAction SilentlyContinue
        return $false
    } catch {
        Remove-Item $LockFilePath -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function New-BackupLock {
    param([string]$LockFilePath)

    # アトミックなロック取得を試みる
    $maxRetries = 3
    for ($i = 0; $i -lt $maxRetries; $i++) {
        try {
            # 排他的にファイルを作成
            $fileStream = [System.IO.File]::Open(
                $LockFilePath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )

            $lockContent = @{
                PID       = $PID
                StartTime = (Get-Date).ToString('o')
                Computer  = $env:COMPUTERNAME
                User      = $env:USERNAME
                Version   = $Script:Constants.Version
            } | ConvertTo-Json

            $bytes = [System.Text.Encoding]::UTF8.GetBytes($lockContent)
            $fileStream.Write($bytes, 0, $bytes.Length)
            $fileStream.Close()

            return $true
        } catch [System.IO.IOException] {
            # ファイルが既に存在する場合
            if (Test-BackupLock -LockFilePath $LockFilePath) {
                return $false
            }
            # 古いロックが残っている場合は再試行
            Start-Sleep -Milliseconds 100
        } catch {
            Write-Log "Failed to create lock file: $_" 'ERROR'
            return $false
        }
    }

    return $false
}

function Remove-BackupLock {
    param([string]$LockFilePath)
    Remove-Item $LockFilePath -Force -ErrorAction SilentlyContinue
}

# ============================================================================
# タイムアウト管理
# ============================================================================

function Initialize-Timeout {
    param([int]$Minutes)

    if ($Minutes -gt 0) {
        $script:DeadlineTime = (Get-Date).AddMinutes($Minutes)
        Write-Log "Timeout set to $Minutes minutes (deadline: $($script:DeadlineTime.ToString($Script:Constants.LogDateFormat)))" 'INFO'
    } else {
        $script:DeadlineTime = $null
    }
}

function Test-Timeout {
    if ($null -eq $script:DeadlineTime) {
        return $false
    }

    if ((Get-Date) -gt $script:DeadlineTime) {
        Write-Log 'Backup operation timed out' 'ERROR'
        return $true
    }

    return $false
}

# ============================================================================
# 検証関数
# ============================================================================

function Test-WslHealth {
    param([string]$Distro)

    try {
        $result = wsl -d $Distro -e echo 'OK' 2>&1
        if ($result -eq 'OK') {
            return $true
        }
        Write-Log "WSL health check failed: $result" 'ERROR'
        return $false
    } catch {
        Write-Log "WSL is not responding: $_" 'ERROR'
        return $false
    }
}

function Test-DiskSpace {
    param(
        [string]$Path,
        [double]$RequiredGB
    )

    if ($RequiredGB -le 0) {
        return $true
    }

    try {
        # パスが存在しない場合は親ディレクトリをチェック
        $checkPath = $Path
        while (-not (Test-Path $checkPath) -and $checkPath.Length -gt 3) {
            $checkPath = Split-Path $checkPath -Parent
        }

        if ($checkPath.Length -lt 3) {
            $checkPath = $Path.Substring(0, 3)  # ドライブルート
        }

        $driveLetter = $checkPath.Substring(0, 1)
        $drive = Get-PSDrive $driveLetter -ErrorAction SilentlyContinue

        if ($drive -and $drive.Free) {
            $freeGB = $drive.Free / 1GB
            if ($freeGB -lt $RequiredGB) {
                Write-Log "Insufficient disk space: $([math]::Round($freeGB, 2)) GB free, need $RequiredGB GB" 'ERROR'
                return $false
            }
            Write-Log "Disk space check passed: $([math]::Round($freeGB, 2)) GB free" 'INFO'
            return $true
        }

        Write-Log "Could not check disk space for path: $Path" 'WARN'
        return $true
    } catch {
        Write-Log "Disk space check failed: $_" 'WARN'
        return $true
    }
}

function Test-SafePath {
    param(
        [string]$Path,
        [string]$AllowedRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    try {
        $resolved = [System.IO.Path]::GetFullPath($Path)
        $resolvedRoot = [System.IO.Path]::GetFullPath($AllowedRoot)
        return $resolved.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Test-SourcePath {
    param(
        [string]$SourcePath,
        [string]$SourceType
    )

    if ([string]::IsNullOrWhiteSpace($SourcePath)) {
        return $false
    }

    # パストラバーサル攻撃の検出
    if ($SourcePath -match '\.\.') {
        Write-Log "Invalid source path (possible path traversal): $SourcePath" 'ERROR'
        return $false
    }

    switch ($SourceType) {
        'wsl' {
            if ($SourcePath -match '//') {
                Write-Log "Invalid WSL path (double slash): $SourcePath" 'ERROR'
                return $false
            }
            if (-not $SourcePath.StartsWith('/')) {
                Write-Log "WSL source path must be absolute (start with /): $SourcePath" 'ERROR'
                return $false
            }
        }
        'windows' {
            if ($SourcePath -notmatch '^[A-Za-z]:\\') {
                Write-Log "Windows source path must be absolute (e.g., C:\...): $SourcePath" 'ERROR'
                return $false
            }
        }
        default {
            Write-Log "Unknown source type for path: $SourcePath" 'ERROR'
            return $false
        }
    }

    return $true
}

function Test-ArchiveIntegrity {
    param(
        [string]$ArchivePath,
        [string]$WslDistro
    )

    if (-not (Test-Path $ArchivePath)) {
        return $false
    }

    try {
        $archivePathWsl = ConvertTo-WslPath -WindowsPath $ArchivePath
        $null = wsl -d $WslDistro -e gzip -t $archivePathWsl 2>&1
        return $LASTEXITCODE -eq 0
    } catch {
        Write-Log "Archive integrity check failed: $_" 'WARN'
        return $false
    }
}

function Test-ZipIntegrity {
    param([string]$ArchivePath)

    if (-not (Test-Path $ArchivePath)) {
        return $false
    }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
        $entryCount = $zip.Entries.Count
        $zip.Dispose()
        return $entryCount -gt 0
    } catch {
        Write-Log "Zip integrity check failed: $_" 'WARN'
        return $false
    }
}

# ============================================================================
# ヘルパー関数
# ============================================================================

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format $Script:Constants.LogDateFormat
    $logEntry = "[$timestamp] [$Level] $Message"

    if ($script:MainLog -and -not $script:DryRunMode) {
        Add-Content -Path $script:MainLog -Value $logEntry -Encoding UTF8
    }

    if ($script:DryRunMode) {
        Write-Host "[DryRun] $logEntry" -ForegroundColor Cyan
    }
}

function Write-SecureLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )

    # 機密情報をマスク
    $masked = $Message
    $masked = $masked -replace '\\Users\\[^\\]+', '\Users\***'
    $masked = $masked -replace '/home/[^/]+', '/home/***'
    $masked = $masked -replace 'password["\s:=]+[^"\s,}]+', 'password=***'
    $masked = $masked -replace 'secret["\s:=]+[^"\s,}]+', 'secret=***'

    Write-Log $masked $Level
}

function Write-MirrorStats {
    param(
        [hashtable]$Stats,
        [string]$Prefix = ''
    )

    if ($Stats.FilesTotal -gt 0) {
        Write-Log "${Prefix}Files: Total=$($Stats.FilesTotal), Copied=$($Stats.FilesCopied), Skipped=$($Stats.FilesSkipped)" 'INFO'
    } else {
        Write-Log "${Prefix}Files: Copied=$($Stats.FilesCopied), Skipped=$($Stats.FilesSkipped)" 'INFO'
    }

    if ($Stats.DirsTotal -gt 0) {
        Write-Log "${Prefix}Directories: Total=$($Stats.DirsTotal), Copied=$($Stats.DirsCopied), Skipped=$($Stats.DirsSkipped)" 'INFO'
    } else {
        Write-Log "${Prefix}Directories: Copied=$($Stats.DirsCopied), Skipped=$($Stats.DirsSkipped)" 'INFO'
    }

    if ($Stats.BytesCopied -gt 0) {
        Write-Log "${Prefix}Data: $([math]::Round($Stats.BytesCopied / 1MB, 2)) MB" 'INFO'
    }
}

function ConvertTo-WslPath {
    param([string]$WindowsPath)

    if ([string]::IsNullOrWhiteSpace($WindowsPath) -or $WindowsPath.Length -lt 2) {
        throw "Invalid Windows path: $WindowsPath"
    }

    $driveLetter = $WindowsPath.Substring(0, 1).ToLower()
    if ($driveLetter -notmatch '^[a-z]$') {
        throw "Invalid drive letter in path: $WindowsPath"
    }

    $pathWithoutDrive = $WindowsPath.Substring(2) -replace '\\', '/'
    return "/mnt/$driveLetter$pathWithoutDrive"
}

function Resolve-SourcePath {
    param(
        [hashtable]$Entry,
        [string]$WslDistro
    )
    if ($Entry.Type -eq 'windows') {
        return $Entry.Path
    }
    return "\\wsl.localhost\$WslDistro" + ($Entry.Path -replace '/', '\')
}

function Get-SafeSourceName {
    param([string]$SourceDir)
    return ($SourceDir -replace '.*/', '') -replace "'", "'\''"
}

function Get-SourceType {
    param([string]$Path)
    if ($Path -match '^[A-Za-z]:\\') { return 'windows' }
    if ($Path.StartsWith('/')) { return 'wsl' }
    return $null
}

function Get-SourceName {
    param([string]$Path, [string]$Type)
    if ($Type -eq 'windows') {
        return Split-Path $Path -Leaf
    }
    return $Path -replace '.*/', ''
}

function Resolve-SourceEntries {
    param([array]$Sources)

    $entries = @()
    $errors = @()

    for ($i = 0; $i -lt $Sources.Count; $i++) {
        $src = $Sources[$i]
        if ($src -is [hashtable]) {
            if (-not $src.Path) {
                $errors += "Sources[$i]: hashtable entry must have a 'Path' property"
                continue
            }
            $path = [string]$src.Path
            $type = Get-SourceType -Path $path
            if (-not $type) {
                $errors += "Sources[$i]: Path must be an absolute WSL path (starting with /) or Windows path (e.g., C:\...)"
                continue
            }
            $name = if ($src.Name) { [string]$src.Name } else { Get-SourceName -Path $path -Type $type }
            if ($name -notmatch '^[a-zA-Z0-9._-]+$') {
                $errors += "Sources[$i]: Name '$name' contains invalid characters (allowed: alphanumeric, dot, underscore, hyphen)"
                continue
            }
            $entries += @{ Path = $path; Name = $name; Type = $type }
        } elseif ($src -is [string]) {
            if (-not $src) {
                $errors += "Sources[$i]: empty path"
                continue
            }
            $type = Get-SourceType -Path $src
            if (-not $type) {
                $errors += "Sources[$i]: Path '$src' must be an absolute WSL path (starting with /) or Windows path (e.g., C:\...)"
                continue
            }
            $name = Get-SourceName -Path $src -Type $type
            $entries += @{ Path = $src; Name = $name; Type = $type }
        } else {
            $errors += "Sources[$i]: must be a string path or a hashtable with Path and optional Name properties"
        }
    }

    if ($entries.Count -gt 1) {
        $dupes = $entries | ForEach-Object { $_.Name } | Group-Object | Where-Object { $_.Count -gt 1 }
        if ($dupes) {
            $dupeDetails = foreach ($dupe in $dupes) {
                $conflicting = for ($j = 0; $j -lt $entries.Count; $j++) {
                    if ($entries[$j].Name -eq $dupe.Name) { $entries[$j].Path }
                }
                "'$($dupe.Name)' ($($conflicting -join ', '))"
            }
            $errors += "Duplicate source names detected: $($dupeDetails -join '; '). Use @{ Path = '...'; Name = '...' } to specify unique aliases."
        }
    }

    return @{
        Valid   = $errors.Count -eq 0
        Errors  = $errors
        Entries = $entries
    }
}

function Read-MirrorIgnore {
    param([string]$IgnoreFilePath)

    $result = @{ Dirs = @(); Files = @() }
    if (-not (Test-Path $IgnoreFilePath)) { return $result }

    Get-Content $IgnoreFilePath -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            if ($line.EndsWith('/')) {
                $result.Dirs += $line.TrimEnd('/')
            } else {
                $result.Files += $line
            }
        }
    }
    return $result
}

function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 3,
        [int]$DelaySeconds = 5,
        [string]$OperationName = 'Operation'
    )

    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            return & $ScriptBlock
        } catch {
            if ($i -eq $MaxRetries) {
                Write-Log "$OperationName failed after $MaxRetries retries: $_" 'ERROR'
                throw
            }
            Write-Log "$OperationName - Retry $i/$MaxRetries after error: $_" 'WARN'
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Show-Progress {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete = -1,
        [int]$CurrentOperation = 0,
        [int]$TotalOperations = 0
    )

    if ($TotalOperations -gt 0 -and $PercentComplete -lt 0) {
        $PercentComplete = [math]::Min(100, [math]::Round(($CurrentOperation / $TotalOperations) * 100))
    }

    if ($PercentComplete -ge 0) {
        Write-Progress -Activity $Activity -Status $Status -PercentComplete $PercentComplete
    } else {
        Write-Progress -Activity $Activity -Status $Status
    }
}

function Complete-Progress {
    Write-Progress -Activity 'Backup' -Completed
}

# ============================================================================
# 通知機能
# ============================================================================

function Send-BackupNotification {
    param(
        [string]$Title,
        [string]$Message,
        [bool]$Success = $true
    )

    if (-not $script:Config.ShowNotification) {
        return
    }

    # Windows通知
    try {
        if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast -ErrorAction SilentlyContinue
            New-BurntToastNotification -Text $Title, $Message -AppLogo $null
        } else {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            $balloon = New-Object System.Windows.Forms.NotifyIcon
            $balloon.Icon = [System.Drawing.SystemIcons]::Information
            $balloon.BalloonTipIcon = if ($Success) { 'Info' } else { 'Error' }
            $balloon.BalloonTipTitle = $Title
            $balloon.BalloonTipText = $Message
            $balloon.Visible = $true
            $balloon.ShowBalloonTip(5000)
            Start-Sleep -Milliseconds 100
            $balloon.Dispose()
        }
    } catch {
        Write-Log "Failed to send Windows notification: $_" 'WARN'
    }

    # Webhook通知
    if ($script:Config.NotificationWebhook) {
        Send-WebhookNotification -Title $Title -Message $Message -Success $Success
    }
}

function Send-WebhookNotification {
    param(
        [string]$Title,
        [string]$Message,
        [bool]$Success
    )

    if (-not $script:Config.NotificationWebhook) {
        return
    }

    try {
        $emoji = if ($Success) { ':white_check_mark:' } else { ':x:' }
        $color = if ($Success) { 'good' } else { 'danger' }

        # Slack形式
        $payload = @{
            attachments = @(
                @{
                    color  = $color
                    title  = "$emoji $Title"
                    text   = $Message
                    footer = "Backup Script v$($Script:Constants.Version)"
                    ts     = [int][double]::Parse((Get-Date -UFormat %s))
                }
            )
        } | ConvertTo-Json -Depth 5

        $null = Invoke-RestMethod -Uri $script:Config.NotificationWebhook -Method Post -Body $payload -ContentType 'application/json' -ErrorAction Stop
        Write-Log 'Webhook notification sent' 'INFO'
    } catch {
        Write-Log "Failed to send webhook notification: $_" 'WARN'
    }
}

# ============================================================================
# 除外アイテム削除
# ============================================================================

function Remove-ExcludedFiles {
    param(
        [string]$MirrorDest,
        [string[]]$ExcludeFiles,
        [string]$Timestamp
    )

    if (-not $ExcludeFiles -or $ExcludeFiles.Count -eq 0) { return @() }

    $matchedFiles = @()
    foreach ($pattern in $ExcludeFiles) {
        $found = Get-ChildItem -Path $MirrorDest -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue
        if ($found) { $matchedFiles += $found }
    }

    if ($matchedFiles.Count -eq 0) { return @() }

    if ($script:DryRunMode) {
        foreach ($file in $matchedFiles) {
            Write-Log "[DryRun] Would delete excluded file: $($file.FullName)" 'INFO'
        }
        return @()
    }

    $failedDeletions = @()
    foreach ($file in $matchedFiles) {
        try {
            Remove-Item -Path $file.FullName -Force -ErrorAction Stop
        } catch {
            $failedDeletions += @{
                Path  = $file.FullName
                Error = $_.Exception.Message
                Time  = Get-Date -Format $Script:Constants.LogDateFormat
            }
        }
    }

    if ($matchedFiles.Count -gt $failedDeletions.Count) {
        $deleted = $matchedFiles.Count - $failedDeletions.Count
        Write-Log "Deleted $deleted excluded file(s) from mirror destination" 'INFO'
    }

    if ($failedDeletions.Count -gt 0) {
        Write-Log "Warning: Failed to delete $($failedDeletions.Count) excluded file(s)" 'WARN'

        $auditLog = Join-Path $script:LogDir "cleanup_audit_$Timestamp.log"
        $logContent = "=== File Cleanup Audit Log ===`nTimestamp: $(Get-Date -Format $Script:Constants.LogDateFormat)`n"
        foreach ($item in $failedDeletions) {
            $logContent += "`n[$($item.Time)] $($item.Path)`n  Error: $($item.Error)"
        }
        $logContent | Out-File -FilePath $auditLog -Encoding UTF8 -Append
    }

    return $failedDeletions
}

function Remove-ExcludedDirectories {
    param(
        [string]$MirrorDest,
        [string[]]$ExcludeDirs,
        [string]$Timestamp
    )

    if (-not $ExcludeDirs -or $ExcludeDirs.Count -eq 0) { return @() }

    $matchedDirs = @()
    foreach ($pattern in $ExcludeDirs) {
        $found = Get-ChildItem -Path $MirrorDest -Recurse -Directory -Filter $pattern -ErrorAction SilentlyContinue
        if ($found) { $matchedDirs += $found }
    }

    if ($matchedDirs.Count -eq 0) { return @() }

    if ($script:DryRunMode) {
        foreach ($dir in $matchedDirs) {
            Write-Log "[DryRun] Would delete excluded directory: $($dir.FullName)" 'INFO'
        }
        return @()
    }

    $failedDeletions = @()
    foreach ($dir in $matchedDirs) {
        if (Test-Path $dir.FullName) {
            try {
                Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction Stop
            } catch {
                $failedDeletions += @{
                    Path  = $dir.FullName
                    Error = $_.Exception.Message
                    Time  = Get-Date -Format $Script:Constants.LogDateFormat
                }
            }
        }
    }

    if ($matchedDirs.Count -gt $failedDeletions.Count) {
        $deleted = $matchedDirs.Count - $failedDeletions.Count
        Write-Log "Deleted $deleted excluded directory/directories from mirror destination" 'INFO'
    }

    if ($failedDeletions.Count -gt 0) {
        Write-Log "Warning: Failed to delete $($failedDeletions.Count) excluded directory/directories" 'WARN'

        $auditLog = Join-Path $script:LogDir "cleanup_audit_$Timestamp.log"
        $logContent = "=== Cleanup Audit Log ===`nTimestamp: $(Get-Date -Format $Script:Constants.LogDateFormat)`n"
        foreach ($item in $failedDeletions) {
            $logContent += "`n[$($item.Time)] $($item.Path)`n  Error: $($item.Error)"
        }
        $logContent | Out-File -FilePath $auditLog -Encoding UTF8 -Append
    }

    return $failedDeletions
}

# ============================================================================
# Robocopyログ解析
# ============================================================================

function ConvertFrom-RobocopyLog {
    param([string]$LogPath)

    $stats = @{
        FilesCopied = 0; FilesSkipped = 0; FilesTotal = 0; FilesFailed = 0
        DirsCopied = 0; DirsSkipped = 0; DirsTotal = 0; DirsFailed = 0
        BytesCopied = 0
        Errors = @()
        NewFiles = @()
        ModifiedFiles = @()
        DeletedFiles = @()
    }

    if (-not (Test-Path $LogPath)) { return $stats }

    try {
        $shiftJis = [System.Text.Encoding]::GetEncoding('shift_jis')
        $utf8 = [System.Text.Encoding]::UTF8
        $logBytes = [System.IO.File]::ReadAllBytes($LogPath)
        $logText = $shiftJis.GetString($logBytes)
        [System.IO.File]::WriteAllText($LogPath, $logText, $utf8)

        foreach ($line in ($logText -split "`r?`n")) {
            # ファイル統計（英語: "Files :" / 日本語: "ファイル:"）
            if ($line -match '^\s*(Files|ファイル)\s*:\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)') {
                $stats.FilesTotal = [int]$matches[2]
                $stats.FilesCopied = [int]$matches[3]
                $stats.FilesSkipped = [int]$matches[4]
                # matches[5] = Mismatch, matches[6] = Failed
                $stats.FilesFailed = [int]$matches[6]
            }
            elseif ($line -match '(Files|ファイル)\s*:\s*(\d+)\s+(\d+)\s+(\d+)') {
                $stats.FilesTotal = [int]$matches[2]
                $stats.FilesCopied = [int]$matches[3]
                $stats.FilesSkipped = [int]$matches[4]
            }

            # ディレクトリ統計（英語: "Dirs :" / 日本語: "ディレクトリ:"）
            if ($line -match '^\s*(Dirs|ディレクトリ)\s*:\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)') {
                $stats.DirsTotal = [int]$matches[2]
                $stats.DirsCopied = [int]$matches[3]
                $stats.DirsSkipped = [int]$matches[4]
                $stats.DirsFailed = [int]$matches[6]
            }
            elseif ($line -match '(Dirs|ディレクトリ)\s*:\s*(\d+)\s+(\d+)\s+(\d+)') {
                $stats.DirsTotal = [int]$matches[2]
                $stats.DirsCopied = [int]$matches[3]
                $stats.DirsSkipped = [int]$matches[4]
            }

            # バイト数（英語: "Bytes :" / 日本語: "バイト:"）
            if ($line -match '(Bytes|バイト)\s*:\s*([\d.]+)\s*([kmgt]?)') {
                $value = [double]$matches[2]
                $unit = $matches[3].ToLower()
                switch ($unit) {
                    'k' { $stats.BytesCopied = [long]($value * 1KB) }
                    'm' { $stats.BytesCopied = [long]($value * 1MB) }
                    'g' { $stats.BytesCopied = [long]($value * 1GB) }
                    't' { $stats.BytesCopied = [long]($value * 1TB) }
                    default { $stats.BytesCopied = [long]$value }
                }
            }

            # 変更レポート用: 新規ファイル（英語: "New File" / 日本語: "新しいファイル"）
            if ($line -match '^\s*(New File|新しいファイル)\s+(.+)$') {
                $stats.NewFiles += $matches[2].Trim()
            }
            # 変更レポート用: 更新ファイル（英語: "Newer"/"Changed" / 日本語: "新しい"/"マイナー変更した"）
            if ($line -match '^\s*(Newer|Changed|新しい|マイナー変更した)\s+(.+)$') {
                $stats.ModifiedFiles += $matches[2].Trim()
            }
            # 変更レポート用: 削除ファイル（英語: "*EXTRA File" / 日本語: "*EXTRA ファイル"）
            if ($line -match '^\s*\*EXTRA\s+(File|ファイル)\s+(.+)$') {
                $stats.DeletedFiles += $matches[2].Trim()
            }

            # エラー
            if ($line -match '(エラー|Error|ERROR)\s+(\d+)') {
                $stats.Errors += $line
            }
        }
    } catch {
        Write-Log "Failed to parse robocopy log: $_" 'WARN'
    }

    return $stats
}

# ============================================================================
# 変更レポート生成
# ============================================================================

function New-ChangeReport {
    param(
        [hashtable]$Stats,
        [string]$SourceName,
        [string]$Timestamp
    )

    if (-not $script:Config.GenerateChangeReport) {
        return $null
    }

    $reportPath = Join-Path $script:LogDir "changes_${SourceName}_$Timestamp.log"

    $report = @"
=== Change Report ===
Source: $SourceName
Time: $(Get-Date -Format $Script:Constants.LogDateFormat)

Summary:
  New Files: $($Stats.NewFiles.Count)
  Modified Files: $($Stats.ModifiedFiles.Count)
  Deleted Files: $($Stats.DeletedFiles.Count)

"@

    if ($Stats.NewFiles.Count -gt 0) {
        $report += "`n--- New Files ---`n"
        foreach ($file in $Stats.NewFiles | Select-Object -First 100) {
            $report += "  + $file`n"
        }
        if ($Stats.NewFiles.Count -gt 100) {
            $report += "  ... and $($Stats.NewFiles.Count - 100) more`n"
        }
    }

    if ($Stats.ModifiedFiles.Count -gt 0) {
        $report += "`n--- Modified Files ---`n"
        foreach ($file in $Stats.ModifiedFiles | Select-Object -First 100) {
            $report += "  ~ $file`n"
        }
        if ($Stats.ModifiedFiles.Count -gt 100) {
            $report += "  ... and $($Stats.ModifiedFiles.Count - 100) more`n"
        }
    }

    if ($Stats.DeletedFiles.Count -gt 0) {
        $report += "`n--- Deleted Files (from mirror) ---`n"
        foreach ($file in $Stats.DeletedFiles | Select-Object -First 100) {
            $report += "  - $file`n"
        }
        if ($Stats.DeletedFiles.Count -gt 100) {
            $report += "  ... and $($Stats.DeletedFiles.Count - 100) more`n"
        }
    }

    if (-not $script:DryRunMode) {
        $report | Out-File -FilePath $reportPath -Encoding UTF8
        Write-Log "Change report saved: $reportPath" 'INFO'
    }

    return $reportPath
}

# ============================================================================
# チェックサム管理
# ============================================================================

function Get-FileChecksum {
    param([string]$FilePath)

    try {
        $hash = Get-FileHash -Path $FilePath -Algorithm SHA256 -ErrorAction Stop
        return $hash.Hash
    } catch {
        return $null
    }
}

function Save-ArchiveChecksum {
    param(
        [string]$ArchivePath,
        [string]$ArchiveDest
    )

    if (-not $script:Config.SaveChecksums) {
        return
    }

    $checksumFile = Join-Path $ArchiveDest $Script:Constants.ChecksumFileName

    try {
        $checksums = @{}
        if (Test-Path $checksumFile) {
            $checksums = Get-Content $checksumFile -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        }

        $archiveName = Split-Path $ArchivePath -Leaf
        $checksum = Get-FileChecksum -FilePath $ArchivePath

        if ($checksum) {
            $checksums[$archiveName] = @{
                SHA256  = $checksum
                Size    = (Get-Item $ArchivePath).Length
                Created = (Get-Date).ToString('o')
            }

            $checksums | ConvertTo-Json -Depth 3 | Set-Content $checksumFile -Encoding UTF8
            Write-Log "Checksum saved for $archiveName" 'INFO'
        }
    } catch {
        Write-Log "Failed to save checksum: $_" 'WARN'
    }
}

function Test-ArchiveChecksum {
    param(
        [string]$ArchivePath,
        [string]$ArchiveDest
    )

    $checksumFile = Join-Path $ArchiveDest $Script:Constants.ChecksumFileName

    if (-not (Test-Path $checksumFile)) {
        return $null
    }

    try {
        $checksums = Get-Content $checksumFile -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        $archiveName = Split-Path $ArchivePath -Leaf

        if ($checksums[$archiveName]) {
            $expectedHash = $checksums[$archiveName].SHA256
            $actualHash = Get-FileChecksum -FilePath $ArchivePath

            return $expectedHash -eq $actualHash
        }
    } catch {
        Write-Log "Failed to verify checksum: $_" 'WARN'
    }

    return $null
}

# ============================================================================
# バックアップ履歴管理
# ============================================================================

function Get-BackupHistory {
    param([string]$HistoryPath)

    if (-not (Test-Path $HistoryPath)) {
        return @{ Backups = @() }
    }

    try {
        return Get-Content $HistoryPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    } catch {
        return @{ Backups = @() }
    }
}

function Save-BackupHistory {
    param(
        [string]$HistoryPath,
        [hashtable]$BackupInfo
    )

    try {
        $history = Get-BackupHistory -HistoryPath $HistoryPath

        $history.Backups += $BackupInfo

        # 最新100件のみ保持
        if ($history.Backups.Count -gt 100) {
            $history.Backups = $history.Backups | Select-Object -Last 100
        }

        $history | ConvertTo-Json -Depth 5 | Set-Content $HistoryPath -Encoding UTF8
    } catch {
        Write-Log "Failed to save backup history: $_" 'WARN'
    }
}

# ============================================================================
# ミラーリング処理
# ============================================================================

function Get-RobocopyExitMessage {
    param([int]$ExitCode)

    if ($ExitCode -eq 0) { return 'No changes - source and destination are synchronized' }
    if ($ExitCode -ge 16) { return "FATAL ERROR (code $ExitCode) - serious error, no files copied" }
    if ($ExitCode -ge 8) { return "FAILED (code $ExitCode) - some files could not be copied (retries exceeded)" }

    $parts = @()
    if ($ExitCode -band 1) { $parts += 'new files copied' }
    if ($ExitCode -band 2) { $parts += 'extra files/dirs detected in destination' }
    if ($ExitCode -band 4) { $parts += 'mismatched files detected' }
    $detail = $parts -join ', '

    return "OK (code $ExitCode) - $detail"
}

function Invoke-Mirroring {
    param(
        [string]$WslSource,
        [string]$MirrorDest,
        [hashtable]$Excludes,
        [string]$Timestamp,
        [int]$ThreadCount,
        [int]$BandwidthLimit = 0
    )

    $startTime = Get-Date
    Write-Log '=== Step 1: Mirroring Started ===' 'INFO'
    Write-SecureLog "Source: $WslSource" 'INFO'
    Write-SecureLog "Destination: $MirrorDest" 'INFO'

    $failedDeletions = Remove-ExcludedDirectories -MirrorDest $MirrorDest -ExcludeDirs $Excludes.Dirs -Timestamp $Timestamp
    $failedDeletions += Remove-ExcludedFiles -MirrorDest $MirrorDest -ExcludeFiles $Excludes.Files -Timestamp $Timestamp

    $robocopyLog = Join-Path $script:LogDir "robocopy_$Timestamp.log"

    $actualThreadCount = if ($ThreadCount -gt 0) {
        $ThreadCount
    } else {
        [Math]::Min([Environment]::ProcessorCount, 16)
    }

    # /V オプションで詳細出力（変更レポート用）
    $robocopyArgs = @($WslSource, $MirrorDest, '/MIR', '/R:1', '/W:0', "/MT:$actualThreadCount", '/NP', '/V', "/LOG:$robocopyLog")

    # DryRunモードでは /L（リストのみ）を追加して予定を表示
    if ($script:DryRunMode) {
        $robocopyArgs += '/L'
        Write-Log "[DryRun] Running robocopy in list-only mode (/L)" 'INFO'
    }

    # 帯域制限
    if ($BandwidthLimit -gt 0) {
        # robocopyには直接の帯域制限がないため、IPGを使用
        # IPG = Inter-Packet Gap (ms) - 概算で帯域制限
        $ipg = [math]::Max(1, [math]::Round(8 / $BandwidthLimit))
        $robocopyArgs += "/IPG:$ipg"
        Write-Log "Bandwidth limit applied: ~$BandwidthLimit Mbps (IPG: $ipg ms)" 'INFO'
    }

    if ($Excludes.Dirs.Count -gt 0) {
        $robocopyArgs += '/XD'
        $robocopyArgs += $Excludes.Dirs
        Write-Log "Excluding directories: $($Excludes.Dirs -join ', ')" 'INFO'
    }
    if ($Excludes.Files.Count -gt 0) {
        $robocopyArgs += '/XF'
        $robocopyArgs += $Excludes.Files
        Write-Log "Excluding files: $($Excludes.Files -join ', ')" 'INFO'
    }

    Write-Log "Thread count: $actualThreadCount" 'INFO'

    Show-Progress -Activity 'Mirroring' -Status 'Running robocopy...' -PercentComplete 10

    $errorLog = Join-Path $env:TEMP "robocopy_error_$PID.log"
    $outputLog = Join-Path $env:TEMP "robocopy_output_$PID.log"

    $process = Start-Process -FilePath 'robocopy' -ArgumentList $robocopyArgs -NoNewWindow -PassThru -Wait -RedirectStandardError $errorLog -RedirectStandardOutput $outputLog

    Show-Progress -Activity 'Mirroring' -Status 'Processing results...' -PercentComplete 90

    $endTime = Get-Date
    $duration = ($endTime - $startTime).TotalSeconds

    $stats = ConvertFrom-RobocopyLog -LogPath $robocopyLog

    if (Test-Path $errorLog) {
        $errorContent = Get-Content $errorLog -ErrorAction SilentlyContinue
        foreach ($err in $errorContent) {
            if ($err.Trim()) {
                Write-Log "Robocopy Error: $err" 'ERROR'
                $stats.Errors += $err
            }
        }
        Remove-Item $errorLog -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $outputLog) {
        Remove-Item $outputLog -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Mirroring completed in $([math]::Round($duration, 2)) seconds" 'INFO'
    Write-MirrorStats -Stats $stats -Prefix '  '
    $exitMsg = Get-RobocopyExitMessage -ExitCode $process.ExitCode
    Write-Log "  Result: $exitMsg" 'INFO'

    if ($process.ExitCode -le $Script:Constants.RobocopySuccessMaxExitCode) {
        Write-Host "  $exitMsg" -ForegroundColor Green
    } else {
        Write-Host "  $exitMsg" -ForegroundColor Yellow
        Write-Log "Warning: $exitMsg" 'WARN'
    }

    return @{
        Duration        = $duration
        Stats           = $stats
        ExitCode        = $process.ExitCode
        FailedDeletions = $failedDeletions
    }
}

# ============================================================================
# アーカイブ作成
# ============================================================================

function New-Archive {
    param(
        [string]$WslDistro,
        [string]$SourceDir,
        [string]$ArchiveDest,
        [string]$Timestamp,
        [bool]$Verify,
        [string]$SourceName,
        [hashtable]$Excludes
    )

    $startTime = Get-Date
    Write-Log '=== Step 2: Archive Creation Started ===' 'INFO'

    $folderName = $SourceDir -replace '.*/', ''
    $parentDir = $SourceDir -replace '/[^/]+$', ''
    if (-not $parentDir) { $parentDir = '/' }
    if (-not $SourceName) { $SourceName = $folderName }

    $archiveName = "${SourceName}_$Timestamp.tar.gz"

    $archivePath = Join-Path $ArchiveDest $archiveName
    $archivePathWsl = ConvertTo-WslPath -WindowsPath $archivePath

    if ($script:DryRunMode) {
        Write-Log "[DryRun] Would create archive: $archivePath" 'INFO'
        return @{
            Duration    = 0
            ArchiveName = $archiveName
            ArchivePath = $archivePath
            TarErrors   = @()
            Verified    = $false
        }
    }

    Show-Progress -Activity 'Creating Archive' -Status "Compressing $SourceName..." -PercentComplete 20

    $tarErrorLog = Join-Path $script:LogDir "tar_errors_$Timestamp.log"
    $tarErrorLogWsl = ConvertTo-WslPath -WindowsPath $tarErrorLog

    $safeFolderName = $folderName -replace "'", "'\\''"
    $safeParentDir = $parentDir -replace "'", "'\\''"

    # --exclude オプションの構築
    $excludeArgs = ''
    if ($Excludes) {
        foreach ($dir in $Excludes.Dirs) {
            $excludeArgs += " --exclude='$dir'"
        }
        foreach ($file in $Excludes.Files) {
            $excludeArgs += " --exclude='$file'"
        }
        if ($excludeArgs) {
            Write-Log "Archive excludes: $($excludeArgs.Trim())" 'INFO'
        }
    }

    $tarCmd = "GZIP=-6 tar -czf '$archivePathWsl'$excludeArgs --ignore-failed-read -C '$safeParentDir' '$safeFolderName' 2>'$tarErrorLogWsl'"

    Invoke-WithRetry -OperationName 'Archive creation' -MaxRetries 2 -DelaySeconds 3 -ScriptBlock {
        wsl -d $WslDistro -e bash -c $tarCmd
    }

    Show-Progress -Activity 'Creating Archive' -Status 'Finalizing...' -PercentComplete 90

    $endTime = Get-Date
    $duration = ($endTime - $startTime).TotalSeconds

    $tarErrors = @()
    if (Test-Path $tarErrorLog) {
        $tarErrorContent = Get-Content $tarErrorLog -ErrorAction SilentlyContinue
        foreach ($err in $tarErrorContent) {
            if ($err.Trim()) {
                Write-Log "Tar Warning: $err" 'WARN'
                $tarErrors += $err
            }
        }
    }

    $verified = $false
    if (Test-Path $archivePath) {
        $size = (Get-Item $archivePath).Length / 1MB
        Write-Host "  OK: $archiveName ($('{0:N1}' -f $size) MB)" -ForegroundColor Green
        Write-Log "Archive created successfully: $archiveName" 'INFO'
        Write-Log "  Size: $([math]::Round($size, 2)) MB" 'INFO'
        Write-Log "  Duration: $([math]::Round($duration, 2)) seconds" 'INFO'

        # チェックサム保存
        Save-ArchiveChecksum -ArchivePath $archivePath -ArchiveDest $ArchiveDest

        if ($Verify) {
            Write-Host '  Verifying archive...' -ForegroundColor Gray
            $verified = Test-ArchiveIntegrity -ArchivePath $archivePath -WslDistro $WslDistro
            if ($verified) {
                Write-Host '  Integrity check: OK' -ForegroundColor Green
                Write-Log '  Integrity check: PASSED' 'INFO'
            } else {
                Write-Host '  Integrity check: FAILED' -ForegroundColor Red
                Write-Log '  Integrity check: FAILED' 'WARN'
            }
        }

        if ($tarErrors.Count -gt 0) {
            Write-Log "  Warnings: $($tarErrors.Count) files skipped" 'WARN'
        }
    } else {
        Write-Host '  ERROR: Archive not created' -ForegroundColor Red
        Write-Log 'ERROR: Archive creation failed' 'ERROR'
    }

    return @{
        Duration    = $duration
        ArchiveName = $archiveName
        ArchivePath = $archivePath
        TarErrors   = $tarErrors
        Verified    = $verified
    }
}

function New-WindowsArchive {
    param(
        [string]$MirrorSource,
        [string]$ArchiveDest,
        [string]$Timestamp,
        [bool]$Verify,
        [string]$SourceName
    )

    $startTime = Get-Date
    Write-Log '=== Step 2: Archive Creation (Windows/zip) Started ===' 'INFO'

    if (-not $SourceName) { $SourceName = Split-Path $MirrorSource -Leaf }
    $archiveName = "${SourceName}_$Timestamp.zip"
    $archivePath = Join-Path $ArchiveDest $archiveName

    if ($script:DryRunMode) {
        Write-Log "[DryRun] Would create archive: $archivePath" 'INFO'
        return @{
            Duration    = 0
            ArchiveName = $archiveName
            ArchivePath = $archivePath
            TarErrors   = @()
            Verified    = $false
        }
    }

    if (-not (Test-Path $MirrorSource)) {
        Write-Host "  ERROR: Mirror source not found: $MirrorSource" -ForegroundColor Red
        Write-Log "ERROR: Mirror source not found: $MirrorSource" 'ERROR'
        return @{
            Duration    = 0
            ArchiveName = $archiveName
            ArchivePath = $null
            TarErrors   = @()
            Verified    = $false
        }
    }

    Show-Progress -Activity 'Creating Archive' -Status "Compressing $SourceName..." -PercentComplete 20

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        Invoke-WithRetry -OperationName 'Archive creation' -MaxRetries 2 -DelaySeconds 3 -ScriptBlock {
            if (Test-Path $archivePath) { Remove-Item $archivePath -Force }
            [System.IO.Compression.ZipFile]::CreateFromDirectory(
                $MirrorSource,
                $archivePath,
                [System.IO.Compression.CompressionLevel]::Optimal,
                $false
            )
        }
    } catch {
        Write-Host "  ERROR: Archive creation failed: $_" -ForegroundColor Red
        Write-Log "ERROR: Archive creation failed: $_" 'ERROR'
        return @{
            Duration    = (New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds
            ArchiveName = $archiveName
            ArchivePath = $null
            TarErrors   = @("$_")
            Verified    = $false
        }
    }

    Show-Progress -Activity 'Creating Archive' -Status 'Finalizing...' -PercentComplete 90

    $endTime = Get-Date
    $duration = ($endTime - $startTime).TotalSeconds

    $verified = $false
    if (Test-Path $archivePath) {
        $size = (Get-Item $archivePath).Length / 1MB
        Write-Host "  OK: $archiveName ($('{0:N1}' -f $size) MB)" -ForegroundColor Green
        Write-Log "Archive created successfully: $archiveName" 'INFO'
        Write-Log "  Size: $([math]::Round($size, 2)) MB" 'INFO'
        Write-Log "  Duration: $([math]::Round($duration, 2)) seconds" 'INFO'

        Save-ArchiveChecksum -ArchivePath $archivePath -ArchiveDest $ArchiveDest

        if ($Verify) {
            Write-Host '  Verifying archive...' -ForegroundColor Gray
            $verified = Test-ZipIntegrity -ArchivePath $archivePath
            if ($verified) {
                Write-Host '  Integrity check: OK' -ForegroundColor Green
                Write-Log '  Integrity check: PASSED' 'INFO'
            } else {
                Write-Host '  Integrity check: FAILED' -ForegroundColor Red
                Write-Log '  Integrity check: FAILED' 'WARN'
            }
        }
    } else {
        Write-Host '  ERROR: Archive not created' -ForegroundColor Red
        Write-Log 'ERROR: Archive creation failed' 'ERROR'
    }

    return @{
        Duration    = $duration
        ArchiveName = $archiveName
        ArchivePath = $archivePath
        TarErrors   = @()
        Verified    = $verified
    }
}

# ============================================================================
# リストア機能
# ============================================================================

function Invoke-Restore {
    param(
        [string]$ArchivePath,
        [string]$RestoreTarget,
        [string]$WslDistro
    )

    Write-Host '=== Restore Mode ===' -ForegroundColor Cyan

    if (-not (Test-Path $ArchivePath)) {
        Write-Host "ERROR: Archive not found: $ArchivePath" -ForegroundColor Red
        return $false
    }

    $isZip = $ArchivePath -match '\.zip$'
    $restoreType = if ($isZip) { 'windows' } else { 'wsl' }

    # リストア先の確認
    if (-not $RestoreTarget) {
        Write-Host 'ERROR: RestoreTarget is required' -ForegroundColor Red
        return $false
    }

    # パスのバリデーション
    if (-not (Test-SourcePath -SourcePath $RestoreTarget -SourceType $restoreType)) {
        Write-Host 'ERROR: Invalid restore target path' -ForegroundColor Red
        return $false
    }

    Write-Host "Archive: $ArchivePath" -ForegroundColor Gray
    Write-Host "Restore to: $RestoreTarget" -ForegroundColor Gray
    Write-Host "Type: $restoreType" -ForegroundColor Gray

    if ($script:DryRunMode) {
        Write-Host "[DryRun] Would restore archive to $RestoreTarget" -ForegroundColor Cyan
        return $true
    }

    # 確認プロンプト
    $confirm = Read-Host "This will restore files to '$RestoreTarget'. Continue? (yes/no)"
    if ($confirm -ne 'yes') {
        Write-Host 'Restore cancelled.' -ForegroundColor Yellow
        return $false
    }

    try {
        if ($isZip) {
            if (-not (Test-Path $RestoreTarget)) {
                New-Item -ItemType Directory -Force -Path $RestoreTarget | Out-Null
            }
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $RestoreTarget)
            Write-Host 'Restore completed successfully!' -ForegroundColor Green
            return $true
        } else {
            $archivePathWsl = ConvertTo-WslPath -WindowsPath $ArchivePath
            wsl -d $WslDistro -e mkdir -p $RestoreTarget
            wsl -d $WslDistro -e tar -xzf $archivePathWsl -C $RestoreTarget

            if ($LASTEXITCODE -eq 0) {
                Write-Host 'Restore completed successfully!' -ForegroundColor Green
                return $true
            } else {
                Write-Host "Restore failed with exit code: $LASTEXITCODE" -ForegroundColor Red
                return $false
            }
        }
    } catch {
        Write-Host "Restore failed: $_" -ForegroundColor Red
        return $false
    }
}

function Show-AvailableArchives {
    param(
        [string]$ArchiveDest,
        [string]$ChecksumFile
    )

    Write-Host "`n=== Available Archives ===" -ForegroundColor Cyan

    $archives = Get-ChildItem $ArchiveDest -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.(tar\.gz|zip)$' } |
        Sort-Object LastWriteTime -Descending

    if ($archives.Count -eq 0) {
        Write-Host "No archives found in $ArchiveDest" -ForegroundColor Yellow
        return
    }

    # チェックサム情報の読み込み
    $checksums = @{}
    if (Test-Path $ChecksumFile) {
        try {
            $checksums = Get-Content $ChecksumFile -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        } catch { }
    }

    Write-Host "`nFound $($archives.Count) archive(s):`n"

    $format = '{0,-50} {1,12} {2,-20} {3}'
    Write-Host ($format -f 'Name', 'Size', 'Date', 'Verified') -ForegroundColor Gray
    Write-Host ('-' * 100) -ForegroundColor Gray

    foreach ($archive in $archives) {
        $sizeMB = '{0:N1} MB' -f ($archive.Length / 1MB)
        $date = $archive.LastWriteTime.ToString('yyyy-MM-dd HH:mm')

        $verifiedStatus = ''
        if ($checksums[$archive.Name]) {
            $verifiedStatus = 'Yes'
        }

        Write-Host ($format -f $archive.Name, $sizeMB, $date, $verifiedStatus)
    }

    Write-Host ''
}

# ============================================================================
# タスクスケジューラー連携
# ============================================================================

function Register-BackupScheduledTask {
    param(
        [string]$ScriptPath,
        [string]$ScheduleTime
    )

    Write-Host '=== Registering Scheduled Task ===' -ForegroundColor Cyan

    if (-not (Test-Administrator)) {
        Write-Host 'ERROR: Administrator privileges required to register scheduled task' -ForegroundColor Red
        return $false
    }

    try {
        $taskName = 'WSL-Backup'

        # 既存タスクの確認
        $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existingTask) {
            Write-Host "Task '$taskName' already exists. Updating..." -ForegroundColor Yellow
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }

        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""

        $trigger = New-ScheduledTaskTrigger -Daily -At $ScheduleTime

        $settings = New-ScheduledTaskSettingsSet `
            -StartWhenAvailable `
            -DontStopOnIdleEnd `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Hours 4)

        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

        Register-ScheduledTask -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -Principal $principal `
            -Description 'WSL Backup - Daily backup of WSL directories to Windows' | Out-Null

        Write-Host "Scheduled task '$taskName' registered successfully!" -ForegroundColor Green
        Write-Host "  Schedule: Daily at $ScheduleTime" -ForegroundColor Gray
        Write-Host "  Script: $ScriptPath" -ForegroundColor Gray

        return $true
    } catch {
        Write-Host "Failed to register scheduled task: $_" -ForegroundColor Red
        return $false
    }
}

function Unregister-BackupScheduledTask {
    Write-Host '=== Unregistering Scheduled Task ===' -ForegroundColor Cyan

    if (-not (Test-Administrator)) {
        Write-Host 'ERROR: Administrator privileges required' -ForegroundColor Red
        return $false
    }

    try {
        $taskName = 'WSL-Backup'

        $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $existingTask) {
            Write-Host "Task '$taskName' not found" -ForegroundColor Yellow
            return $true
        }

        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Scheduled task '$taskName' removed successfully!" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "Failed to unregister scheduled task: $_" -ForegroundColor Red
        return $false
    }
}

# ============================================================================
# 除外パターンテスト
# ============================================================================

function Test-ExclusionPatterns {
    param(
        [string]$WslSource,
        [hashtable]$Excludes
    )

    Write-Host "`n=== Exclusion Pattern Test ===" -ForegroundColor Cyan
    Write-Host "Source: $WslSource`n" -ForegroundColor Gray

    Write-Host 'Excluded Directories:' -ForegroundColor Yellow
    foreach ($dir in $Excludes.Dirs) {
        $testPath = Join-Path $WslSource $dir
        $exists = Test-Path $testPath
        $status = if ($exists) { '[FOUND]' } else { '[NOT FOUND]' }
        $color = if ($exists) { 'Green' } else { 'Gray' }
        Write-Host "  $status $dir" -ForegroundColor $color
    }

    Write-Host "`nExcluded Files:" -ForegroundColor Yellow
    foreach ($pattern in $Excludes.Files) {
        Write-Host "  $pattern" -ForegroundColor Gray
    }

    # 実際に除外されるファイル数をカウント
    Write-Host "`nScanning for excluded items..." -ForegroundColor Gray

    $excludedCount = 0
    foreach ($dir in $Excludes.Dirs) {
        $found = Get-ChildItem -Path $WslSource -Directory -Recurse -Name -Filter $dir -ErrorAction SilentlyContinue
        $excludedCount += ($found | Measure-Object).Count
    }

    Write-Host "`nExcluded directories found: $excludedCount" -ForegroundColor Cyan
}

# ============================================================================
# クリーンアップ処理
# ============================================================================

function Remove-OldArchives {
    param(
        [string]$ArchiveDest,
        [int]$KeepCount
    )

    $startTime = Get-Date
    Write-Log '=== Step 3: Cleanup Started ===' 'INFO'

    $deletedCount = 0
    $deletedSize = 0

    if ($KeepCount -gt 0) {
        $all = Get-ChildItem $ArchiveDest -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '\.(tar\.gz|zip)$' } |
            Sort-Object LastWriteTime -Descending
        $old = $all | Select-Object -Skip $KeepCount
        $deletedCount = ($old | Measure-Object).Count
        $deletedSize = ($old | Measure-Object -Property Length -Sum).Sum / 1MB

        if ($deletedCount -gt 0) {
            foreach ($file in $old) {
                Write-Log "Deleting old archive: $($file.Name)" 'INFO'
            }

            if ($script:DryRunMode) {
                Write-Log "[DryRun] Would delete $deletedCount old archive(s) (keeping newest $KeepCount)" 'INFO'
            }
            else {
                try {
                    $old | Remove-Item -Force -ErrorAction Stop
                    Write-Host "  Deleted $deletedCount old archive(s) (keeping newest $KeepCount)" -ForegroundColor Green
                    Write-Log "Deleted $deletedCount old archive(s), freed $([math]::Round($deletedSize, 2)) MB" 'INFO'
                }
                catch {
                    Write-Host '  Warning: Failed to delete some archives' -ForegroundColor Yellow
                    Write-Log "Warning: Failed to delete some archives: $($_.Exception.Message)" 'WARN'
                }
            }
        }
        else {
            Write-Host '  No old archives to delete' -ForegroundColor Gray
            Write-Log 'No old archives to delete' 'INFO'
        }
    }
    else {
        Write-Host '  Skipped (KeepCount=0, keep all)' -ForegroundColor Gray
        Write-Log 'Cleanup skipped (KeepCount=0)' 'INFO'
    }

    $endTime = Get-Date
    $duration = ($endTime - $startTime).TotalSeconds
    Write-Log "Cleanup completed in $([math]::Round($duration, 2)) seconds" 'INFO'

    return @{
        Duration     = $duration
        DeletedCount = $deletedCount
        DeletedSize  = $deletedSize
    }
}

function Remove-OldLogs {
    param(
        [string]$LogDir,
        [int]$KeepCount
    )

    if ($KeepCount -le 0) {
        return
    }

    $all = Get-ChildItem $LogDir -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    $oldLogs = $all | Select-Object -Skip $KeepCount
    $count = ($oldLogs | Measure-Object).Count

    if ($count -le 0) {
        return
    }

    if ($script:DryRunMode) {
        Write-Log "[DryRun] Would delete $count old log file(s) (keeping newest $KeepCount)" 'INFO'
        return
    }

    $oldLogs | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Log "Deleted $count old log file(s) (keeping newest $KeepCount)" 'INFO'
}

# ============================================================================
# サマリー出力
# ============================================================================

function Write-Summary {
    param(
        [datetime]$ScriptStartTime,
        [hashtable[]]$MirrorResults,
        [hashtable[]]$ArchiveResults,
        [hashtable]$CleanupResult,
        [bool]$SkipArchive,
        [int]$KeepCount
    )

    $endTime = Get-Date
    $totalDuration = ($endTime - $ScriptStartTime).TotalSeconds

    Write-Log '=== Backup Summary ===' 'INFO'
    Write-Log "Version: $($Script:Constants.Version)" 'INFO'
    Write-Log "Start Time: $($ScriptStartTime.ToString($Script:Constants.LogDateFormat))" 'INFO'
    Write-Log "End Time: $($endTime.ToString($Script:Constants.LogDateFormat))" 'INFO'
    Write-Log "Total Duration: $([math]::Round($totalDuration, 2)) seconds ($([math]::Round($totalDuration / 60, 2)) minutes)" 'INFO'
    Write-Log '' 'INFO'

    $multiSource = $MirrorResults.Count -gt 1

    Write-Log 'Step 1 - Mirroring:' 'INFO'
    for ($i = 0; $i -lt $MirrorResults.Count; $i++) {
        $mirrorResult = $MirrorResults[$i]
        $src = $script:SourceEntries[$i].Path
        $pad = if ($multiSource) { '    ' } else { '  ' }
        if ($multiSource) {
            Write-Log "  [$($i + 1)] $src" 'INFO'
        } else {
            Write-Log "  Source: $src" 'INFO'
        }
        Write-Log "${pad}Duration: $([math]::Round($mirrorResult.Duration, 2)) seconds" 'INFO'
        Write-MirrorStats -Stats $mirrorResult.Stats -Prefix $pad
        Write-Log "${pad}Result: $(Get-RobocopyExitMessage -ExitCode $mirrorResult.ExitCode)" 'INFO'
    }
    Write-Log '' 'INFO'

    Write-Log 'Step 2 - Archive:' 'INFO'
    if ($SkipArchive) {
        Write-Log '  Status: SKIPPED' 'INFO'
    } else {
        for ($i = 0; $i -lt $ArchiveResults.Count; $i++) {
            $archiveResult = $ArchiveResults[$i]
            $src = $script:SourceEntries[$i].Path
            $pad = if ($multiSource) { '    ' } else { '  ' }
            if ($multiSource) {
                Write-Log "  [$($i + 1)] $src" 'INFO'
            }
            Write-Log "${pad}Duration: $([math]::Round($archiveResult.Duration, 2)) seconds" 'INFO'
            if ($script:DryRunMode) {
                Write-Log "${pad}Archive: $($archiveResult.ArchiveName)" 'INFO'
                Write-Log "${pad}Status: SKIPPED (DryRun)" 'INFO'
            }
            elseif ($archiveResult.ArchivePath -and (Test-Path $archiveResult.ArchivePath)) {
                $archiveSize = (Get-Item $archiveResult.ArchivePath).Length / 1MB
                Write-Log "${pad}Archive: $($archiveResult.ArchiveName)" 'INFO'
                Write-Log "${pad}Size: $([math]::Round($archiveSize, 2)) MB" 'INFO'
                if ($archiveResult.Verified) {
                    Write-Log "${pad}Integrity: VERIFIED" 'INFO'
                }
            }
            else {
                Write-Log "${pad}Status: FAILED" 'ERROR'
            }
        }
    }
    Write-Log '' 'INFO'

    Write-Log 'Step 3 - Cleanup:' 'INFO'
    Write-Log "  Duration: $([math]::Round($CleanupResult.Duration, 2)) seconds" 'INFO'
    if ($KeepCount -gt 0) {
        Write-Log "  Old archives deleted: $($CleanupResult.DeletedCount) (keeping newest $KeepCount)" 'INFO'
    } else {
        Write-Log '  Cleanup: Disabled (KeepCount=0, keep all)' 'INFO'
    }
    Write-Log '' 'INFO'

    $hasErrors = $false
    foreach ($mirrorResult in $MirrorResults) {
        if ($mirrorResult.Stats.Errors.Count -gt 0 -or $mirrorResult.FailedDeletions.Count -gt 0) {
            $hasErrors = $true
            break
        }
    }

    if ($hasErrors) {
        Write-Log '=== Error/Warning Summary ===' 'WARN'
        foreach ($mirrorResult in $MirrorResults) {
            if ($mirrorResult.FailedDeletions.Count -gt 0) {
                Write-Log "  Failed deletions: $($mirrorResult.FailedDeletions.Count)" 'WARN'
            }
            if ($mirrorResult.Stats.Errors.Count -gt 0) {
                Write-Log "  Robocopy errors: $($mirrorResult.Stats.Errors.Count)" 'WARN'
            }
        }
    }

    Write-Log "=== $script:BackupModeLabel Completed ===" 'INFO'
    Write-Log "Log file: $script:MainLog" 'INFO'
}

# ============================================================================
# メイン処理
# ============================================================================

# グローバル変数の初期化
$script:DryRunMode = $DryRun.IsPresent

# 設定ファイルの読み込み
$configPath = Join-Path $PSScriptRoot $Script:Constants.ConfigFileName

$configResult = Import-BackupConfig -ConfigPath $configPath
$script:Config = $configResult.Config

# 設定バリデーションエラーの表示
if (-not $configResult.Valid) {
    Write-Host 'Configuration errors:' -ForegroundColor Red
    foreach ($err in $configResult.Errors) {
        Write-Host "  - $err" -ForegroundColor Red
    }

    # 必須項目のエラーの場合は終了
    $hasCriticalError = $configResult.Errors | Where-Object { $_ -match 'Required|missing' }
    if ($hasCriticalError -and -not ($ListArchives -or $UnregisterScheduledTask)) {
        exit $Script:ExitCodes.ConfigError
    }
}

# コマンドライン引数で上書き
if ($Source) {
    $script:Config.Sources = @($Source)
}

# ソースエントリの解決（エイリアス対応 + 重複名チェック）
$resolveResult = Resolve-SourceEntries -Sources $script:Config.Sources
if (-not $resolveResult.Valid) {
    foreach ($err in $resolveResult.Errors) {
        Write-Host "ERROR: $err" -ForegroundColor Red
    }
    exit $Script:ExitCodes.ValidationError
}
$script:SourceEntries = $resolveResult.Entries

# ============================================================================
# モード別処理
# ============================================================================

# アーカイブ一覧表示モード
if ($ListArchives) {
    $archiveDest = Join-Path $script:Config.DestRoot 'archive'
    $checksumFile = Join-Path $archiveDest $Script:Constants.ChecksumFileName
    Show-AvailableArchives -ArchiveDest $archiveDest -ChecksumFile $checksumFile
    exit $Script:ExitCodes.Success
}

# タスクスケジューラー登録モード
if ($RegisterScheduledTask) {
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.ScriptName }
    $result = Register-BackupScheduledTask -ScriptPath $scriptPath -ScheduleTime $ScheduleTime
    exit $(if ($result) { $Script:ExitCodes.Success } else { $Script:ExitCodes.ScheduleError })
}

# タスクスケジューラー解除モード
if ($UnregisterScheduledTask) {
    $result = Unregister-BackupScheduledTask
    exit $(if ($result) { $Script:ExitCodes.Success } else { $Script:ExitCodes.ScheduleError })
}

# 除外パターンテストモード
if ($TestExclusions) {
    $excludes = Read-MirrorIgnore -IgnoreFilePath (Join-Path $PSScriptRoot '.mirrorignore')
    foreach ($entry in $script:SourceEntries) {
        $resolvedSource = Resolve-SourcePath -Entry $entry -WslDistro $script:Config.WslDistro
        Test-ExclusionPatterns -WslSource $resolvedSource -Excludes $excludes
    }
    exit $Script:ExitCodes.Success
}

# リストアモード
if ($Restore) {
    if (-not $RestoreArchive) {
        # アーカイブ一覧を表示して選択
        $archiveDest = Join-Path $script:Config.DestRoot 'archive'
        Show-AvailableArchives -ArchiveDest $archiveDest -ChecksumFile (Join-Path $archiveDest $Script:Constants.ChecksumFileName)

        $RestoreArchive = Read-Host 'Enter archive filename to restore'
        if (-not $RestoreArchive) {
            Write-Host 'No archive selected. Exiting.' -ForegroundColor Yellow
            exit $Script:ExitCodes.Success
        }

        $RestoreArchive = Join-Path $archiveDest $RestoreArchive
    }

    if (-not $RestoreTarget) {
        $isZipRestore = $RestoreArchive -match '\.zip$'
        if ($isZipRestore) {
            $RestoreTarget = Read-Host 'Enter restore target path (Windows path, e.g., C:\Users\user\restore)'
        } else {
            $RestoreTarget = Read-Host 'Enter restore target path (WSL path, e.g., /home/user/restore)'
        }
    }

    $result = Invoke-Restore -ArchivePath $RestoreArchive -RestoreTarget $RestoreTarget `
        -WslDistro $script:Config.WslDistro

    exit $(if ($result) { $Script:ExitCodes.Success } else { $Script:ExitCodes.RestoreError })
}

# ============================================================================
# 通常バックアップモード
# ============================================================================

$script:SkipArchiveFlag = $SkipArchive.IsPresent

# ドライランモードの表示
if ($script:DryRunMode) {
    Write-Host '=== DRY RUN MODE ===' -ForegroundColor Magenta
    Write-Host '実際には何も変更されません。' -ForegroundColor Magenta
    Write-Host ''
}

# ソースパスの検証
foreach ($entry in $script:SourceEntries) {
    if (-not (Test-SourcePath -SourcePath $entry.Path -SourceType $entry.Type)) {
        Write-Host "ERROR: Invalid source path: $($entry.Path)" -ForegroundColor Red
        exit $Script:ExitCodes.ValidationError
    }
}

# モード判定
$script:HasWslSources = ($script:SourceEntries | Where-Object { $_.Type -eq 'wsl' }).Count -gt 0
$script:HasWindowsSources = ($script:SourceEntries | Where-Object { $_.Type -eq 'windows' }).Count -gt 0

# WSLソースがある場合、WslDistroが必須
if ($script:HasWslSources -and [string]::IsNullOrWhiteSpace($script:Config.WslDistro)) {
    Write-Host 'ERROR: WslDistro is required when using WSL source paths' -ForegroundColor Red
    exit $Script:ExitCodes.ConfigError
}

# バックアップモードラベル
$script:BackupModeLabel = if ($script:HasWslSources -and $script:HasWindowsSources) {
    'WSL/Windows Backup'
} elseif ($script:HasWindowsSources) {
    'Windows Backup'
} else {
    'WSL Backup'
}

# ロックファイルによる二重実行防止
$lockFilePath = Get-LockFilePath
if (Test-BackupLock -LockFilePath $lockFilePath) {
    Write-Host 'エラー: バックアップが既に実行中です。' -ForegroundColor Red
    Write-Host "  ロックファイル: $lockFilePath" -ForegroundColor Red
    exit $Script:ExitCodes.LockError
}

# 管理者権限チェック
$scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.ScriptName }
if (-not (Test-Administrator)) {
    $MirrorDest = Join-Path $script:Config.DestRoot 'mirror'
    $testLogDir = Join-Path $PSScriptRoot 'logs'

    $needsAdmin = $false
    try {
        $testPath = Join-Path $testLogDir "test_$PID"
        New-Item -ItemType Directory -Force -Path $testPath -ErrorAction Stop | Out-Null
        Remove-Item -Path $testPath -Force -ErrorAction SilentlyContinue
    } catch {
        if ($_.Exception.Message -match 'アクセス|Access|権限|Permission|denied') {
            $needsAdmin = $true
        }
    }

    if ($needsAdmin -and $script:Config.AutoElevate) {
        $elevateArgs = @()
        if ($script:SkipArchiveFlag) { $elevateArgs += '-SkipArchive' }
        if ($script:DryRunMode) { $elevateArgs += '-DryRun' }
        if ($Source) { $elevateArgs += "-Source `"$Source`"" }
        if ($TimeoutMinutes -ne 120) { $elevateArgs += "-TimeoutMinutes $TimeoutMinutes" }

        if (Request-Administrator -ScriptPath $scriptPath -Arguments $elevateArgs) {
            exit $Script:ExitCodes.PermissionError
        }
    } elseif ($needsAdmin) {
        Write-Host 'エラー: 管理者権限が必要ですが、自動昇格が無効です。' -ForegroundColor Red
        exit $Script:ExitCodes.PermissionError
    }
}

# ロックファイルの作成
if (-not $script:DryRunMode) {
    if (-not (New-BackupLock -LockFilePath $lockFilePath)) {
        Write-Host 'エラー: ロックの取得に失敗しました。' -ForegroundColor Red
        exit $Script:ExitCodes.LockError
    }
}

try {
    $Timestamp = Get-Date -Format $Script:Constants.TimestampFormat
    $ScriptStartTime = Get-Date

    # タイムアウト初期化
    Initialize-Timeout -Minutes $TimeoutMinutes

    $MirrorDest = Join-Path $script:Config.DestRoot 'mirror'
    $ArchiveDest = Join-Path $script:Config.DestRoot 'archive'
    $script:LogDir = Join-Path $PSScriptRoot 'logs'
    $historyPath = Join-Path $ArchiveDest $Script:Constants.HistoryFileName

    # ディレクトリ作成
    if (-not $script:DryRunMode) {
        try {
            New-Item -ItemType Directory -Force -Path $MirrorDest -ErrorAction Stop | Out-Null
            New-Item -ItemType Directory -Force -Path $ArchiveDest -ErrorAction Stop | Out-Null
            New-Item -ItemType Directory -Force -Path $script:LogDir -ErrorAction Stop | Out-Null
        } catch {
            Write-Host "エラー: ディレクトリの作成に失敗しました: $($_.Exception.Message)" -ForegroundColor Red
            exit $Script:ExitCodes.PermissionError
        }
    }

    $script:MainLog = Join-Path $script:LogDir "backup_$Timestamp.log"

    $sourceDisplayPaths = ($script:SourceEntries | ForEach-Object { $_.Path }) -join ', '
    Write-Host "$script:BackupModeLabel v$($Script:Constants.Version): $sourceDisplayPaths -> $($script:Config.DestRoot)"
    Write-Log "=== $script:BackupModeLabel Started ===" 'INFO'
    Write-Log "Version: $($Script:Constants.Version)" 'INFO'
    Write-SecureLog "Sources: $sourceDisplayPaths" 'INFO'
    Write-SecureLog "Destination: $($script:Config.DestRoot)" 'INFO'
    if ($script:HasWslSources) {
        Write-Log "WSL Distribution: $($script:Config.WslDistro)" 'INFO'
    }
    if ($script:SkipArchiveFlag) {
        Write-Log 'Archive Creation: SKIPPED (via command-line argument)' 'INFO'
    }
    if ($script:DryRunMode) {
        Write-Log 'Mode: DRY RUN' 'INFO'
    }
    Write-Log "Start Time: $($ScriptStartTime.ToString($Script:Constants.LogDateFormat))" 'INFO'

    # WSLの状態確認（WSLソースがある場合のみ）
    if ($script:HasWslSources) {
        Show-Progress -Activity $script:BackupModeLabel -Status 'Checking WSL health...' -PercentComplete 5
        Write-Host 'Checking WSL health...' -ForegroundColor Gray
        if (-not (Test-WslHealth -Distro $script:Config.WslDistro)) {
            Write-Host "ERROR: WSL is not responding or distribution '$($script:Config.WslDistro)' is not available" -ForegroundColor Red
            exit $Script:ExitCodes.WslError
        }
        Write-Log 'WSL health check passed' 'INFO'
    }

    # タイムアウトチェック
    if (Test-Timeout) {
        Write-Host 'ERROR: Operation timed out' -ForegroundColor Red
        exit $Script:ExitCodes.TimeoutError
    }

    # ディスク容量チェック
    if (-not (Test-DiskSpace -Path $script:Config.DestRoot -RequiredGB $script:Config.RequiredFreeSpaceGB)) {
        Write-Host 'ERROR: Insufficient disk space' -ForegroundColor Red
        exit $Script:ExitCodes.DiskSpaceError
    }

    # ソースディレクトリの確認
    foreach ($entry in $script:SourceEntries) {
        $resolvedSource = Resolve-SourcePath -Entry $entry -WslDistro $script:Config.WslDistro
        if (-not (Test-Path $resolvedSource)) {
            Write-Host "ERROR: Source not found: $resolvedSource" -ForegroundColor Red
            exit $Script:ExitCodes.SourceNotFound
        }
    }
    Write-Log 'Source directories verified' 'INFO'

    # 除外パターンの読み込み
    $excludes = Read-MirrorIgnore -IgnoreFilePath (Join-Path $PSScriptRoot '.mirrorignore')

    # ミラーリング処理
    $mirrorResults = @()
    $totalSources = $script:SourceEntries.Count
    $totalSteps = $totalSources * 2 + 1  # mirror + archive + cleanup

    for ($i = 0; $i -lt $totalSources; $i++) {
        # タイムアウトチェック
        if (Test-Timeout) {
            Write-Host 'ERROR: Operation timed out during mirroring' -ForegroundColor Red
            exit $Script:ExitCodes.TimeoutError
        }

        $sourceEntry = $script:SourceEntries[$i]
        $sourceDir = $sourceEntry.Path
        $sourceName = $sourceEntry.Name
        $resolvedSource = Resolve-SourcePath -Entry $sourceEntry -WslDistro $script:Config.WslDistro
        $sourceMirrorDest = if ($totalSources -eq 1) { $MirrorDest } else { Join-Path $MirrorDest $sourceName }

        $stepNum = $i + 1
        $progress = [math]::Round(($stepNum / $totalSteps) * 100)
        Show-Progress -Activity $script:BackupModeLabel -Status "Mirroring $sourceName..." -PercentComplete $progress

        if ($totalSources -eq 1) {
            Write-Host "[1/3] Mirroring $sourceDir..." -ForegroundColor Cyan
        } else {
            Write-Host "[1.$($i + 1)/$totalSources] Mirroring $sourceDir..." -ForegroundColor Cyan
        }

        if ($totalSources -gt 1 -and -not $script:DryRunMode) {
            New-Item -ItemType Directory -Force -Path $sourceMirrorDest -ErrorAction SilentlyContinue | Out-Null
        }

        $mirrorResult = Invoke-Mirroring -WslSource $resolvedSource -MirrorDest $sourceMirrorDest `
            -Excludes $excludes -Timestamp $Timestamp -ThreadCount $script:Config.ThreadCount `
            -BandwidthLimit $script:Config.BandwidthLimitMbps
        $mirrorResults += $mirrorResult

        # 変更レポート生成
        if ($script:Config.GenerateChangeReport -and -not $script:DryRunMode) {
            New-ChangeReport -Stats $mirrorResult.Stats -SourceName $sourceName -Timestamp $Timestamp
        }
    }

    # アーカイブ作成処理
    $archiveResults = @()

    if ($script:SkipArchiveFlag) {
        Write-Host '[2/3] Creating archive... (SKIPPED)' -ForegroundColor Gray
        Write-Log '=== Step 2: Archive Creation Skipped ===' 'INFO'
        for ($i = 0; $i -lt $totalSources; $i++) {
            $archiveResults += @{ Duration = 0; ArchiveName = ''; ArchivePath = $null; TarErrors = @(); Verified = $false }
        }
    } else {
        for ($i = 0; $i -lt $totalSources; $i++) {
            # タイムアウトチェック
            if (Test-Timeout) {
                Write-Host 'ERROR: Operation timed out during archive creation' -ForegroundColor Red
                exit $Script:ExitCodes.TimeoutError
            }

            $sourceEntry = $script:SourceEntries[$i]
            $sourceDir = $sourceEntry.Path
            $sourceName = $sourceEntry.Name
            $sourceMirrorDest = if ($totalSources -eq 1) { $MirrorDest } else { Join-Path $MirrorDest $sourceName }

            $stepNum = $totalSources + $i + 1
            $progress = [math]::Round(($stepNum / $totalSteps) * 100)
            Show-Progress -Activity $script:BackupModeLabel -Status "Creating archive for $sourceName..." -PercentComplete $progress

            if ($totalSources -eq 1) {
                Write-Host "[2/3] Creating archive for $sourceDir..." -ForegroundColor Cyan
            } else {
                Write-Host "[2.$($i + 1)/$totalSources] Creating archive for $sourceDir..." -ForegroundColor Cyan
            }

            if ($sourceEntry.Type -eq 'windows') {
                $archiveResult = New-WindowsArchive -MirrorSource $sourceMirrorDest `
                    -ArchiveDest $ArchiveDest -Timestamp $Timestamp -Verify $script:Config.VerifyArchive `
                    -SourceName $sourceName
            } else {
                $archiveResult = New-Archive -WslDistro $script:Config.WslDistro -SourceDir $sourceDir `
                    -ArchiveDest $ArchiveDest -Timestamp $Timestamp -Verify $script:Config.VerifyArchive `
                    -SourceName $sourceName -Excludes $excludes
            }
            $archiveResults += $archiveResult

            # 履歴に保存
            if (-not $script:DryRunMode -and $archiveResult.ArchivePath -and (Test-Path $archiveResult.ArchivePath)) {
                Save-BackupHistory -HistoryPath $historyPath -BackupInfo @{
                    SourceName  = $sourceName
                    SourcePath  = $sourceDir
                    ArchiveName = $archiveResult.ArchiveName
                    Timestamp   = (Get-Date).ToString('o')
                    Success     = $true
                    Size        = (Get-Item $archiveResult.ArchivePath).Length
                }
            }
        }
    }

    # クリーンアップ
    Show-Progress -Activity $script:BackupModeLabel -Status 'Cleanup...' -PercentComplete 95
    Write-Host '[3/3] Cleanup...' -ForegroundColor Cyan
    $cleanupResult = Remove-OldArchives -ArchiveDest $ArchiveDest -KeepCount $script:Config.KeepCount

    # ログファイルのクリーンアップ
    Remove-OldLogs -LogDir $script:LogDir -KeepCount $script:Config.LogKeepCount

    Complete-Progress
    Write-Host 'Done.' -ForegroundColor Green
    Write-Summary -ScriptStartTime $ScriptStartTime -MirrorResults $mirrorResults -ArchiveResults $archiveResults `
        -CleanupResult $cleanupResult -SkipArchive $script:SkipArchiveFlag -KeepCount $script:Config.KeepCount

    # 通知
    $hasErrors = $false
    foreach ($mr in $mirrorResults) {
        if ($mr.ExitCode -gt $Script:Constants.RobocopySuccessMaxExitCode) {
            $hasErrors = $true
            break
        }
    }

    $totalFiles = ($mirrorResults | ForEach-Object { $_.Stats.FilesCopied } | Measure-Object -Sum).Sum
    $totalSize = ($archiveResults | Where-Object { $_.ArchivePath -and (Test-Path $_.ArchivePath) } |
        ForEach-Object { (Get-Item $_.ArchivePath).Length } | Measure-Object -Sum).Sum / 1MB

    $message = "Files: $totalFiles, Archives: $([math]::Round($totalSize, 1)) MB"

    if ($hasErrors) {
        Send-BackupNotification -Title "$script:BackupModeLabel 完了（警告あり）" -Message $message -Success $false
    } else {
        Send-BackupNotification -Title "$script:BackupModeLabel 完了" -Message $message -Success $true
    }

    exit $Script:ExitCodes.Success
} catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    Write-Log "Unhandled error: $_" 'ERROR'
    Send-BackupNotification -Title "$script:BackupModeLabel 失敗" -Message "$_" -Success $false
    exit $Script:ExitCodes.MirrorError
} finally {
    Complete-Progress

    # ロックファイルの削除
    if (-not $script:DryRunMode) {
        Remove-BackupLock -LockFilePath $lockFilePath
    }
}
