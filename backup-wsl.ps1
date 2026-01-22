#Requires -Version 5.1
<#
.SYNOPSIS
    WSL → Windows バックアップスクリプト
.DESCRIPTION
    WSLのディレクトリをWindowsにミラーリング＆アーカイブ保存
.PARAMETER SkipArchive
    アーカイブ作成をスキップします。ミラーバックアップのみを実行します。
.NOTES
    Windows側から実行
#>

# ============================================================================
# コマンドライン引数の処理
# ============================================================================

param(
    [switch]$SkipArchive  # アーカイブ作成をスキップ
)

# ============================================================================
# 設定
# ============================================================================

$Config = @{
    WslDistro   = 'Ubuntu'
    SourceDir   = '/home/aoki/projects'
    DestRoot    = 'C:\Users\aoki\Dropbox\Projects_wsl'
    KeepDays    = 15  # 0で無制限
    SkipArchive = $false  # アーカイブ作成をスキップするか（$true = スキップ）
}

# コマンドライン引数で上書き
if ($SkipArchive) {
    $Config.SkipArchive = $true
}

# ============================================================================
# 初期化
# ============================================================================

$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$TargetName = $Config.SourceDir -replace '.*/', ''
$ParentDir = $Config.SourceDir -replace '/[^/]+$', ''
if (-not $ParentDir) { $ParentDir = '/' }

$MirrorDest = Join-Path $Config.DestRoot 'mirror'
$ArchiveDest = Join-Path $Config.DestRoot 'archive'
$LogDir = Join-Path $PSScriptRoot 'logs'  # スクリプトフォルダに保存（一般的なベストプラクティス）
$WslSource = "\\wsl.localhost\$($Config.WslDistro)" + ($Config.SourceDir -replace '/', '\')

# ============================================================================
# メイン処理
# ============================================================================

# ディレクトリ作成（ログ開始前に必要）
New-Item -ItemType Directory -Force -Path $MirrorDest | Out-Null
New-Item -ItemType Directory -Force -Path $ArchiveDest | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# ログファイル設定
$mainLog = Join-Path $LogDir "backup_$Timestamp.log"
$startTime = Get-Date
$scriptStartTime = $startTime

# ログ関数
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $mainLog -Value $logEntry -Encoding UTF8
}

# ログ開始
Write-Host "WSL Backup: $($Config.SourceDir) -> $($Config.DestRoot)"
Write-Log '=== WSL Backup Started ===' 'INFO'
Write-Log "Source: $($Config.SourceDir)" 'INFO'
Write-Log "Destination: $($Config.DestRoot)" 'INFO'
Write-Log "WSL Distribution: $($Config.WslDistro)" 'INFO'
if ($Config.SkipArchive) {
    if ($SkipArchive) {
        Write-Log 'Archive Creation: SKIPPED (via command-line argument)' 'INFO'
    } else {
        Write-Log 'Archive Creation: SKIPPED (via config)' 'INFO'
    }
}
Write-Log "Start Time: $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))" 'INFO'

# 前提条件チェック
if (-not (Test-Path $WslSource)) {
    Write-Host "ERROR: Source not found: $WslSource" -ForegroundColor Red
    Write-Host "  WSL is running? -> wsl -d $($Config.WslDistro)"
    Write-Log "ERROR: Source directory not found: $WslSource" 'ERROR'
    Write-Log 'Backup failed' 'ERROR'
    exit 1
}
Write-Log 'Source directory verified' 'INFO'

# [1] ミラーリング
Write-Host '[1/3] Mirroring...' -ForegroundColor Cyan
$mirrorStartTime = Get-Date
Write-Log '=== Step 1: Mirroring Started ===' 'INFO'

# .mirrorignoreから除外パターン読み込み
$ignoreFile = Join-Path $PSScriptRoot '.mirrorignore'
$excludeDirs = @()
$excludeFiles = @()
if (Test-Path $ignoreFile) {
    Get-Content $ignoreFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            if ($line.EndsWith('/')) {
                $excludeDirs += $line.TrimEnd('/')
            } else {
                $excludeFiles += $line
            }
        }
    }
}

# 除外対象のディレクトリがミラー先に存在する場合、事前に削除を試みる
# （robocopyが削除できない場合の残留を防ぐため）
$auditLog = Join-Path $LogDir "cleanup_audit_$Timestamp.log"
$failedDeletions = @()
foreach ($excludeDir in $excludeDirs) {
    $excludePath = Join-Path $MirrorDest $excludeDir
    if (Test-Path $excludePath) {
        try {
            Remove-Item -Path $excludePath -Recurse -Force -ErrorAction Stop
        } catch {
            # 削除できない場合（ファイル使用中など）はログに記録
            $failedDeletions += @{
                Path  = $excludePath
                Error = $_.Exception.Message
                Time  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            }
        }
    }
}

# 削除失敗をログファイルに記録
if ($failedDeletions.Count -gt 0) {
    Write-Log "Warning: Failed to delete $($failedDeletions.Count) excluded directory/directories" 'WARN'
    foreach ($item in $failedDeletions) {
        Write-Log "  Failed: $($item.Path) - $($item.Error)" 'WARN'
    }
    $logContent = @"
=== Cleanup Audit Log ===
Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Source: $($Config.SourceDir)
Mirror: $MirrorDest

Failed to delete excluded directories:
"@
    foreach ($item in $failedDeletions) {
        $logContent += "`n[$($item.Time)] $($item.Path)`n  Error: $($item.Error)"
    }
    $logContent | Out-File -FilePath $auditLog -Encoding UTF8 -Append
}

# robocopyログファイル設定
$robocopyLog = Join-Path $LogDir "robocopy_$Timestamp.log"
$robocopyArgs = @($WslSource, $MirrorDest, '/MIR', '/R:1', '/W:0', '/MT', '/NP', "/LOG:$robocopyLog")
if ($excludeDirs.Count -gt 0) {
    $robocopyArgs += '/XD'
    $robocopyArgs += $excludeDirs
    Write-Log "Excluding directories: $($excludeDirs -join ', ')" 'INFO'
}
if ($excludeFiles.Count -gt 0) {
    $robocopyArgs += '/XF'
    $robocopyArgs += $excludeFiles
    Write-Log "Excluding files: $($excludeFiles -join ', ')" 'INFO'
}

# エラーメッセージと標準出力を一時ファイルにリダイレクトして抑制
$errorLog = Join-Path $env:TEMP "robocopy_error_$PID.log"
$outputLog = Join-Path $env:TEMP "robocopy_output_$PID.log"
$result = Start-Process -FilePath 'robocopy' -ArgumentList $robocopyArgs -NoNewWindow -PassThru -Wait -RedirectStandardError $errorLog -RedirectStandardOutput $outputLog
$mirrorEndTime = Get-Date
$mirrorDuration = ($mirrorEndTime - $mirrorStartTime).TotalSeconds

# robocopyログから統計情報を取得
$filesCopied = 0
$filesSkipped = 0
$filesTotal = 0
$dirsCopied = 0
$dirsSkipped = 0
$dirsTotal = 0
$bytesCopied = 0
$errors = @()

if (Test-Path $robocopyLog) {
    # robocopyのログはShift-JISで出力されるため、Shift-JISとして読み込んでUTF-8に変換
    $shiftJis = [System.Text.Encoding]::GetEncoding('shift_jis')
    $utf8 = [System.Text.Encoding]::UTF8
    $logBytes = [System.IO.File]::ReadAllBytes($robocopyLog)
    $logText = $shiftJis.GetString($logBytes)
    # UTF-8で再保存
    [System.IO.File]::WriteAllText($robocopyLog, $logText, $utf8)
    # 行ごとに処理
    $logContent = $logText -split "`r?`n"
    foreach ($line in $logContent) {
        # robocopyの統計行をパース（例: "   Files :        10         5         5         0         0         0"）
        if ($line -match 'Files\s*:\s*(\d+)\s+(\d+)\s+(\d+)') {
            $filesTotal = [int]$matches[1]
            $filesCopied = [int]$matches[2]
            $filesSkipped = [int]$matches[3]
        }
        # 別の形式（例: "   Files :         5         0         5"）
        elseif ($line -match 'Files\s*:\s*(\d+)\s+(\d+)\s+(\d+)') {
            $filesCopied = [int]$matches[1]
            $filesSkipped = [int]$matches[2]
        }
        if ($line -match 'Dirs\s*:\s*(\d+)\s+(\d+)\s+(\d+)') {
            $dirsTotal = [int]$matches[1]
            $dirsCopied = [int]$matches[2]
            $dirsSkipped = [int]$matches[3]
        }
        # 別の形式
        elseif ($line -match 'Dirs\s*:\s*(\d+)\s+(\d+)\s+(\d+)') {
            $dirsCopied = [int]$matches[1]
            $dirsSkipped = [int]$matches[2]
        }
        # バイト数（数値のみ、単位なし）
        if ($line -match 'Bytes\s*:\s*(\d+)') {
            $bytesCopied = [long]$matches[1]
        }
        # エラーメッセージ
        if ($line -match '(エラー|Error|ERROR)\s+(\d+)') {
            $errors += $line
        }
    }
}

# エラーログを読み込んで記録
if (Test-Path $errorLog) {
    $errorContent = Get-Content $errorLog -ErrorAction SilentlyContinue
    foreach ($err in $errorContent) {
        if ($err.Trim()) {
            Write-Log "Robocopy Error: $err" 'ERROR'
            $errors += $err
        }
    }
    Remove-Item $errorLog -Force -ErrorAction SilentlyContinue
}
# 標準出力ログも削除
if (Test-Path $outputLog) {
    Remove-Item $outputLog -Force -ErrorAction SilentlyContinue
}

Write-Log "Mirroring completed in $([math]::Round($mirrorDuration, 2)) seconds" 'INFO'
if ($filesTotal -gt 0) {
    Write-Log "  Files: Total=$filesTotal, Copied=$filesCopied, Skipped=$filesSkipped" 'INFO'
} else {
    Write-Log "  Files: Copied=$filesCopied, Skipped=$filesSkipped" 'INFO'
}
if ($dirsTotal -gt 0) {
    Write-Log "  Directories: Total=$dirsTotal, Copied=$dirsCopied, Skipped=$dirsSkipped" 'INFO'
} else {
    Write-Log "  Directories: Copied=$dirsCopied, Skipped=$dirsSkipped" 'INFO'
}
if ($bytesCopied -gt 0) {
    Write-Log "  Bytes: $([math]::Round($bytesCopied / 1MB, 2)) MB" 'INFO'
}
Write-Log "  Exit Code: $($result.ExitCode)" 'INFO'

if ($result.ExitCode -lt 8) {
    Write-Host "  OK (exit=$($result.ExitCode))" -ForegroundColor Green
} else {
    Write-Host "  WARNING: exit=$($result.ExitCode)" -ForegroundColor Yellow
    Write-Log "Warning: Robocopy exit code $($result.ExitCode)" 'WARN'
}

# [2] アーカイブ作成
if ($Config.SkipArchive) {
    Write-Host '[2/3] Creating archive... (SKIPPED)' -ForegroundColor Gray
    Write-Log '=== Step 2: Archive Creation Skipped ===' 'INFO'
    $archiveStartTime = Get-Date
    $archiveEndTime = Get-Date
    $archiveDuration = 0
    $archivePath = $null
    $archiveName = ''
    $tarErrors = @()
    Write-Log 'Archive creation skipped by user request' 'INFO'
} else {
    Write-Host '[2/3] Creating archive...' -ForegroundColor Cyan
    $archiveStartTime = Get-Date
    Write-Log '=== Step 2: Archive Creation Started ===' 'INFO'

    $archiveName = "${TargetName}_$Timestamp.tar.gz"
    $archivePath = Join-Path $ArchiveDest $archiveName
    $archivePathWsl = '/mnt/' + $archivePath.Substring(0, 1).ToLower() + ($archivePath.Substring(2) -replace '\\', '/')

    # tarのエラー出力をキャプチャ
    $tarErrorLog = Join-Path $LogDir "tar_errors_$Timestamp.log"
    $tarCmd = "tar -czf '$archivePathWsl' --ignore-failed-read -C '$ParentDir' '$TargetName' 2>$tarErrorLog"
    wsl -d $Config.WslDistro -e bash -c $tarCmd
    $archiveEndTime = Get-Date
    $archiveDuration = ($archiveEndTime - $archiveStartTime).TotalSeconds

    # tarエラーログを読み込んで記録
    $tarErrors = @()
    if (Test-Path $tarErrorLog) {
        $tarErrorContent = Get-Content $tarErrorLog -ErrorAction SilentlyContinue
        foreach ($err in $tarErrorContent) {
            if ($err.Trim() -and $err -notmatch '^$') {
                Write-Log "Tar Warning: $err" 'WARN'
                $tarErrors += $err
            }
        }
    }

    if (Test-Path $archivePath) {
        $size = (Get-Item $archivePath).Length / 1MB
        Write-Host "  OK: $archiveName ($('{0:N1}' -f $size) MB)" -ForegroundColor Green
        Write-Log "Archive created successfully: $archiveName" 'INFO'
        Write-Log "  Size: $([math]::Round($size, 2)) MB" 'INFO'
        Write-Log "  Duration: $([math]::Round($archiveDuration, 2)) seconds" 'INFO'
        if ($tarErrors.Count -gt 0) {
            Write-Log "  Warnings: $($tarErrors.Count) files skipped" 'WARN'
        }
    } else {
        Write-Host '  ERROR: Archive not created' -ForegroundColor Red
        Write-Log 'ERROR: Archive creation failed' 'ERROR'
    }
}

# [3] 古いアーカイブ削除
Write-Host '[3/3] Cleanup...' -ForegroundColor Cyan
$cleanupStartTime = Get-Date
Write-Log '=== Step 3: Cleanup Started ===' 'INFO'

if ($Config.KeepDays -gt 0) {
    $cutoff = (Get-Date).AddDays(-$Config.KeepDays)
    $old = Get-ChildItem $ArchiveDest -Filter '*.tar.gz' | Where-Object { $_.LastWriteTime -lt $cutoff }
    $count = ($old | Measure-Object).Count
    $deletedSize = ($old | Measure-Object -Property Length -Sum).Sum / 1MB
    
    if ($count -gt 0) {
        foreach ($file in $old) {
            Write-Log "Deleting old archive: $($file.Name)" 'INFO'
        }
        $old | Remove-Item -Force
        Write-Host "  Deleted $count old archive(s)" -ForegroundColor Green
        Write-Log "Deleted $count old archive(s), freed $([math]::Round($deletedSize, 2)) MB" 'INFO'
    } else {
        Write-Host '  No old archives to delete' -ForegroundColor Gray
        Write-Log 'No old archives to delete' 'INFO'
    }
} else {
    Write-Host '  Skipped (KeepDays=0)' -ForegroundColor Gray
    Write-Log 'Cleanup skipped (KeepDays=0)' 'INFO'
}
$cleanupEndTime = Get-Date
$cleanupDuration = ($cleanupEndTime - $cleanupStartTime).TotalSeconds
Write-Log "Cleanup completed in $([math]::Round($cleanupDuration, 2)) seconds" 'INFO'

# サマリー
$endTime = Get-Date
$totalDuration = ($endTime - $scriptStartTime).TotalSeconds
Write-Host 'Done.' -ForegroundColor Green

Write-Log '=== Backup Summary ===' 'INFO'
Write-Log "Start Time: $($scriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))" 'INFO'
Write-Log "End Time: $($endTime.ToString('yyyy-MM-dd HH:mm:ss'))" 'INFO'
Write-Log "Total Duration: $([math]::Round($totalDuration, 2)) seconds ($([math]::Round($totalDuration / 60, 2)) minutes)" 'INFO'
Write-Log '' 'INFO'
Write-Log 'Step 1 - Mirroring:' 'INFO'
Write-Log "  Duration: $([math]::Round($mirrorDuration, 2)) seconds" 'INFO'
if ($filesTotal -gt 0) {
    Write-Log "  Files: Total=$filesTotal, Copied=$filesCopied, Skipped=$filesSkipped" 'INFO'
} else {
    Write-Log "  Files: Copied=$filesCopied, Skipped=$filesSkipped" 'INFO'
}
if ($dirsTotal -gt 0) {
    Write-Log "  Directories: Total=$dirsTotal, Copied=$dirsCopied, Skipped=$dirsSkipped" 'INFO'
} else {
    Write-Log "  Directories: Copied=$dirsCopied, Skipped=$dirsSkipped" 'INFO'
}
if ($bytesCopied -gt 0) {
    Write-Log "  Data: $([math]::Round($bytesCopied / 1MB, 2)) MB" 'INFO'
}
Write-Log "  Exit Code: $($result.ExitCode)" 'INFO'
Write-Log '' 'INFO'
Write-Log 'Step 2 - Archive:' 'INFO'
if ($Config.SkipArchive) {
    Write-Log '  Status: SKIPPED' 'INFO'
    Write-Log '  Reason: User requested to skip archive creation' 'INFO'
} else {
    Write-Log "  Duration: $([math]::Round($archiveDuration, 2)) seconds" 'INFO'
    if ($archivePath -and (Test-Path $archivePath)) {
        $archiveSize = (Get-Item $archivePath).Length / 1MB
        Write-Log "  Archive: $archiveName" 'INFO'
        Write-Log "  Size: $([math]::Round($archiveSize, 2)) MB" 'INFO'
        if ($tarErrors.Count -gt 0) {
            Write-Log "  Warnings: $($tarErrors.Count) files skipped during archive creation" 'WARN'
        }
    } else {
        Write-Log '  Status: FAILED' 'ERROR'
    }
}
Write-Log '' 'INFO'
Write-Log 'Step 3 - Cleanup:' 'INFO'
Write-Log "  Duration: $([math]::Round($cleanupDuration, 2)) seconds" 'INFO'
if ($Config.KeepDays -gt 0) {
    Write-Log "  Old archives deleted: $count" 'INFO'
} else {
    Write-Log '  Cleanup: Disabled (KeepDays=0)' 'INFO'
}
Write-Log '' 'INFO'

# エラーサマリー
if ($errors.Count -gt 0 -or $tarErrors.Count -gt 0 -or $failedDeletions.Count -gt 0) {
    Write-Log '=== Error/Warning Summary ===' 'WARN'
    if ($failedDeletions.Count -gt 0) {
        Write-Log "  Failed deletions: $($failedDeletions.Count)" 'WARN'
    }
    if ($errors.Count -gt 0) {
        Write-Log "  Robocopy errors: $($errors.Count)" 'WARN'
    }
    if ($tarErrors.Count -gt 0) {
        Write-Log "  Tar warnings: $($tarErrors.Count)" 'WARN'
    }
}

Write-Log '=== WSL Backup Completed ===' 'INFO'
Write-Log "Log file: $mainLog" 'INFO'
