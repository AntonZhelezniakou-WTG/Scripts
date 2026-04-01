param(
	[string]$WorkDir
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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

Write-Host "== Switch to master =="
$ErrorActionPreference = "Continue"
git checkout master 2>&1 | Out-Null
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -ne 0) {
	Write-Host "Error: failed to switch to master. Is another process locking .git?" -ForegroundColor Red
	exit 1
}

# Collect all local branches
$localBranches = git branch --format="%(refname:short)" | Where-Object { $_ -ne '' }

Write-Host "== Delete remote-tracking refs (except those with a local branch) =="

# Iterate using full refname to avoid ambiguity with nested paths like origin/origin/...
git for-each-ref refs/remotes/origin --format="%(refname)" |
Where-Object { $_ -ne "refs/remotes/origin/master" -and $_ -ne "refs/remotes/origin/HEAD" } |
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

# Add refspec for master
git config --file $configFile --add remote.origin.fetch "+refs/heads/master:refs/remotes/origin/master"

# Add refspec for each local branch except master
foreach ($branch in $localBranches) {
	if ($branch -eq 'master') { continue }
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

Write-Host "Done"
exit 0