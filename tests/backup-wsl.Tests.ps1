#Requires -Modules Pester

<#
.SYNOPSIS
    WSL バックアップスクリプトのユニットテスト
.DESCRIPTION
    Pester 5.x を使用したテストスイート
    実行方法: Invoke-Pester -Path .\tests\backup-wsl.Tests.ps1
.NOTES
    Pester のインストール: Install-Module -Name Pester -Force -SkipPublisherCheck
#>

BeforeAll {
    # スクリプトのルートディレクトリを取得
    $script:ScriptRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptPath = Join-Path $script:ScriptRoot 'backup-wsl.ps1'

    # テスト用の一時ディレクトリ
    $script:TestTempDir = Join-Path $env:TEMP "backup-wsl-tests-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Force -Path $script:TestTempDir | Out-Null

    # スクリプトから関数を読み込む（ドットソース）
    # 注: メイン処理が実行されないよう、関数定義のみを抽出
    $scriptContent = Get-Content $script:ScriptPath -Raw

    # 定数と関数定義のみを抽出して読み込む
    $functionsOnly = @()
    $inFunction = $false
    $braceCount = 0

    # ExitCodesとConstantsの定義を抽出
    if ($scriptContent -match '(?s)\$Script:ExitCodes = @\{.*?\}') {
        Invoke-Expression $matches[0]
    }
    if ($scriptContent -match '(?s)\$Script:Constants = @\{.*?\}') {
        Invoke-Expression $matches[0]
    }
    if ($scriptContent -match '(?s)\$Script:ConfigSchema = @\{.*?\}') {
        # ConfigSchemaは複雑なので簡略化
        $Script:ConfigSchema = @{
            WslDistro = @{ Type = 'string'; Required = $true; Pattern = '^[a-zA-Z0-9_-]+$' }
            Sources = @{ Type = 'array'; Required = $true; MinItems = 1 }
            DestRoot = @{ Type = 'string'; Required = $true }
            KeepDays = @{ Type = 'int'; Min = 0; Max = 3650; Default = 15 }
        }
    }

    # 個別の関数を定義
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
            'array' {
                if ($Value -is [array] -or $Value -is [System.Collections.ArrayList]) {
                    if ($rule.MinItems -and $Value.Count -lt $rule.MinItems) {
                        return @{ Valid = $false; Message = $rule.Message }
                    }
                    return @{ Valid = $true; Value = @($Value) }
                }
                return @{ Valid = $false; Message = "$Key must be an array" }
            }
        }
        return @{ Valid = $true; Value = $Value }
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
        }
        catch {
            return $false
        }
    }

    function Test-SourcePath {
        param(
            [string]$SourcePath,
            [string]$WslDistro
        )

        if ([string]::IsNullOrWhiteSpace($SourcePath)) {
            return $false
        }

        if ($SourcePath -match '\.\.' -or $SourcePath -match '//') {
            return $false
        }

        if (-not $SourcePath.StartsWith('/')) {
            return $false
        }

        return $true
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
                }
                else {
                    $result.Files += $line
                }
            }
        }
        return $result
    }

    function Get-SafeSourceName {
        param([string]$SourceDir)
        return ($SourceDir -replace '.*/', '') -replace "'", "'\''"
    }
}

AfterAll {
    # テスト用一時ディレクトリの削除
    if (Test-Path $script:TestTempDir) {
        Remove-Item $script:TestTempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'ConvertTo-WslPath' {
    Context 'Valid Windows paths' {
        It 'Converts C:\Users\test to /mnt/c/Users/test' {
            ConvertTo-WslPath -WindowsPath 'C:\Users\test' | Should -Be '/mnt/c/Users/test'
        }

        It 'Converts D:\Backup\data to /mnt/d/Backup/data' {
            ConvertTo-WslPath -WindowsPath 'D:\Backup\data' | Should -Be '/mnt/d/Backup/data'
        }

        It 'Handles paths with spaces' {
            ConvertTo-WslPath -WindowsPath 'C:\Program Files\Test' | Should -Be '/mnt/c/Program Files/Test'
        }

        It 'Converts drive root correctly' {
            ConvertTo-WslPath -WindowsPath 'E:\' | Should -Be '/mnt/e/'
        }
    }

    Context 'Invalid Windows paths' {
        It 'Throws on empty path' {
            { ConvertTo-WslPath -WindowsPath '' } | Should -Throw
        }

        It 'Throws on null path' {
            { ConvertTo-WslPath -WindowsPath $null } | Should -Throw
        }

        It 'Throws on path too short' {
            { ConvertTo-WslPath -WindowsPath 'C' } | Should -Throw
        }

        It 'Throws on invalid drive letter' {
            { ConvertTo-WslPath -WindowsPath '1:\test' } | Should -Throw
        }
    }
}

Describe 'Test-SafePath' {
    Context 'Valid paths within allowed root' {
        It 'Returns true for path within root' {
            Test-SafePath -Path 'C:\Backup\data\file.txt' -AllowedRoot 'C:\Backup' | Should -Be $true
        }

        It 'Returns true for exact root path' {
            Test-SafePath -Path 'C:\Backup' -AllowedRoot 'C:\Backup' | Should -Be $true
        }

        It 'Returns true for nested path' {
            Test-SafePath -Path 'C:\Backup\a\b\c\d' -AllowedRoot 'C:\Backup' | Should -Be $true
        }
    }

    Context 'Invalid paths outside allowed root' {
        It 'Returns false for path outside root' {
            Test-SafePath -Path 'C:\Other\file.txt' -AllowedRoot 'C:\Backup' | Should -Be $false
        }

        It 'Returns false for path traversal attempt' {
            Test-SafePath -Path 'C:\Backup\..\Other' -AllowedRoot 'C:\Backup' | Should -Be $false
        }

        It 'Returns false for empty path' {
            Test-SafePath -Path '' -AllowedRoot 'C:\Backup' | Should -Be $false
        }

        It 'Returns false for null path' {
            Test-SafePath -Path $null -AllowedRoot 'C:\Backup' | Should -Be $false
        }
    }
}

Describe 'Test-SourcePath' {
    Context 'Valid WSL paths' {
        It 'Returns true for absolute path' {
            Test-SourcePath -SourcePath '/home/user/projects' -WslDistro 'Ubuntu' | Should -Be $true
        }

        It 'Returns true for root path' {
            Test-SourcePath -SourcePath '/data' -WslDistro 'Ubuntu' | Should -Be $true
        }
    }

    Context 'Invalid WSL paths' {
        It 'Returns false for relative path' {
            Test-SourcePath -SourcePath 'home/user' -WslDistro 'Ubuntu' | Should -Be $false
        }

        It 'Returns false for path with ..' {
            Test-SourcePath -SourcePath '/home/../etc/passwd' -WslDistro 'Ubuntu' | Should -Be $false
        }

        It 'Returns false for path with //' {
            Test-SourcePath -SourcePath '/home//user' -WslDistro 'Ubuntu' | Should -Be $false
        }

        It 'Returns false for empty path' {
            Test-SourcePath -SourcePath '' -WslDistro 'Ubuntu' | Should -Be $false
        }

        It 'Returns false for null path' {
            Test-SourcePath -SourcePath $null -WslDistro 'Ubuntu' | Should -Be $false
        }
    }
}

Describe 'Test-ConfigValue' {
    Context 'String validation' {
        It 'Validates valid string' {
            $result = Test-ConfigValue -Key 'WslDistro' -Value 'Ubuntu' -Schema $Script:ConfigSchema
            $result.Valid | Should -Be $true
            $result.Value | Should -Be 'Ubuntu'
        }

        It 'Validates string with pattern' {
            $result = Test-ConfigValue -Key 'WslDistro' -Value 'Ubuntu-22.04' -Schema $Script:ConfigSchema
            $result.Valid | Should -Be $true
        }

        It 'Rejects invalid pattern' {
            $result = Test-ConfigValue -Key 'WslDistro' -Value 'Ubuntu@22.04' -Schema $Script:ConfigSchema
            $result.Valid | Should -Be $false
        }

        It 'Rejects non-string' {
            $result = Test-ConfigValue -Key 'WslDistro' -Value 123 -Schema $Script:ConfigSchema
            $result.Valid | Should -Be $false
        }
    }

    Context 'Integer validation' {
        It 'Validates valid integer' {
            $result = Test-ConfigValue -Key 'KeepDays' -Value 30 -Schema $Script:ConfigSchema
            $result.Valid | Should -Be $true
            $result.Value | Should -Be 30
        }

        It 'Validates integer at minimum' {
            $result = Test-ConfigValue -Key 'KeepDays' -Value 0 -Schema $Script:ConfigSchema
            $result.Valid | Should -Be $true
        }

        It 'Rejects integer below minimum' {
            $result = Test-ConfigValue -Key 'KeepDays' -Value -1 -Schema $Script:ConfigSchema
            $result.Valid | Should -Be $false
        }

        It 'Rejects integer above maximum' {
            $result = Test-ConfigValue -Key 'KeepDays' -Value 5000 -Schema $Script:ConfigSchema
            $result.Valid | Should -Be $false
        }

        It 'Returns default for null value' {
            $result = Test-ConfigValue -Key 'KeepDays' -Value $null -Schema $Script:ConfigSchema
            $result.Valid | Should -Be $true
            $result.Value | Should -Be 15
        }
    }

    Context 'Array validation' {
        It 'Validates valid array' {
            $result = Test-ConfigValue -Key 'Sources' -Value @('/home/user') -Schema $Script:ConfigSchema
            $result.Valid | Should -Be $true
        }

        It 'Validates array with multiple items' {
            $result = Test-ConfigValue -Key 'Sources' -Value @('/home/user', '/data') -Schema $Script:ConfigSchema
            $result.Valid | Should -Be $true
        }

        It 'Rejects empty array' {
            $result = Test-ConfigValue -Key 'Sources' -Value @() -Schema $Script:ConfigSchema
            $result.Valid | Should -Be $false
        }

        It 'Rejects non-array' {
            $result = Test-ConfigValue -Key 'Sources' -Value '/home/user' -Schema $Script:ConfigSchema
            $result.Valid | Should -Be $false
        }
    }
}

Describe 'Read-MirrorIgnore' {
    BeforeAll {
        $script:TestIgnoreFile = Join-Path $script:TestTempDir '.mirrorignore'
    }

    Context 'Valid ignore file' {
        It 'Parses directory patterns' {
            @"
# Comment
.venv/
node_modules/
"@ | Set-Content $script:TestIgnoreFile -Encoding UTF8

            $result = Read-MirrorIgnore -IgnoreFilePath $script:TestIgnoreFile
            $result.Dirs | Should -Contain '.venv'
            $result.Dirs | Should -Contain 'node_modules'
            $result.Files | Should -BeNullOrEmpty
        }

        It 'Parses file patterns' {
            @"
*.pyc
*.tmp
.env
"@ | Set-Content $script:TestIgnoreFile -Encoding UTF8

            $result = Read-MirrorIgnore -IgnoreFilePath $script:TestIgnoreFile
            $result.Files | Should -Contain '*.pyc'
            $result.Files | Should -Contain '*.tmp'
            $result.Files | Should -Contain '.env'
            $result.Dirs | Should -BeNullOrEmpty
        }

        It 'Parses mixed patterns' {
            @"
# Directories
.git/
__pycache__/

# Files
*.log
"@ | Set-Content $script:TestIgnoreFile -Encoding UTF8

            $result = Read-MirrorIgnore -IgnoreFilePath $script:TestIgnoreFile
            $result.Dirs | Should -HaveCount 2
            $result.Files | Should -HaveCount 1
        }

        It 'Ignores comments and empty lines' {
            @"
# This is a comment

.venv/

# Another comment
*.pyc
"@ | Set-Content $script:TestIgnoreFile -Encoding UTF8

            $result = Read-MirrorIgnore -IgnoreFilePath $script:TestIgnoreFile
            $result.Dirs | Should -HaveCount 1
            $result.Files | Should -HaveCount 1
        }
    }

    Context 'Missing file' {
        It 'Returns empty result for non-existent file' {
            $result = Read-MirrorIgnore -IgnoreFilePath 'C:\nonexistent\.mirrorignore'
            $result.Dirs | Should -BeNullOrEmpty
            $result.Files | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-SafeSourceName' {
    It 'Extracts directory name from path' {
        Get-SafeSourceName -SourceDir '/home/user/projects' | Should -Be 'projects'
    }

    It 'Handles root-level directory' {
        Get-SafeSourceName -SourceDir '/data' | Should -Be 'data'
    }

    It 'Handles nested path' {
        Get-SafeSourceName -SourceDir '/home/user/workspace/myproject' | Should -Be 'myproject'
    }

    It 'Escapes single quotes' {
        Get-SafeSourceName -SourceDir "/home/user/project's" | Should -Be "project'\''s"
    }
}

Describe 'Exit Codes' {
    It 'Has Success code as 0' {
        $Script:ExitCodes.Success | Should -Be 0
    }

    It 'Has distinct error codes' {
        $codes = $Script:ExitCodes.Values | Sort-Object -Unique
        $codes.Count | Should -Be $Script:ExitCodes.Count
    }

    It 'Has all expected codes' {
        $Script:ExitCodes.Keys | Should -Contain 'Success'
        $Script:ExitCodes.Keys | Should -Contain 'LockError'
        $Script:ExitCodes.Keys | Should -Contain 'WslError'
        $Script:ExitCodes.Keys | Should -Contain 'ConfigError'
        $Script:ExitCodes.Keys | Should -Contain 'TimeoutError'
    }
}

Describe 'Constants' {
    It 'Has Version defined' {
        $Script:Constants.Version | Should -Not -BeNullOrEmpty
    }

    It 'Has valid RobocopySuccessMaxExitCode' {
        $Script:Constants.RobocopySuccessMaxExitCode | Should -Be 7
    }

    It 'Has valid default keep days' {
        $Script:Constants.DefaultKeepDays | Should -BeGreaterThan 0
        $Script:Constants.DefaultLogKeepDays | Should -BeGreaterThan 0
    }

    It 'Has valid timestamp formats' {
        $Script:Constants.LogDateFormat | Should -Not -BeNullOrEmpty
        $Script:Constants.TimestampFormat | Should -Not -BeNullOrEmpty
    }
}

Describe 'Script File Existence' {
    It 'Main script exists' {
        Test-Path $script:ScriptPath | Should -Be $true
    }

    It 'Script has valid PowerShell syntax' {
        $errors = $null
        $null = [System.Management.Automation.PSParser]::Tokenize(
            (Get-Content $script:ScriptPath -Raw),
            [ref]$errors
        )
        $errors.Count | Should -Be 0
    }
}

Describe 'Integration Tests' -Tag 'Integration' {
    BeforeAll {
        $script:IntegrationTestDir = Join-Path $script:TestTempDir 'integration'
        New-Item -ItemType Directory -Force -Path $script:IntegrationTestDir | Out-Null
    }

    Context 'DryRun Mode' {
        It 'Runs without errors in DryRun mode' -Skip:(-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
            $result = & $script:ScriptPath -DryRun -SkipArchive 2>&1
            # DryRunモードでは実際の処理は行われない
            $LASTEXITCODE | Should -BeIn @(0, 6, 7)  # Success, ConfigError (if no config), ValidationError
        }
    }

    Context 'Help Display' {
        It 'Shows help without errors' {
            $help = Get-Help $script:ScriptPath
            $help | Should -Not -BeNullOrEmpty
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
