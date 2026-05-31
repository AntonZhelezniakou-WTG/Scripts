<# :
@echo off & setlocal EnableExtensions

git rev-parse --is-inside-work-tree >nul 2>&1 || jj root >nul 2>&1
if errorlevel 1 (
    echo Error: not a repository.
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

# Detect backend (jj takes priority in colocated repos). Self-contained: this
# script is copied to TEMP and run, so it can't dot-source Common\Vcs.ps1.
$jjRoot = $null
$probe  = (Get-Location).Path
while ($probe) {
    if (Test-Path (Join-Path $probe ".jj")) { $jjRoot = $probe; break }
    $parent = Split-Path $probe -Parent
    if ($parent -eq $probe) { break }
    $probe = $parent
}

if ($jjRoot) {
    $repoRoot = $jjRoot
    $base = $null
    foreach ($b in @('main@origin', 'master@origin', 'main', 'master')) {
        jj log --no-graph -r $b -T '"x"' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $base = $b; break }
    }
    $changedRel = if ($base) { @(jj diff --summary --from $base --to '@' 2>$null) }
                  else       { @(jj diff --summary -r '@' 2>$null) }
    $changedFiles = @($changedRel | ForEach-Object {
            if ($_ -match '^[MADCR]\s+(.+)$') {
                $p = $Matches[1].Trim()
                # Expand rename/copy notation "pre{old => new}post" to the new path.
                if ($p -match '^(.*)\{(.*?) => (.*?)\}(.*)$') { $Matches[1] + $Matches[3] + $Matches[4] } else { $p }
            }
        }) |
        Where-Object { $_ -ne '' } |
        Sort-Object -Unique |
        ForEach-Object { Join-Path $repoRoot ($_ -replace '/','\') }
} else {
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
}

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