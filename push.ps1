param(
	[string]$WorkDir
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common\common.ps1")

if ($WorkDir) { Set-Location $WorkDir }

$branch = git rev-parse --abbrev-ref HEAD 2>&1
if ($LASTEXITCODE -ne 0) {
	Write-Host "Not a git repository." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

if ($branch -eq "HEAD") {
	Write-Host "Detached HEAD state - no branch to push." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

# Detect remote tracking branch
$ErrorActionPreference = "Continue"
$remote = git config --get "branch.$branch.remote" 2>$null
$ErrorActionPreference = "Stop"

if (-not $remote) {
	$remote = "origin"
	Write-Host ""
	Write-Host "Branch '$branch' has no upstream." -ForegroundColor Yellow
	$remoteBranch = Read-Host "Remote branch name [$branch]"
	if ([string]::IsNullOrWhiteSpace($remoteBranch)) { $remoteBranch = $branch }

	if (-not (Confirm-Action "Push to $remote/$remoteBranch and set upstream?")) {
		Write-Host "Cancelled." -ForegroundColor DarkGray
		exit 0
	}

	Write-Host ""
	Write-Host "Pushing to $remote/$remoteBranch..." -ForegroundColor Cyan
	$ErrorActionPreference = "Continue"
	git push -u $remote "${branch}:${remoteBranch}"
	$pushExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($pushExit -ne 0) {
		Write-Host "Push failed." -ForegroundColor Red
		Wait-AnyKey
		exit 1
	}
	Write-Host "Pushed." -ForegroundColor Green
	Ensure-FetchRefspec $branch
	exit 0
}

# Ensure the fetch refspec exists so git updates refs/remotes/origin/<branch>
Ensure-FetchRefspec $branch

# Check whether the branch already exists on the remote
$ErrorActionPreference = "Continue"
$remoteRef = git ls-remote --heads $remote $branch 2>$null
$ErrorActionPreference = "Stop"
$existsOnRemote = [bool]$remoteRef

if ($existsOnRemote) {
	# Fetch to check if remote is ahead
	Write-Host "Fetching $remote/$branch..." -ForegroundColor Cyan
	$ErrorActionPreference = "Continue"
	git fetch $remote $branch
	$fetchExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($fetchExit -ne 0) {
		Write-Host "Fetch failed." -ForegroundColor Red
		Wait-AnyKey
		exit 1
	}

	# Check if remote is ahead of local
	$ErrorActionPreference = "Continue"
	$behind = git rev-list --count "HEAD..$remote/$branch" 2>&1
	$behindExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($behindExit -ne 0) {
		Write-Host "Failed to compare with remote." -ForegroundColor Red
		Wait-AnyKey
		exit 1
	}

	if ([int]$behind -gt 0) {
		Write-Host ""
		Write-Host "[warn] Remote is $behind commit(s) ahead." -ForegroundColor Yellow
		if (Confirm-Action "Pull first?") {
			$pullScript = Join-Path $PSScriptRoot "pull.ps1"
			& $pullScript
			if ($LASTEXITCODE -ne 0) {
				Write-Host "Pull failed, aborting push." -ForegroundColor Red
				Wait-AnyKey
				exit 1
			}
		}
	}
} else {
	Write-Host "Branch '$branch' does not exist on $remote yet — first push." -ForegroundColor Cyan
}

# Pre-push review (or first-push confirmation)
Write-Host ""
if ($existsOnRemote) {
	$proceed = Invoke-PushReview -Remote $remote -Branch $branch
} else {
	$proceed = Confirm-Action "Push '$branch' to $remote (create remote branch)?"
}
if (-not $proceed) {
	Write-Host "Push cancelled." -ForegroundColor Yellow
	exit 0
}

# Push
Write-Host ""
Write-Host "Pushing to $remote/$branch..." -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
git push $remote $branch
$pushExit = $LASTEXITCODE
$ErrorActionPreference = "Stop"
if ($pushExit -ne 0) {
	Write-Host "Push failed." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

Invoke-PrCreate