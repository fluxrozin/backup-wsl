#Requires -Version 5.1
<#
.SYNOPSIS
    WSL -> Windows バックアップスクリプト
.DESCRIPTION
    WSLのディレクトリをWindowsにミラーリング＆アーカイブ保存
    - 複数ソースディレクトリのサポート
    - 外部設定ファイル（config.toml）対応
    - ドライランモード、二重実行防止、整合性検証など堅牢な設計
.PARAMETER SkipArchive
    アーカイブ作成をスキップします。ミラーバックアップのみを実行します。
.PARAMETER DryRun
    実際には実行せず、何が行われるかを表示します。
.PARAMETER Source
    バックアップするソースディレクトリを指定します（設定ファイルより優先）。
.NOTES
    Windows側から実行
#>

param(
    [switch]$SkipArchive,
    [switch]$DryRun,
    [string]$Source
)

# ============================================================================
# 定数
# ============================================================================

$Script:Constants = @{
    RobocopySuccessMaxExitCode = 7
    DefaultKeepDays            = 15
    DefaultLogKeepDays         = 30
    LogDateFormat              = 'yyyy-MM-dd HH:mm:ss'
    TimestampFormat            = 'yyyyMMdd_HHmmss'
    LockFileName               = 'backup-wsl.lock'
    ConfigFileName             = 'config.json'  # .json（標準）, .toml, .psd1（標準）, .yaml をサポート
    MinRequiredFreeSpaceGB     = 1
}

# ============================================================================
# 設定読み込み
# ============================================================================

function Import-BackupConfig {
    param([string]$ConfigPath)

    $defaultConfig = @{
        WslDistro           = 'Ubuntu'
        Sources             = @('/home/aoki/projects')
        DestRoot            = 'C:\Users\aoki\Dropbox\Projects_wsl'
        KeepDays            = $Script:Constants.DefaultKeepDays
        LogKeepDays         = $Script:Constants.DefaultLogKeepDays
        AutoElevate         = $true
        ThreadCount         = 0
        ShowNotification    = $true
        VerifyArchive       = $true
        RequiredFreeSpaceGB = 10
    }

    if (Test-Path $ConfigPath) {
        try {
            $extension = [System.IO.Path]::GetExtension($ConfigPath).ToLower()
            $userConfig = $null
            
            # 拡張子に応じて適切なパーサーを使用
            switch ($extension) {
                '.json' {
                    # JSON形式（標準モジュール）
                    $jsonContent = Get-Content $ConfigPath -Raw -Encoding UTF8
                    $userConfig = $jsonContent | ConvertFrom-Json
                }
                '.psd1' {
                    # PowerShell Data File形式（標準モジュール、PowerShell 5以降）
                    $userConfig = Import-PowerShellDataFile -Path $ConfigPath
                }
                '.toml' {
                    # TOML形式（外部モジュール必要）
                    if (-not (Get-Module -ListAvailable -Name PSToml)) {
                        Write-Host "警告: TOML形式の設定ファイルを読み込むには PSToml モジュールが必要です。" -ForegroundColor Yellow
                        Write-Host "  インストール方法: Install-Module -Name PSToml -Scope CurrentUser" -ForegroundColor Yellow
                        Write-Host "  デフォルト設定を使用します。" -ForegroundColor Yellow
                        return $defaultConfig
                    }
                    Import-Module PSToml -ErrorAction Stop
                    $tomlContent = Get-Content $ConfigPath -Raw -Encoding UTF8
                    $userConfig = ConvertFrom-Toml -TomlString $tomlContent
                    
                    # TOMLの配列をPowerShellの配列に変換
                    if ($userConfig.Sources -and $userConfig.Sources -is [System.Collections.ArrayList]) {
                        $userConfig.Sources = $userConfig.Sources.ToArray()
                    }
                }
                { $_ -in '.yaml', '.yml' } {
                    # YAML形式（外部モジュール必要）
                    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
                        Write-Host "警告: YAML形式の設定ファイルを読み込むには powershell-yaml モジュールが必要です。" -ForegroundColor Yellow
                        Write-Host "  インストール方法: Install-Module -Name powershell-yaml -Scope CurrentUser" -ForegroundColor Yellow
                        Write-Host "  デフォルト設定を使用します。" -ForegroundColor Yellow
                        return $defaultConfig
                    }
                    Import-Module powershell-yaml -ErrorAction Stop
                    $yamlContent = Get-Content $ConfigPath -Raw -Encoding UTF8
                    $userConfig = ConvertFrom-Yaml -Yaml $yamlContent
                }
                default {
                    Write-Host "警告: サポートされていない設定ファイル形式です: $extension" -ForegroundColor Yellow
                    Write-Host "  サポート形式: .json（標準）, .psd1（標準）, .toml, .yaml/.yml" -ForegroundColor Yellow
                    Write-Host "  デフォルト設定を使用します。" -ForegroundColor Yellow
                    return $defaultConfig
                }
            }
            
            # 設定をマージ
            foreach ($key in $userConfig.PSObject.Properties.Name) {
                $defaultConfig[$key] = $userConfig.$key
            }
            Write-Host "設定ファイルを読み込みました: $ConfigPath" -ForegroundColor Gray
        }
        catch {
            Write-Host "警告: 設定ファイルの読み込みに失敗しました。デフォルト設定を使用します。" -ForegroundColor Yellow
            Write-Host "  エラー: $_" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "設定ファイルが見つかりません。デフォルト設定を使用します: $ConfigPath" -ForegroundColor Yellow
    }

    return $defaultConfig
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
        [switch]$SkipArchiveParam,
        [switch]$DryRunParam,
        [string]$SourceParam
    )

    if (Test-Administrator) {
        return $false
    }

    Write-Host "管理者権限が必要です。管理者権限で再実行します..." -ForegroundColor Yellow
    Write-Host "UACダイアログが表示されたら「はい」をクリックしてください。" -ForegroundColor Yellow
    Write-Host "（注意: 管理者権限に昇格できるのは、Administratorsグループのメンバーのみです）" -ForegroundColor Gray

    $arguments = "-ExecutionPolicy Bypass -File `"$ScriptPath`""

    if ($SkipArchiveParam) {
        $arguments += " -SkipArchive"
    }
    if ($DryRunParam) {
        $arguments += " -DryRun"
    }
    if ($SourceParam) {
        $arguments += " -Source `"$SourceParam`""
    }

    try {
        Start-Process powershell -Verb RunAs -ArgumentList $arguments -Wait
        exit 0
    }
    catch {
        Write-Host "管理者権限の取得に失敗しました: $_" -ForegroundColor Red
        return $true
    }
}

# ============================================================================
# ロックファイル管理（二重実行防止）
# ============================================================================

function Get-LockFilePath {
    param([string]$WslDistro)
    return Join-Path $env:TEMP "backup-wsl-$WslDistro.lock"
}

function Test-BackupLock {
    param([string]$LockFilePath)

    if (-not (Test-Path $LockFilePath)) {
        return $false
    }

    try {
        $lockContent = Get-Content $LockFilePath -Raw | ConvertFrom-Json
        $process = Get-Process -Id $lockContent.PID -ErrorAction SilentlyContinue
        if ($process) {
            return $true
        }
        # プロセスが存在しない場合、古いロックファイルを削除
        Remove-Item $LockFilePath -Force -ErrorAction SilentlyContinue
        return $false
    }
    catch {
        Remove-Item $LockFilePath -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function New-BackupLock {
    param([string]$LockFilePath)

    $lockContent = @{
        PID       = $PID
        StartTime = (Get-Date).ToString('o')
        Computer  = $env:COMPUTERNAME
        User      = $env:USERNAME
    }
    $lockContent | ConvertTo-Json | Set-Content $LockFilePath -Force
}

function Remove-BackupLock {
    param([string]$LockFilePath)
    Remove-Item $LockFilePath -Force -ErrorAction SilentlyContinue
}

# ============================================================================
# 検証関数
# ============================================================================

function Test-WslHealth {
    param([string]$Distro)

    try {
        $result = wsl -d $Distro -e echo "OK" 2>&1
        if ($result -eq "OK") {
            return $true
        }
        Write-Log "WSL health check failed: $result" 'ERROR'
        return $false
    }
    catch {
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
        $drive = (Get-Item $Path -ErrorAction SilentlyContinue)?.PSDrive
        if (-not $drive) {
            $driveLetter = $Path.Substring(0, 1)
            $drive = Get-PSDrive $driveLetter -ErrorAction SilentlyContinue
        }

        if ($drive -and $drive.Free) {
            $freeGB = $drive.Free / 1GB
            if ($freeGB -lt $RequiredGB) {
                Write-Log "Insufficient disk space: $([math]::Round($freeGB, 2)) GB free, need $RequiredGB GB" 'ERROR'
                return $false
            }
            Write-Log "Disk space check passed: $([math]::Round($freeGB, 2)) GB free" 'INFO'
            return $true
        }

        # ドライブ情報が取得できない場合はチェックをスキップ
        Write-Log "Could not check disk space for path: $Path" 'WARN'
        return $true
    }
    catch {
        Write-Log "Disk space check failed: $_" 'WARN'
        return $true
    }
}

function Test-SafePath {
    param(
        [string]$Path,
        [string]$AllowedRoot
    )

    try {
        $resolved = [System.IO.Path]::GetFullPath($Path)
        $resolvedRoot = [System.IO.Path]::GetFullPath($AllowedRoot)
        return $resolved.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
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
    }
    catch {
        Write-Log "Archive integrity check failed: $_" 'WARN'
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

function Write-MirrorStats {
    param(
        [hashtable]$Stats,
        [string]$Prefix = ''
    )
    if ($Stats.FilesTotal -gt 0) {
        Write-Log "${Prefix}Files: Total=$($Stats.FilesTotal), Copied=$($Stats.FilesCopied), Skipped=$($Stats.FilesSkipped)" 'INFO'
    }
    else {
        Write-Log "${Prefix}Files: Copied=$($Stats.FilesCopied), Skipped=$($Stats.FilesSkipped)" 'INFO'
    }
    if ($Stats.DirsTotal -gt 0) {
        Write-Log "${Prefix}Directories: Total=$($Stats.DirsTotal), Copied=$($Stats.DirsCopied), Skipped=$($Stats.DirsSkipped)" 'INFO'
    }
    else {
        Write-Log "${Prefix}Directories: Copied=$($Stats.DirsCopied), Skipped=$($Stats.DirsSkipped)" 'INFO'
    }
    if ($Stats.BytesCopied -gt 0) {
        Write-Log "${Prefix}Data: $([math]::Round($Stats.BytesCopied / 1MB, 2)) MB" 'INFO'
    }
}

function ConvertTo-WslPath {
    param([string]$WindowsPath)

    $driveLetter = $WindowsPath.Substring(0, 1).ToLower()
    $pathWithoutDrive = $WindowsPath.Substring(2) -replace '\\', '/'
    return "/mnt/$driveLetter$pathWithoutDrive"
}

function Get-SafeSourceName {
    param([string]$SourceDir)
    # パス内の特殊文字をエスケープ
    return ($SourceDir -replace '.*/', '') -replace "'", "'\''"
}

function Read-MirrorIgnore {
    param([string]$IgnoreFilePath)

    $result = @{ Dirs = @(); Files = @() }
    if (-not (Test-Path $IgnoreFilePath)) { return $result }

    Get-Content $IgnoreFilePath | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            if ($line.EndsWith('/')) {
                $result.Dirs += $line.TrimEnd('/')
            }
            else {
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
        }
        catch {
            if ($i -eq $MaxRetries) {
                Write-Log "$OperationName failed after $MaxRetries retries: $_" 'ERROR'
                throw
            }
            Write-Log "$OperationName - Retry $i/$MaxRetries after error: $_" 'WARN'
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Send-BackupNotification {
    param(
        [string]$Title,
        [string]$Message,
        [bool]$Success = $true
    )

    if (-not $script:Config.ShowNotification) {
        return
    }

    try {
        # BurntToast モジュールがある場合はそれを使用
        if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast -ErrorAction SilentlyContinue
            if ($Success) {
                New-BurntToastNotification -Text $Title, $Message -AppLogo $null
            }
            else {
                New-BurntToastNotification -Text $Title, $Message -AppLogo $null
            }
            return
        }

        # フォールバック: PowerShell標準の通知（Windows 10以降）
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
    catch {
        # 通知に失敗しても処理は続行
        Write-Log "Failed to send notification: $_" 'WARN'
    }
}

# ============================================================================
# 除外ディレクトリ削除
# ============================================================================

function Remove-ExcludedDirectories {
    param(
        [string]$MirrorDest,
        [string[]]$ExcludeDirs,
        [string]$Timestamp
    )

    if ($script:DryRunMode) {
        foreach ($excludeDir in $ExcludeDirs) {
            $excludePath = Join-Path $MirrorDest $excludeDir
            if (Test-Path $excludePath) {
                Write-Log "[DryRun] Would delete excluded directory: $excludePath" 'INFO'
            }
        }
        return @()
    }

    $failedDeletions = @()
    foreach ($excludeDir in $ExcludeDirs) {
        $excludePath = Join-Path $MirrorDest $excludeDir
        if (Test-Path $excludePath) {
            try {
                Remove-Item -Path $excludePath -Recurse -Force -ErrorAction Stop
            }
            catch {
                if ($_.Exception.Message -match 'アクセス|Access|権限|Permission|denied') {
                    if (-not (Test-Administrator)) {
                        Write-Host "  Warning: 管理者権限が必要な可能性があります: $excludePath" -ForegroundColor Yellow
                    }
                }
                $failedDeletions += @{
                    Path  = $excludePath
                    Error = $_.Exception.Message
                    Time  = Get-Date -Format $Script:Constants.LogDateFormat
                }
            }
        }
    }

    if ($failedDeletions.Count -gt 0) {
        Write-Log "Warning: Failed to delete $($failedDeletions.Count) excluded directory/directories" 'WARN'
        foreach ($item in $failedDeletions) {
            Write-Log "  Failed: $($item.Path) - $($item.Error)" 'WARN'
        }

        $auditLog = Join-Path $script:LogDir "cleanup_audit_$Timestamp.log"
        $logContent = @"
=== Cleanup Audit Log ===
Timestamp: $(Get-Date -Format $Script:Constants.LogDateFormat)
Mirror: $MirrorDest

Failed to delete excluded directories:
"@
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
        FilesCopied  = 0; FilesSkipped = 0; FilesTotal = 0
        DirsCopied   = 0; DirsSkipped = 0; DirsTotal = 0
        BytesCopied  = 0
        Errors       = @()
    }

    if (-not (Test-Path $LogPath)) { return $stats }

    try {
        $shiftJis = [System.Text.Encoding]::GetEncoding('shift_jis')
        $utf8 = [System.Text.Encoding]::UTF8
        $logBytes = [System.IO.File]::ReadAllBytes($LogPath)
        $logText = $shiftJis.GetString($logBytes)
        [System.IO.File]::WriteAllText($LogPath, $logText, $utf8)

        foreach ($line in ($logText -split "`r?`n")) {
            if ($line -match 'Files\s*:\s*(\d+)\s+(\d+)\s+(\d+)') {
                $stats.FilesTotal = [int]$matches[1]
                $stats.FilesCopied = [int]$matches[2]
                $stats.FilesSkipped = [int]$matches[3]
            }
            if ($line -match 'Dirs\s*:\s*(\d+)\s+(\d+)\s+(\d+)') {
                $stats.DirsTotal = [int]$matches[1]
                $stats.DirsCopied = [int]$matches[2]
                $stats.DirsSkipped = [int]$matches[3]
            }
            # Bytes行の改善: 数値と単位の両方に対応
            if ($line -match 'Bytes\s*:\s*([\d.]+)\s*([kmgt]?)') {
                $value = [double]$matches[1]
                $unit = $matches[2].ToLower()
                switch ($unit) {
                    'k' { $stats.BytesCopied = [long]($value * 1KB) }
                    'm' { $stats.BytesCopied = [long]($value * 1MB) }
                    'g' { $stats.BytesCopied = [long]($value * 1GB) }
                    't' { $stats.BytesCopied = [long]($value * 1TB) }
                    default { $stats.BytesCopied = [long]$value }
                }
            }
            if ($line -match '(エラー|Error|ERROR)\s+(\d+)') {
                $stats.Errors += $line
            }
        }
    }
    catch {
        Write-Log "Failed to parse robocopy log: $_" 'WARN'
    }

    return $stats
}

# ============================================================================
# ミラーリング処理
# ============================================================================

function Invoke-Mirroring {
    param(
        [string]$WslSource,
        [string]$MirrorDest,
        [hashtable]$Excludes,
        [string]$Timestamp,
        [int]$ThreadCount
    )

    $startTime = Get-Date
    Write-Log '=== Step 1: Mirroring Started ===' 'INFO'
    Write-Log "Source: $WslSource" 'INFO'
    Write-Log "Destination: $MirrorDest" 'INFO'

    $failedDeletions = Remove-ExcludedDirectories -MirrorDest $MirrorDest -ExcludeDirs $Excludes.Dirs -Timestamp $Timestamp

    if ($script:DryRunMode) {
        Write-Log "[DryRun] Would run robocopy from $WslSource to $MirrorDest" 'INFO'
        return @{
            Duration        = 0
            Stats           = @{ FilesCopied = 0; FilesSkipped = 0; DirsCopied = 0; DirsSkipped = 0; BytesCopied = 0; Errors = @() }
            ExitCode        = 0
            FailedDeletions = @()
        }
    }

    $robocopyLog = Join-Path $script:LogDir "robocopy_$Timestamp.log"

    # スレッド数の決定
    $actualThreadCount = if ($ThreadCount -gt 0) {
        $ThreadCount
    }
    else {
        [Math]::Min([Environment]::ProcessorCount, 16)
    }

    $robocopyArgs = @($WslSource, $MirrorDest, '/MIR', '/R:1', '/W:0', "/MT:$actualThreadCount", '/NP', "/LOG:$robocopyLog")

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

    $errorLog = Join-Path $env:TEMP "robocopy_error_$PID.log"
    $outputLog = Join-Path $env:TEMP "robocopy_output_$PID.log"
    $process = Start-Process -FilePath 'robocopy' -ArgumentList $robocopyArgs -NoNewWindow -PassThru -Wait -RedirectStandardError $errorLog -RedirectStandardOutput $outputLog

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
    Write-Log "  Exit Code: $($process.ExitCode)" 'INFO'

    if ($process.ExitCode -le $Script:Constants.RobocopySuccessMaxExitCode) {
        Write-Host "  OK (exit=$($process.ExitCode))" -ForegroundColor Green
    }
    else {
        Write-Host "  WARNING: exit=$($process.ExitCode)" -ForegroundColor Yellow
        Write-Log "Warning: Robocopy exit code $($process.ExitCode)" 'WARN'
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
        [bool]$Verify
    )

    $startTime = Get-Date
    Write-Log '=== Step 2: Archive Creation Started ===' 'INFO'

    $targetName = Get-SafeSourceName -SourceDir $SourceDir
    $parentDir = $SourceDir -replace '/[^/]+$', ''
    if (-not $parentDir) { $parentDir = '/' }

    $archiveName = "${targetName}_$Timestamp.tar.gz"
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

    $tarErrorLog = Join-Path $script:LogDir "tar_errors_$Timestamp.log"
    $tarErrorLogWsl = ConvertTo-WslPath -WindowsPath $tarErrorLog

    # シングルクォートを含むパスのエスケープ
    $safeTargetName = $targetName -replace "'", "'\\''"
    $safeParentDir = $parentDir -replace "'", "'\\''"

    $tarCmd = "tar -czf '$archivePathWsl' --ignore-failed-read -C '$safeParentDir' '$safeTargetName' 2>'$tarErrorLogWsl'"

    Invoke-WithRetry -OperationName 'Archive creation' -MaxRetries 2 -DelaySeconds 3 -ScriptBlock {
        wsl -d $WslDistro -e bash -c $tarCmd
    }

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

        if ($Verify) {
            Write-Host "  Verifying archive..." -ForegroundColor Gray
            $verified = Test-ArchiveIntegrity -ArchivePath $archivePath -WslDistro $WslDistro
            if ($verified) {
                Write-Host "  Integrity check: OK" -ForegroundColor Green
                Write-Log "  Integrity check: PASSED" 'INFO'
            }
            else {
                Write-Host "  Integrity check: FAILED" -ForegroundColor Red
                Write-Log "  Integrity check: FAILED" 'WARN'
            }
        }

        if ($tarErrors.Count -gt 0) {
            Write-Log "  Warnings: $($tarErrors.Count) files skipped" 'WARN'
        }
    }
    else {
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

# ============================================================================
# クリーンアップ処理
# ============================================================================

function Remove-OldArchives {
    param(
        [string]$ArchiveDest,
        [int]$KeepDays
    )

    $startTime = Get-Date
    Write-Log '=== Step 3: Cleanup Started ===' 'INFO'

    $deletedCount = 0
    $deletedSize = 0

    if ($KeepDays -gt 0) {
        $cutoff = (Get-Date).AddDays(-$KeepDays)
        $old = Get-ChildItem $ArchiveDest -Filter '*.tar.gz' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff }
        $deletedCount = ($old | Measure-Object).Count
        $deletedSize = ($old | Measure-Object -Property Length -Sum).Sum / 1MB

        if ($deletedCount -gt 0) {
            foreach ($file in $old) {
                Write-Log "Deleting old archive: $($file.Name)" 'INFO'
            }

            if ($script:DryRunMode) {
                Write-Log "[DryRun] Would delete $deletedCount old archive(s)" 'INFO'
            }
            else {
                try {
                    $old | Remove-Item -Force -ErrorAction Stop
                    Write-Host "  Deleted $deletedCount old archive(s)" -ForegroundColor Green
                    Write-Log "Deleted $deletedCount old archive(s), freed $([math]::Round($deletedSize, 2)) MB" 'INFO'
                }
                catch {
                    if ($_.Exception.Message -match 'アクセス|Access|権限|Permission|denied') {
                        Write-Host "  Warning: 一部のファイルの削除に失敗しました（権限不足の可能性）" -ForegroundColor Yellow
                        Write-Log "Warning: Failed to delete some archives: $($_.Exception.Message)" 'WARN'
                    }
                    else {
                        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
                        Write-Log "Error: Failed to delete archives: $($_.Exception.Message)" 'ERROR'
                    }
                }
            }
        }
        else {
            Write-Host '  No old archives to delete' -ForegroundColor Gray
            Write-Log 'No old archives to delete' 'INFO'
        }
    }
    else {
        Write-Host '  Skipped (KeepDays=0)' -ForegroundColor Gray
        Write-Log 'Cleanup skipped (KeepDays=0)' 'INFO'
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
        [int]$KeepDays
    )

    if ($KeepDays -le 0) {
        return
    }

    if ($script:DryRunMode) {
        Write-Log "[DryRun] Would clean up logs older than $KeepDays days" 'INFO'
        return
    }

    $cutoff = (Get-Date).AddDays(-$KeepDays)
    $oldLogs = Get-ChildItem $LogDir -Filter '*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff }
    $count = ($oldLogs | Measure-Object).Count

    if ($count -gt 0) {
        $oldLogs | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Log "Deleted $count old log file(s)" 'INFO'
    }
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
        [int]$KeepDays
    )

    $endTime = Get-Date
    $totalDuration = ($endTime - $ScriptStartTime).TotalSeconds

    Write-Log '=== Backup Summary ===' 'INFO'
    Write-Log "Start Time: $($ScriptStartTime.ToString($Script:Constants.LogDateFormat))" 'INFO'
    Write-Log "End Time: $($endTime.ToString($Script:Constants.LogDateFormat))" 'INFO'
    Write-Log "Total Duration: $([math]::Round($totalDuration, 2)) seconds ($([math]::Round($totalDuration / 60, 2)) minutes)" 'INFO'
    Write-Log '' 'INFO'

    for ($i = 0; $i -lt $MirrorResults.Count; $i++) {
        $mirrorResult = $MirrorResults[$i]
        Write-Log "Step 1.$($i + 1) - Mirroring ($($script:Config.Sources[$i])):" 'INFO'
        Write-Log "  Duration: $([math]::Round($mirrorResult.Duration, 2)) seconds" 'INFO'
        Write-MirrorStats -Stats $mirrorResult.Stats -Prefix '  '
        Write-Log "  Exit Code: $($mirrorResult.ExitCode)" 'INFO'
        Write-Log '' 'INFO'
    }

    Write-Log 'Step 2 - Archive:' 'INFO'
    if ($SkipArchive) {
        Write-Log '  Status: SKIPPED' 'INFO'
        Write-Log '  Reason: User requested to skip archive creation' 'INFO'
    }
    else {
        for ($i = 0; $i -lt $ArchiveResults.Count; $i++) {
            $archiveResult = $ArchiveResults[$i]
            Write-Log "  Source $($i + 1):" 'INFO'
            Write-Log "    Duration: $([math]::Round($archiveResult.Duration, 2)) seconds" 'INFO'
            if ($archiveResult.ArchivePath -and (Test-Path $archiveResult.ArchivePath)) {
                $archiveSize = (Get-Item $archiveResult.ArchivePath).Length / 1MB
                Write-Log "    Archive: $($archiveResult.ArchiveName)" 'INFO'
                Write-Log "    Size: $([math]::Round($archiveSize, 2)) MB" 'INFO'
                if ($archiveResult.Verified) {
                    Write-Log "    Integrity: VERIFIED" 'INFO'
                }
                if ($archiveResult.TarErrors.Count -gt 0) {
                    Write-Log "    Warnings: $($archiveResult.TarErrors.Count) files skipped during archive creation" 'WARN'
                }
            }
            else {
                Write-Log '    Status: FAILED' 'ERROR'
            }
        }
    }
    Write-Log '' 'INFO'

    Write-Log 'Step 3 - Cleanup:' 'INFO'
    Write-Log "  Duration: $([math]::Round($CleanupResult.Duration, 2)) seconds" 'INFO'
    if ($KeepDays -gt 0) {
        Write-Log "  Old archives deleted: $($CleanupResult.DeletedCount)" 'INFO'
    }
    else {
        Write-Log '  Cleanup: Disabled (KeepDays=0)' 'INFO'
    }
    Write-Log '' 'INFO'

    $hasErrors = $false
    foreach ($mirrorResult in $MirrorResults) {
        if ($mirrorResult.Stats.Errors.Count -gt 0 -or $mirrorResult.FailedDeletions.Count -gt 0) {
            $hasErrors = $true
            break
        }
    }
    if (-not $hasErrors) {
        foreach ($archiveResult in $ArchiveResults) {
            if ($archiveResult.TarErrors.Count -gt 0) {
                $hasErrors = $true
                break
            }
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
        foreach ($archiveResult in $ArchiveResults) {
            if ($archiveResult.TarErrors.Count -gt 0) {
                Write-Log "  Tar warnings: $($archiveResult.TarErrors.Count)" 'WARN'
            }
        }
    }

    Write-Log '=== WSL Backup Completed ===' 'INFO'
    Write-Log "Log file: $script:MainLog" 'INFO'
}

# ============================================================================
# メイン処理
# ============================================================================

# グローバル変数の初期化
$script:DryRunMode = $DryRun.IsPresent

# 設定ファイルの読み込み（優先順位: JSON > PSD1 > TOML > YAML）
$configPath = $null
$possibleConfigFiles = @(
    (Join-Path $PSScriptRoot 'config.json'),
    (Join-Path $PSScriptRoot 'config.psd1'),
    (Join-Path $PSScriptRoot 'config.toml'),
    (Join-Path $PSScriptRoot 'config.yaml'),
    (Join-Path $PSScriptRoot 'config.yml')
)
foreach ($possiblePath in $possibleConfigFiles) {
    if (Test-Path $possiblePath) {
        $configPath = $possiblePath
        break
    }
}
# どれも見つからない場合はデフォルト（JSON）を使用
if (-not $configPath) {
    $configPath = Join-Path $PSScriptRoot $Script:Constants.ConfigFileName
}
$script:Config = Import-BackupConfig -ConfigPath $configPath

# コマンドライン引数で上書き
if ($Source) {
    $script:Config.Sources = @($Source)
}

# SkipArchiveの設定
$script:SkipArchiveFlag = $SkipArchive.IsPresent

# ドライランモードの表示
if ($script:DryRunMode) {
    Write-Host "=== DRY RUN MODE ===" -ForegroundColor Magenta
    Write-Host "実際には何も変更されません。" -ForegroundColor Magenta
    Write-Host ""
}

# ロックファイルによる二重実行防止
$lockFilePath = Get-LockFilePath -WslDistro $script:Config.WslDistro
if (Test-BackupLock -LockFilePath $lockFilePath) {
    Write-Host "エラー: バックアップが既に実行中です。" -ForegroundColor Red
    Write-Host "  ロックファイル: $lockFilePath" -ForegroundColor Red
    Write-Host "  他のバックアッププロセスが実行中でないことを確認してください。" -ForegroundColor Yellow
    exit 1
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
    }
    catch {
        if ($_.Exception.Message -match 'アクセス|Access|権限|Permission|denied') {
            $needsAdmin = $true
        }
    }

    if (-not $needsAdmin) {
        try {
            if (-not (Test-Path (Split-Path $MirrorDest -Parent))) {
                $needsAdmin = $true
            }
        }
        catch {
            $needsAdmin = $true
        }
    }

    if ($needsAdmin) {
        if ($script:Config.AutoElevate) {
            if (Request-Administrator -ScriptPath $scriptPath -SkipArchiveParam:$script:SkipArchiveFlag -DryRunParam:$script:DryRunMode -SourceParam $Source) {
                exit 1
            }
        }
        else {
            Write-Host "エラー: 管理者権限が必要ですが、自動昇格が無効になっています。" -ForegroundColor Red
            Write-Host "解決方法:" -ForegroundColor Yellow
            Write-Host "  1. 管理者権限でPowerShellを開いてスクリプトを実行する" -ForegroundColor Yellow
            Write-Host "  2. または、設定で AutoElevate = `$true に設定する" -ForegroundColor Yellow
            exit 1
        }
    }
}

# ロックファイルの作成
if (-not $script:DryRunMode) {
    New-BackupLock -LockFilePath $lockFilePath
}

try {
    $Timestamp = Get-Date -Format $Script:Constants.TimestampFormat
    $ScriptStartTime = Get-Date

    $MirrorDest = Join-Path $script:Config.DestRoot 'mirror'
    $ArchiveDest = Join-Path $script:Config.DestRoot 'archive'
    $script:LogDir = Join-Path $PSScriptRoot 'logs'

    # ディレクトリ作成
    if (-not $script:DryRunMode) {
        try {
            New-Item -ItemType Directory -Force -Path $MirrorDest -ErrorAction Stop | Out-Null
            New-Item -ItemType Directory -Force -Path $ArchiveDest -ErrorAction Stop | Out-Null
            New-Item -ItemType Directory -Force -Path $script:LogDir -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Host "エラー: ディレクトリの作成に失敗しました: $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
    }

    $script:MainLog = Join-Path $script:LogDir "backup_$Timestamp.log"

    Write-Host "WSL Backup: $($script:Config.Sources -join ', ') -> $($script:Config.DestRoot)"
    Write-Log '=== WSL Backup Started ===' 'INFO'
    Write-Log "Sources: $($script:Config.Sources -join ', ')" 'INFO'
    Write-Log "Destination: $($script:Config.DestRoot)" 'INFO'
    Write-Log "WSL Distribution: $($script:Config.WslDistro)" 'INFO'
    if ($script:SkipArchiveFlag) {
        Write-Log 'Archive Creation: SKIPPED (via command-line argument)' 'INFO'
    }
    if ($script:DryRunMode) {
        Write-Log 'Mode: DRY RUN' 'INFO'
    }
    Write-Log "Start Time: $($ScriptStartTime.ToString($Script:Constants.LogDateFormat))" 'INFO'

    # WSLの状態確認
    Write-Host "Checking WSL health..." -ForegroundColor Gray
    if (-not (Test-WslHealth -Distro $script:Config.WslDistro)) {
        Write-Host "ERROR: WSL is not responding or distribution '$($script:Config.WslDistro)' is not available" -ForegroundColor Red
        Write-Host "  Check: wsl -l -v" -ForegroundColor Yellow
        Write-Log "ERROR: WSL health check failed" 'ERROR'
        exit 1
    }
    Write-Log 'WSL health check passed' 'INFO'

    # ディスク容量チェック
    if (-not (Test-DiskSpace -Path $script:Config.DestRoot -RequiredGB $script:Config.RequiredFreeSpaceGB)) {
        Write-Host "ERROR: Insufficient disk space" -ForegroundColor Red
        exit 1
    }

    # ソースディレクトリの確認
    foreach ($sourceDir in $script:Config.Sources) {
        $WslSource = "\\wsl.localhost\$($script:Config.WslDistro)" + ($sourceDir -replace '/', '\')
        if (-not (Test-Path $WslSource)) {
            Write-Host "ERROR: Source not found: $WslSource" -ForegroundColor Red
            Write-Host "  WSL is running? -> wsl -d $($script:Config.WslDistro)"
            Write-Log "ERROR: Source directory not found: $WslSource" 'ERROR'
            exit 1
        }
    }
    Write-Log 'Source directories verified' 'INFO'

    # 除外パターンの読み込み
    $excludes = Read-MirrorIgnore -IgnoreFilePath (Join-Path $PSScriptRoot '.mirrorignore')

    # ミラーリング処理（複数ソース対応）
    $mirrorResults = @()
    $totalSources = $script:Config.Sources.Count

    for ($i = 0; $i -lt $totalSources; $i++) {
        $sourceDir = $script:Config.Sources[$i]
        $sourceName = $sourceDir -replace '.*/', ''
        $WslSource = "\\wsl.localhost\$($script:Config.WslDistro)" + ($sourceDir -replace '/', '\')
        $sourceMirrorDest = if ($totalSources -eq 1) { $MirrorDest } else { Join-Path $MirrorDest $sourceName }

        if ($totalSources -eq 1) {
            Write-Host "[1/3] Mirroring $sourceDir..." -ForegroundColor Cyan
        }
        else {
            Write-Host "[1.$($i + 1)/$totalSources] Mirroring $sourceDir..." -ForegroundColor Cyan
        }

        if ($totalSources -gt 1 -and -not $script:DryRunMode) {
            New-Item -ItemType Directory -Force -Path $sourceMirrorDest -ErrorAction SilentlyContinue | Out-Null
        }

        $mirrorResult = Invoke-Mirroring -WslSource $WslSource -MirrorDest $sourceMirrorDest -Excludes $excludes -Timestamp $Timestamp -ThreadCount $script:Config.ThreadCount
        $mirrorResults += $mirrorResult
    }

    # アーカイブ作成処理（複数ソース対応）
    $archiveResults = @()

    if ($script:SkipArchiveFlag) {
        Write-Host '[2/3] Creating archive... (SKIPPED)' -ForegroundColor Gray
        Write-Log '=== Step 2: Archive Creation Skipped ===' 'INFO'
        for ($i = 0; $i -lt $totalSources; $i++) {
            $archiveResults += @{ Duration = 0; ArchiveName = ''; ArchivePath = $null; TarErrors = @(); Verified = $false }
        }
    }
    else {
        for ($i = 0; $i -lt $totalSources; $i++) {
            $sourceDir = $script:Config.Sources[$i]
            if ($totalSources -eq 1) {
                Write-Host "[2/3] Creating archive for $sourceDir..." -ForegroundColor Cyan
            }
            else {
                Write-Host "[2.$($i + 1)/$totalSources] Creating archive for $sourceDir..." -ForegroundColor Cyan
            }
            $archiveResult = New-Archive -WslDistro $script:Config.WslDistro -SourceDir $sourceDir -ArchiveDest $ArchiveDest -Timestamp $Timestamp -Verify $script:Config.VerifyArchive
            $archiveResults += $archiveResult
        }
    }

    # クリーンアップ
    Write-Host '[3/3] Cleanup...' -ForegroundColor Cyan
    $cleanupResult = Remove-OldArchives -ArchiveDest $ArchiveDest -KeepDays $script:Config.KeepDays

    # ログファイルのクリーンアップ
    Remove-OldLogs -LogDir $script:LogDir -KeepDays $script:Config.LogKeepDays

    Write-Host 'Done.' -ForegroundColor Green
    Write-Summary -ScriptStartTime $ScriptStartTime -MirrorResults $mirrorResults -ArchiveResults $archiveResults -CleanupResult $cleanupResult -SkipArchive $script:SkipArchiveFlag -KeepDays $script:Config.KeepDays

    # 通知
    $hasErrors = $false
    foreach ($mr in $mirrorResults) {
        if ($mr.ExitCode -gt $Script:Constants.RobocopySuccessMaxExitCode) {
            $hasErrors = $true
            break
        }
    }

    if ($hasErrors) {
        Send-BackupNotification -Title "WSL Backup 完了（警告あり）" -Message "バックアップは完了しましたが、一部のファイルで警告が発生しました。" -Success $false
    }
    else {
        Send-BackupNotification -Title "WSL Backup 完了" -Message "バックアップが正常に完了しました。" -Success $true
    }
}
finally {
    # ロックファイルの削除
    if (-not $script:DryRunMode) {
        Remove-BackupLock -LockFilePath $lockFilePath
    }
}
