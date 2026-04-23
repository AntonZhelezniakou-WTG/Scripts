param(
	[string]$WorkDir
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot "Common\common.ps1")

if ($WorkDir) {
	Set-Location $WorkDir
}

$ErrorActionPreference = "Continue"
$null = git rev-parse --is-inside-work-tree 2>$null
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -ne 0) {
	Write-Host "Error: not a git repository." -ForegroundColor Red
	exit 1
}

# Detect the repo's main branch (master / main / anything else origin/HEAD points to)
$ErrorActionPreference = "Continue"
$headRef = git symbolic-ref refs/remotes/origin/HEAD 2>$null
$ErrorActionPreference = "Stop"

$mainBranch = $null
if ($headRef -and "$headRef" -match 'refs/remotes/origin/(.+)') {
	$mainBranch = $Matches[1].Trim()
} else {
	foreach ($candidate in @('master', 'main')) {
		$ErrorActionPreference = "Continue"
		$null = git rev-parse --verify $candidate 2>$null
		$ErrorActionPreference = "Stop"
		if ($LASTEXITCODE -eq 0) { $mainBranch = $candidate; break }
	}
}
if (-not $mainBranch) {
	Write-Host "Error: could not determine main branch." -ForegroundColor Red
	exit 1
}

Write-Host "== Switch to $mainBranch =="
$ErrorActionPreference = "Continue"
git checkout $mainBranch 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -ne 0) {
	Write-Host "Error: failed to switch to $mainBranch. Is another process locking .git?" -ForegroundColor Red
	exit 1
}

# Collect all local branches
$localBranches = git branch --format="%(refname:short)" | Where-Object { $_ -ne '' }

Write-Host "== Delete remote-tracking refs (except those with a local branch) =="

# Iterate using full refname to avoid ambiguity with nested paths like origin/origin/...
git for-each-ref refs/remotes/origin --format="%(refname)" |
Where-Object { $_ -ne "refs/remotes/origin/$mainBranch" -and $_ -ne "refs/remotes/origin/HEAD" } |
ForEach-Object {
	$fullRef   = $_
	$shortName = $fullRef -replace "^refs/remotes/origin/", ""
	if ($localBranches -notcontains $shortName) {
		$ErrorActionPreference = "Continue"
		git update-ref -d $fullRef 2>&1 | Out-Null
		$ErrorActionPreference = "Stop"
		if ($LASTEXITCODE -eq 0) {
			Write-Host "  Deleted: $fullRef" -ForegroundColor DarkGray
		} else {
			Write-Host "  Failed to delete: $fullRef (locked?)" -ForegroundColor Yellow
		}
	}
}

Write-Host "== Rebuild fetch refspecs in .git/config =="

$gitCommonDir = git rev-parse --git-common-dir
$configFile   = "$gitCommonDir/config"

# Remove all existing fetch refspecs for origin
$ErrorActionPreference = "Continue"
git config --file $configFile --unset-all remote.origin.fetch 2>$null
$ErrorActionPreference = "Stop"

# Add refspec for main branch
git config --file $configFile --add remote.origin.fetch "+refs/heads/${mainBranch}:refs/remotes/origin/${mainBranch}"

# Add refspec for each local branch except the main branch
foreach ($branch in $localBranches) {
	if ($branch -eq $mainBranch) { continue }
	git config --file $configFile --add remote.origin.fetch "+refs/heads/${branch}:refs/remotes/origin/${branch}"
	Write-Host "  Added refspec: $branch" -ForegroundColor DarkGray
}

Write-Host "== Prune + GC =="
$ErrorActionPreference = "Continue"
git gc --prune=now --quiet 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -ne 0) {
	Write-Host "Warning: gc finished with errors (locked files?)" -ForegroundColor Yellow
}

Apply-GitUser ((git rev-parse --show-toplevel).Trim() -replace '/', '\')

Write-Host "Done"
exit 0