param(
	[string]$WorkDir
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common\common.ps1")

if ($WorkDir) {
	Set-Location $WorkDir
}

# ── jj backend ───────────────────────────────────────────────────────────────
# Mirror the git mode below: fetch only the branches we work on (local
# bookmarks), never the whole remote — a huge repo has thousands of branches.
if ((Get-VcsBackend) -eq 'jj') {
	$root = Get-JjRoot
	if ($root) { Set-Location $root }

	$bookmarks = @(Get-JjBookmarks)
	if ($bookmarks.Count -eq 0) {
		Write-Host "No local bookmarks to fetch." -ForegroundColor Yellow
		exit 0
	}

	Write-Host "== Fetching local bookmarks from origin ==" -ForegroundColor DarkGray
	$bookmarks | ForEach-Object { Write-Host "  fetch $_" }
	$branchArgs = @($bookmarks | ForEach-Object { '--branch'; $_ })
	$ErrorActionPreference = "Continue"
	jj git fetch @branchArgs
	$exit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($exit -ne 0) {
		Write-Host "Fetch failed." -ForegroundColor Red
		exit 1
	}
	Write-Host "Done"
	exit 0
}

# Verify we're inside a git repository
$prev = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$null = git rev-parse --is-inside-work-tree 2>&1
$gitExit = $LASTEXITCODE
$ErrorActionPreference = $prev
if ($gitExit -ne 0) {
	Write-Host "Error: not a git repository." -ForegroundColor Red
	exit 1
}

# List remote branches (no stderr suppression — allows GCM auth prompt)
$ErrorActionPreference = "Continue"
$remoteBranches = git ls-remote --heads origin | ForEach-Object {
	$_ -replace '^.*refs/heads/',''
}
$lsExit = $LASTEXITCODE
$ErrorActionPreference = "Stop"
if ($lsExit -ne 0) {
	Write-Host "Failed to query remote branches." -ForegroundColor Red
	exit 1
}

$localBranches = git branch |
	ForEach-Object { $_.Trim() -replace '^[*+] ','' } |
	Where-Object { $_ -ne '' }

$toFetch = $localBranches |
	Where-Object { $remoteBranches -contains $_ } |
	Sort-Object -Unique

if (-not $toFetch) {
	Write-Host "No matching branches found on origin."
	exit 0
}

Write-Host "== Fetching local branches from origin =="
foreach ($branch in $toFetch) {
	Write-Host "  fetch $branch"
	$ErrorActionPreference = "Continue"
	git fetch origin $branch
	$ErrorActionPreference = "Stop"
}

Write-Host "Done"
exit 0