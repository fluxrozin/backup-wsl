#Requires -Version 5.1
<#
.SYNOPSIS
    WSL → Windows バックアップスクリプト
.DESCRIPTION
    WSLのディレクトリをWindowsにミラーリング＆アーカイブ保存
.NOTES
    Windows側から実行
#>

# ============================================================================
# 設定
# ============================================================================

$Config = @{
    WslDistro  = "Ubuntu"
    SourceDir  = "/home/aoki/projects"
    DestRoot   = "C:\Users\aoki\Dropbox\Projects_wsl"
    KeepDays   = 15  # 0で無制限
}

# ============================================================================
# 初期化
# ============================================================================

$Timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$TargetName  = $Config.SourceDir -replace '.*/', ''
$ParentDir   = $Config.SourceDir -replace '/[^/]+$', ''
if (-not $ParentDir) { $ParentDir = '/' }

$MirrorDest  = Join-Path $Config.DestRoot "mirror"
$ArchiveDest = Join-Path $Config.DestRoot "archive"
$WslSource   = "\\wsl.localhost\$($Config.WslDistro)" + ($Config.SourceDir -replace '/', '\')

# ============================================================================
# メイン処理
# ============================================================================

Write-Host "WSL Backup: $($Config.SourceDir) -> $($Config.DestRoot)"

# 前提条件チェック
if (-not (Test-Path $WslSource)) {
    Write-Host "ERROR: Source not found: $WslSource" -ForegroundColor Red
    Write-Host "  WSL is running? -> wsl -d $($Config.WslDistro)"
    exit 1
}

# ディレクトリ作成
New-Item -ItemType Directory -Force -Path $MirrorDest | Out-Null
New-Item -ItemType Directory -Force -Path $ArchiveDest | Out-Null

# [1] ミラーリング
Write-Host "[1/3] Mirroring..." -ForegroundColor Cyan

# .mirrorignoreから除外パターン読み込み
$ignoreFile = Join-Path $PSScriptRoot ".mirrorignore"
$excludeDirs = @()
$excludeFiles = @()
if (Test-Path $ignoreFile) {
    Get-Content $ignoreFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#")) {
            if ($line.EndsWith("/")) {
                $excludeDirs += $line.TrimEnd("/")
            } else {
                $excludeFiles += $line
            }
        }
    }
}

$robocopyArgs = @($WslSource, $MirrorDest, "/MIR", "/R:1", "/W:0", "/MT", "/NP", "/NFL", "/NDL", "/NJH", "/NJS")
if ($excludeDirs.Count -gt 0) {
    $robocopyArgs += "/XD"
    $robocopyArgs += $excludeDirs
}
if ($excludeFiles.Count -gt 0) {
    $robocopyArgs += "/XF"
    $robocopyArgs += $excludeFiles
}

$result = Start-Process -FilePath "robocopy" -ArgumentList $robocopyArgs -NoNewWindow -PassThru -Wait

if ($result.ExitCode -lt 8) {
    Write-Host "  OK (exit=$($result.ExitCode))" -ForegroundColor Green
} else {
    Write-Host "  WARNING: exit=$($result.ExitCode)" -ForegroundColor Yellow
}

# [2] アーカイブ作成
Write-Host "[2/3] Creating archive..." -ForegroundColor Cyan
$archiveName = "${TargetName}_$Timestamp.tar.gz"
$archivePath = Join-Path $ArchiveDest $archiveName
$archivePathWsl = "/mnt/" + $archivePath.Substring(0,1).ToLower() + ($archivePath.Substring(2) -replace '\\', '/')

$tarCmd = "tar -czf '$archivePathWsl' --ignore-failed-read -C '$ParentDir' '$TargetName' 2>/dev/null"
wsl -d $Config.WslDistro -e bash -c $tarCmd

if (Test-Path $archivePath) {
    $size = (Get-Item $archivePath).Length / 1MB
    Write-Host "  OK: $archiveName ($("{0:N1}" -f $size) MB)" -ForegroundColor Green
} else {
    Write-Host "  ERROR: Archive not created" -ForegroundColor Red
}

# [3] 古いアーカイブ削除
Write-Host "[3/3] Cleanup..." -ForegroundColor Cyan
if ($Config.KeepDays -gt 0) {
    $cutoff = (Get-Date).AddDays(-$Config.KeepDays)
    $old = Get-ChildItem $ArchiveDest -Filter "*.tar.gz" | Where-Object { $_.LastWriteTime -lt $cutoff }
    $count = ($old | Measure-Object).Count
    $old | Remove-Item -Force
    Write-Host "  Deleted $count old archive(s)" -ForegroundColor Green
} else {
    Write-Host "  Skipped (KeepDays=0)" -ForegroundColor Gray
}

Write-Host "Done." -ForegroundColor Green
