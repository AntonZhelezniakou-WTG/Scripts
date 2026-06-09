param(
	[string]$WorkDir,
	[string]$Target
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common\common.ps1")

# Pulls $BranchName in $RepoPath; pass -NoFetch if fetch was done earlier
# Returns exit code as [int]
function Invoke-Pull([string]$RepoPath, [string]$BranchName, [switch]$NoFetch) {
	$remote = git -C $RepoPath config --get "branch.$BranchName.remote" 2>$null
	if (-not $remote) {
		Write-Host "No remote configured for '$BranchName', skipping pull." -ForegroundColor Yellow
		return [int]0
	}

	if (-not $NoFetch) {
		Write-Host "Fetching $remote/$BranchName..." -ForegroundColor Cyan
		$ErrorActionPreference = "Continue"
		git -C $RepoPath fetch $remote $BranchName | Out-Host
		$fetchExit = $LASTEXITCODE
		$ErrorActionPreference = "Stop"
		if ($fetchExit -ne 0) {
			Write-Host "Fetch failed." -ForegroundColor Red
			Wait-AnyKey
			exit 1
		}
	}

	$behind = git -C $RepoPath rev-list --count "${BranchName}..$remote/$BranchName" 2>$null
	if ($behind -eq "0") { return [int]0 }

	Write-Host "Pulling $remote/$BranchName..." -ForegroundColor Cyan
	$ErrorActionPreference = "Continue"
	git -C $RepoPath merge --ff-only "$remote/$BranchName" | Out-Host
	$pullExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	return [int]$pullExit
}

function Get-BranchBehind([string]$RepoPath, [string]$BranchName) {
	$r = git -C $RepoPath config --get "branch.$BranchName.remote" 2>$null
	if (-not $r) { return [int]0 }
	$tracked = git -C $RepoPath rev-parse --verify "$r/$BranchName" 2>$null
	if (-not $tracked) { return [int]0 }
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
		git -C $RepoPath fetch $r $BranchName | Out-Host
		Write-Host "Pulling $r/${BranchName}..." -ForegroundColor Cyan
		$ErrorActionPreference = "Continue"
		git -C $RepoPath merge --ff-only "$r/$BranchName" | Out-Host
		$ErrorActionPreference = "Stop"
	}
}

# ── Setup ────────────────────────────────────────────────────────────────────

$WorkDir, $Target = Resolve-WorkDirArg $WorkDir $Target
if ($WorkDir) { Set-Location $WorkDir }

# ── jj backend ───────────────────────────────────────────────────────────────
# No staging/stash dance: pull is just fetch + rebase the current change onto the
# updated remote. main/master target rebases onto the base; otherwise onto the
# current bookmark's own remote.
if ((Get-VcsBackend) -eq 'jj') {
	$root = Get-JjRoot
	if ($root) { Set-Location $root }

	# Resolve what to pull first, then fetch only that branch — a plain
	# `jj git fetch` would walk every refspec (or, without narrow refspecs,
	# every branch of a huge remote).
	if ($Target -in @('main', 'master')) {
		$base = Get-JjBaseBookmark -Explicit $Target
		if (-not $base) {
			Write-Host "No base bookmark (main/master) found." -ForegroundColor Red
			Wait-AnyKey
			exit 1
		}
		$fetchName = $base
	} else {
		$bm = Select-JjBookmarkForPush -Header "Which bookmark to pull?"
		if (-not $bm) {
			Write-Host "No bookmark on the current change to pull." -ForegroundColor Yellow
			exit 0
		}
		$fetchName = $bm
	}
	$dest = "$fetchName@origin"

	Write-Host "== Fetching '$fetchName' from origin ==" -ForegroundColor DarkGray
	$ErrorActionPreference = "Continue"
	jj git fetch --branch $fetchName | Out-Host
	$ErrorActionPreference = "Stop"

	if (-not (Test-JjRevExists $dest)) {
		Write-Host "Bookmark '$fetchName' has no remote on origin — nothing to pull." -ForegroundColor Yellow
		exit 0
	}
	Ensure-JjFetchRefspec $fetchName

	Write-Host ""
	Write-Host "== Rebasing current branch onto '$dest' ==" -ForegroundColor Cyan
	$ErrorActionPreference = "Continue"
	jj rebase -b '@' -d $dest
	$rebaseExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($rebaseExit -ne 0) {
		Write-Host "Rebase failed (see above). Recover with 'jj op undo'." -ForegroundColor Red
		Wait-AnyKey
		exit $rebaseExit
	}
	if (Test-JjHasConflicts) {
		Write-Host ""
		Write-Host "Pull produced conflicts. Resolve with 'jj resolve', or undo with 'jj op undo'." -ForegroundColor Yellow
		Wait-AnyKey
		exit 1
	}
	Write-Host "Up to date." -ForegroundColor Green
	exit 0
}

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
	$localBranches = Get-LocalBranches
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
	git fetch $remote $baseBranch | Out-Host
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

		$mmScript = Join-Path $PSScriptRoot "pump.ps1"
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

	git checkout $baseBranch | Out-Host
	if ($LASTEXITCODE -ne 0) {
		Write-Host "Cannot switch to '$baseBranch'." -ForegroundColor Red
		if ($stashed) { Invoke-StashPop $here }
		Wait-AnyKey
		exit 1
	}

	$pullExit = Invoke-Pull $here $baseBranch -NoFetch

	git checkout $branch | Out-Host
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

	$mmScript = Join-Path $PSScriptRoot "pump.ps1"
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
git fetch $remote $branch | Out-Host
$fetchExit = $LASTEXITCODE
$ErrorActionPreference = "Stop"
if ($fetchExit -ne 0) {
	Write-Host "Fetch failed." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

Write-Host "Pulling $remote/$branch..." -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
git pull $remote $branch | Out-Host
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
	git pull $remote $branch | Out-Host
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