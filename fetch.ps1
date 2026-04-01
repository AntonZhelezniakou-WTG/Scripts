param(
	[string]$WorkDir
)

$ErrorActionPreference = "Stop"

if ($WorkDir) {
	Set-Location $WorkDir
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