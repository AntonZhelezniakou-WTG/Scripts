param(
	[string]$WorkDir,
	[string]$Target
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

# Returns $true if something was actually stashed
function Invoke-Stash([string]$RepoPath, [string]$Label) {
	$before = (git -C $RepoPath stash list 2>$null | Measure-Object).Count
	$ErrorActionPreference = "Continue"
	git -C $RepoPath stash push -m $Label 2>$null
	$exit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($exit -ne 0) {
		Write-Host "Stash failed." -ForegroundColor Red
		Wait-AnyKey
		exit 1
	}
	$after = (git -C $RepoPath stash list 2>$null | Measure-Object).Count
	return ($after -gt $before)
}

function Invoke-StashPop([string]$RepoPath) {
	Write-Host "Restoring stashed changes..." -ForegroundColor Cyan

	$stashRef = git -C $RepoPath stash list --max-count=1 --format="%gd" 2>$null

	$ErrorActionPreference = "Continue"
	git -C $RepoPath stash pop
	$exit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"

	if ($exit -ne 0) {
		$conflictsScript = Join-Path $PSScriptRoot "conflicts.ps1"
		Push-Location $RepoPath
		& $conflictsScript -Mode stash -StashRef $stashRef
		Pop-Location
	}
}

# Pulls $BranchName in $RepoPath; pass -NoFetch if fetch was done earlier
function Invoke-Pull([string]$RepoPath, [string]$BranchName, [switch]$NoFetch) {
	$remote = git -C $RepoPath config --get "branch.$BranchName.remote" 2>$null
	if (-not $remote) {
		Write-Host "No remote configured for '$BranchName', skipping pull." -ForegroundColor Yellow
		return 0
	}

	if (-not $NoFetch) {
		Write-Host "Fetching $remote/$BranchName..." -ForegroundColor Cyan
		$ErrorActionPreference = "Continue"
		git -C $RepoPath fetch $remote $BranchName
		$fetchExit = $LASTEXITCODE
		$ErrorActionPreference = "Stop"
		if ($fetchExit -ne 0) {
			Write-Host "Fetch failed." -ForegroundColor Red
			Wait-AnyKey
			exit 1
		}
	}

	$behind = git -C $RepoPath rev-list --count "${BranchName}..$remote/$BranchName" 2>$null
	if ($behind -eq "0") { return 0 }

	Write-Host "Pulling $remote/$BranchName..." -ForegroundColor Cyan
	$ErrorActionPreference = "Continue"
	git -C $RepoPath merge --ff-only "$remote/$BranchName"
	$pullExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	return $pullExit
}

function Get-BranchBehind([string]$RepoPath, [string]$BranchName) {
	$r = git -C $RepoPath config --get "branch.$BranchName.remote" 2>$null
	if (-not $r) { return 0 }
	$tracked = git -C $RepoPath rev-parse --verify "$r/$BranchName" 2>$null
	if (-not $tracked) { return 0 }
	$count = git -C $RepoPath rev-list --count "${BranchName}..${r}/${BranchName}" 2>$null
	return [int]$count
}

function Invoke-PullCurrentIfBehind([string]$RepoPath, [string]$BranchName) {
	$behind = Get-BranchBehind $RepoPath $BranchName
	if ($behind -eq 0) { return }
	Write-Host ""
	if (Confirm-Action "'$BranchName' is $behind commit(s) behind its remote. Pull now?") {
		$r = git -C $RepoPath config --get "branch.$BranchName.remote" 2>$null
		Write-Host "Fetching $r/${BranchName}..." -ForegroundColor Cyan
		git -C $RepoPath fetch $r $BranchName
		Write-Host "Pulling $r/${BranchName}..." -ForegroundColor Cyan
		$ErrorActionPreference = "Continue"
		git -C $RepoPath merge --ff-only "$r/$BranchName"
		$ErrorActionPreference = "Stop"
	}
}

# ── Setup ────────────────────────────────────────────────────────────────────

if ($WorkDir) { Set-Location $WorkDir }

$branch = git rev-parse --abbrev-ref HEAD 2>&1
if ($LASTEXITCODE -ne 0) {
	Write-Host "Not a git repository." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

if ($branch -eq "HEAD") {
	Write-Host "Detached HEAD state - no branch to pull." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

$here = (Get-Location).Path

# ── pull main/master mode ────────────────────────────────────────────────────

$isMainTarget = $Target -eq "master" -or $Target -eq "main"

if ($isMainTarget) {
	$localBranches = git branch | ForEach-Object { $_.Trim() -replace "^[*+] ", "" }
	$baseBranch    = $localBranches | Where-Object { $_ -eq $Target } | Select-Object -First 1
	if (-not $baseBranch) {
		Write-Host "Branch '$Target' not found locally." -ForegroundColor Red
		Wait-AnyKey
		exit 1
	}

	$remote = git config --get "branch.$baseBranch.remote" 2>$null
	if (-not $remote) {
		Write-Host "No remote configured for '$baseBranch'." -ForegroundColor Red
		Wait-AnyKey
		exit 1
	}

	if (-not (Confirm-Action "Pull $remote/$baseBranch into local '$baseBranch'?")) {
		Write-Host "Cancelled." -ForegroundColor Yellow
		exit 0
	}

	Write-Host "Fetching $remote/$baseBranch..." -ForegroundColor Cyan
	$ErrorActionPreference = "Continue"
	git fetch $remote $baseBranch
	$fetchExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($fetchExit -ne 0) {
		Write-Host "Fetch failed." -ForegroundColor Red
		Wait-AnyKey
		exit 1
	}

	$behind = git rev-list --count "${baseBranch}..$remote/$baseBranch" 2>$null
	$masterUpToDate = ($behind -eq "0")
	if ($masterUpToDate) {
		Write-Host "'$baseBranch' is already up to date with $remote/$baseBranch." -ForegroundColor Green
	}

	$repoRoot   = Get-RepoRoot
	$gitEntry   = Join-Path $repoRoot ".git"
	$isWorktree = $repoRoot -and [System.IO.File]::Exists($gitEntry)

	# ── Case 1: currently on master/main ────────────────────────────────────
	if ($branch -eq $baseBranch) {
		if (-not $masterUpToDate) {
			$pullExit = Invoke-Pull $here $baseBranch -NoFetch
			if ($pullExit -ne 0) {
				Write-Host "Pull failed." -ForegroundColor Red
				Wait-AnyKey
				exit 1
			}
		}
		exit 0
	}

	# ── Case 2: worktree ────────────────────────────────────────────────────
	if ($isWorktree) {
		$mainPath = Get-MainWorktreePath $repoRoot
		if (-not $mainPath) {
			Write-Host "Cannot locate main worktree." -ForegroundColor Red
			Wait-AnyKey
			exit 1
		}

		$wtDirty   = git -C $here status --porcelain --ignored=no 2>$null
		$wtStashed = $false
		if ($wtDirty) {
			$wtStashed = Invoke-Stash $here "auto-stash before pull $baseBranch (worktree)"
		}

		$mainDirty   = git -C $mainPath status --porcelain --ignored=no 2>$null
		$mainStashed = $false
		if ($mainDirty) {
			$mainStashed = Invoke-Stash $mainPath "auto-stash before pull $baseBranch (main)"
		}

		$pullExit = Invoke-Pull $mainPath $baseBranch -NoFetch
		if ($pullExit -ne 0) {
			Write-Host "Pull failed." -ForegroundColor Red
			if ($mainStashed) { Invoke-StashPop $mainPath }
			if ($wtStashed)   { Invoke-StashPop $here }
			Wait-AnyKey
			exit 1
		}

		if ($mainStashed) { Invoke-StashPop $mainPath }

		$mmScript = Join-Path $PSScriptRoot "mm.ps1"
		if (-not $masterUpToDate) {
			& $mmScript -WorkDir $here -Force
		}

		if ($wtStashed) { Invoke-StashPop $here }

		Invoke-PullCurrentIfBehind $here $branch
		exit 0
	}

	# ── Case 3: plain feature branch ────────────────────────────────────────
	$dirty   = git status --porcelain --ignored=no 2>$null
	$stashed = $false
	if ($dirty) {
		$stashed = Invoke-Stash $here "auto-stash before pull $baseBranch"
	}

	git checkout $baseBranch
	if ($LASTEXITCODE -ne 0) {
		Write-Host "Cannot switch to '$baseBranch'." -ForegroundColor Red
		if ($stashed) { Invoke-StashPop $here }
		Wait-AnyKey
		exit 1
	}

	$pullExit = Invoke-Pull $here $baseBranch -NoFetch

	git checkout $branch
	if ($LASTEXITCODE -ne 0) {
		Write-Host "Cannot switch back to '$branch'." -ForegroundColor Red
		if ($stashed) { Invoke-StashPop $here }
		Wait-AnyKey
		exit 1
	}

	if ($pullExit -ne 0) {
		Write-Host "Pull failed." -ForegroundColor Red
		if ($stashed) { Invoke-StashPop $here }
		Wait-AnyKey
		exit 1
	}

	$mmScript = Join-Path $PSScriptRoot "mm.ps1"
	if (-not $masterUpToDate) {
		& $mmScript -WorkDir $here -Force
	}

	if ($stashed) { Invoke-StashPop $here }
	Invoke-PullCurrentIfBehind $here $branch
	exit 0
}

# ── Default mode: pull current branch ───────────────────────────────────────

$remote = git config --get "branch.$branch.remote" 2>&1
if ($LASTEXITCODE -ne 0 -or -not $remote) {
	Write-Host "No remote tracking branch configured for '$branch'." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

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

Write-Host "Pulling $remote/$branch..." -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
git pull $remote $branch
$pullExit = $LASTEXITCODE
$ErrorActionPreference = "Stop"

if ($pullExit -eq 0) { exit 0 }

$status = git status --porcelain 2>$null

$unresolved = $status | Where-Object { $_ -match '^UU' }
if ($unresolved) {
	$conflictsScript = Join-Path $PSScriptRoot "conflicts.ps1"
	& $conflictsScript -AbortCommand "merge --abort" -CommitMessage "Merged $remote/$branch. Conflicts resolved."
	exit $LASTEXITCODE
}

$dirty = git status --porcelain --ignored=no 2>$null
if ($dirty) {
	Write-Host ""
	Write-Host "[warn] Local changes would be overwritten by pull." -ForegroundColor Yellow
	if (-not (Confirm-Action "Stash local changes and retry?")) {
		Write-Host "Cancelled." -ForegroundColor Yellow
		exit 1
	}

	$stashed = Invoke-Stash $here "auto-stash before pull $remote/$branch"

	$ErrorActionPreference = "Continue"
	git pull $remote $branch
	$pullExit2 = $LASTEXITCODE
	$ErrorActionPreference = "Stop"

	if ($pullExit2 -ne 0) {
		Write-Host "Pull failed after stash. Restoring stash..." -ForegroundColor Red
		if ($stashed) { Invoke-StashPop $here }
		Wait-AnyKey
		exit 1
	}

	if ($stashed) { Invoke-StashPop $here }
	exit 0
}

Write-Host "Pull failed." -ForegroundColor Red
Wait-AnyKey
exit 1