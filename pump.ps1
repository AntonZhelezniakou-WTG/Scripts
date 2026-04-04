param(
	[string]$WorkDir,
	[switch]$Force
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

if ($WorkDir) { Set-Location $WorkDir }

git rev-parse --is-inside-work-tree 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
	Write-Host "Error: not a git repository." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

$currentBranch = git symbolic-ref --short HEAD 2>$null
if (-not $currentBranch) {
	Write-Host "Error: cannot determine current branch (detached HEAD?)." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

if ($currentBranch -eq "master" -or $currentBranch -eq "main") {
	Write-Host "Already on '$currentBranch'. Nothing to merge." -ForegroundColor Yellow
	Wait-AnyKey
	exit 0
}

$localBranches = git branch | ForEach-Object { $_.Trim() -replace "^[*+] ", "" } | Where-Object { $_ -ne "" }
$baseBranch    = $localBranches | Where-Object { $_ -eq "master" -or $_ -eq "main" } | Select-Object -First 1

if (-not $baseBranch) {
	Write-Host "Error: neither 'master' nor 'main' found locally." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

if (-not $Force) {
	if (-not (Confirm-Action "Merge '$baseBranch' into '$currentBranch'?")) {
		Write-Host "Cancelled." -ForegroundColor Yellow
		exit 0
	}
}

Write-Host ""
Write-Host "== Merging '$baseBranch' into '$currentBranch' ==" -ForegroundColor Cyan

$ErrorActionPreference = "Continue"
git merge $baseBranch --no-edit --quiet --no-stat
$mergeExit = $LASTEXITCODE
$ErrorActionPreference = "Stop"

if ($mergeExit -eq 0) {
	Write-Host "Merge completed successfully." -ForegroundColor Green
	exit 0
}

$conflictsScript = Join-Path $PSScriptRoot "conflicts.ps1"
$conflictFiles = (git diff --name-only --diff-filter=U 2>$null) -join ", "
& $conflictsScript -AbortCommand "merge --abort" -CommitMessage "Merged $baseBranch. Conflicts resolved in: $conflictFiles"
exit $LASTEXITCODE