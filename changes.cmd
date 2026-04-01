<# :
@echo off & setlocal EnableExtensions

git rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 (
    echo Error: not a git repository.
    pause
    exit /b 1
)

set "PS1_TEMP=%TEMP%\git-find-sln-%RANDOM%.ps1"
copy /y "%~f0" "%PS1_TEMP%" >nul

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1_TEMP%" "%CD%"
set "EXIT_CODE=%ERRORLEVEL%"

del /q "%PS1_TEMP%" 2>nul
exit /b %EXIT_CODE%
#>

param(
    [string]$WorkDir
)

$ErrorActionPreference = "Stop"

if ($WorkDir) { Set-Location $WorkDir }

# Validate git repository
git rev-parse --is-inside-work-tree 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: not a git repository." -ForegroundColor Red
    exit 1
}

$repoRoot = (git rev-parse --show-toplevel) -replace '/','\'

# Get all files changed between master and HEAD, plus locally modified/added/deleted
$diffFiles = git diff --name-only master...HEAD
$statusFiles = git status --porcelain |
    Where-Object { $_ -notmatch '^\s*!!' } |
    ForEach-Object {
        $path = $_.Substring(3).Trim()
        if ($path -match ' -> ') { $path = $path -split ' -> ' | Select-Object -Last 1 }
        $path
    }

$changedFiles = @($diffFiles) + @($statusFiles) |
    Where-Object { $_ -ne '' } |
    Sort-Object -Unique |
    ForEach-Object { Join-Path $repoRoot ($_ -replace '/','\') }

if (-not $changedFiles) {
    Write-Host "No changed files found." -ForegroundColor Yellow
    exit 0
}

# For each changed file find the nearest .sln walking up to repo root
function Find-Sln {
    param([string]$FilePath)

    $dir = Split-Path $FilePath -Parent
    while ($true) {
        $slns = Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.sln','.slnx' }
        if ($slns) { return $slns[0].FullName }

        # Stop if we've reached the repo root
        if ($dir -ieq $repoRoot) { break }

        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -ieq $dir) { break }
        $dir = $parent
    }
    return $null
}

$seen = @{}

$changedFiles | ForEach-Object {
    $sln = Find-Sln $_
    if ($sln -and -not $seen.ContainsKey($sln)) {
        $seen[$sln] = $true
        Write-Host $sln.Substring($repoRoot.Length).TrimStart('\')
    }
}

if ($seen.Count -eq 0) {
    Write-Host "No .sln/.slnx files found for changed files." -ForegroundColor Yellow
}