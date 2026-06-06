param(
	[string]$Base,
	[switch]$Force,
	[string]$WorkDir
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common\common.ps1")

# When launched from PowerShell the cwd is already the repo, so $WorkDir is only
# passed by the .cmd shim (from cmd.exe). Ignore it if it isn't an existing path
# so a stray first positional argument can't break the cd.
if ($WorkDir -and (Test-Path -LiteralPath $WorkDir -PathType Container)) { Set-Location $WorkDir }

# ── jj backend ───────────────────────────────────────────────────────────────
if ((Get-VcsBackend) -eq 'jj') {
	$root = Get-JjRoot
	if ($root) { Set-Location $root }

	$baseBranch = Get-JjBaseBookmark -Explicit $Base
	if (-not $baseBranch) {
		Write-Host "Error: no base bookmark (main/master) found." -ForegroundColor Red
		Wait-AnyKey
		exit 1
	}

	if (-not $Force) {
		if (-not (Confirm-Action "Fetch and rebase the current change onto '$baseBranch'?")) {
			Write-Host "Cancelled." -ForegroundColor Yellow
			exit 0
		}
	}

	Write-Host ""
	Write-Host "== Fetching '$baseBranch' from origin ==" -ForegroundColor DarkGray
	$ErrorActionPreference = "Continue"
	jj git fetch --branch $baseBranch
	$ErrorActionPreference = "Stop"

	# Prefer the freshly-fetched remote bookmark, fall back to the local one.
	$dest = if (Test-JjRevExists "$baseBranch@origin") { "$baseBranch@origin" }
	        elseif (Test-JjRevExists $baseBranch)       { $baseBranch }
	        else { $null }
	if (-not $dest) {
		Write-Host "Error: '$baseBranch' not found locally or on origin." -ForegroundColor Red
		Wait-AnyKey
		exit 1
	}

	Write-Host ""
	Write-Host "== Rebasing current branch onto '$dest' ==" -ForegroundColor Cyan
	$ErrorActionPreference = "Continue"
	jj rebase -b '@' -d $dest
	$rebaseExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"

	if ($rebaseExit -ne 0) {
		Write-Host "Rebase failed (see the message above). Recover with 'jj op undo'." -ForegroundColor Red
		Wait-AnyKey
		exit $rebaseExit
	}

	# jj exits 0 even with conflicts — detect them explicitly.
	if (Test-JjHasConflicts) {
		Write-Host ""
		Write-Host "Rebase produced conflicts. Resolve with 'jj resolve', or undo with 'jj op undo'." -ForegroundColor Yellow
		Wait-AnyKey
		exit 1
	}

	Write-Host "Rebase completed successfully." -ForegroundColor Green
	exit 0
}

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

# Base branch to pull and merge: explicit argument, else local master/main.
if ($Base) {
	$baseBranch = $Base
} else {
	$baseBranch = Get-BaseBranch
	if (-not $baseBranch) {
		Write-Host "Error: neither 'master' nor 'main' found locally." -ForegroundColor Red
		Wait-AnyKey
		exit 1
	}
}

if ($baseBranch -eq $currentBranch) {
	Write-Host "'$baseBranch' is the current branch. Nothing to merge." -ForegroundColor Yellow
	Wait-AnyKey
	exit 0
}

if (-not $Force) {
	if (-not (Confirm-Action "Pull '$baseBranch' from origin and merge into '$currentBranch'?")) {
		Write-Host "Cancelled." -ForegroundColor Yellow
		exit 0
	}
}

# Fetch the latest base from origin. Use the repo's per-branch refspec helpers so
# that origin/<base> is updated even in single-branch clones (a plain
# `git fetch origin <base>` would only move FETCH_HEAD there).
Write-Host ""
Write-Host "== Updating '$baseBranch' from origin ==" -ForegroundColor DarkGray
Ensure-FetchRefspec $baseBranch
Fetch-Branch $baseBranch

# Decide what to merge: prefer the freshly-fetched origin ref, fall back to a
# local branch of the same name, otherwise there is nothing to merge.
$ErrorActionPreference = "Continue"
$hasOrigin = [bool](git rev-parse --verify --quiet "refs/remotes/origin/$baseBranch" 2>$null)
$hasLocal  = [bool](git rev-parse --verify --quiet "refs/heads/$baseBranch" 2>$null)
$ErrorActionPreference = "Stop"

if ($hasOrigin) {
	$mergeRef = "origin/$baseBranch"
} elseif ($hasLocal) {
	$mergeRef = $baseBranch
	Write-Host "Warning: '$baseBranch' not found on origin; merging local copy." -ForegroundColor Yellow
} else {
	Write-Host "Error: branch '$baseBranch' not found locally or on origin." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

Write-Host ""
Write-Host "== Merging '$mergeRef' into '$currentBranch' ==" -ForegroundColor Cyan

$ErrorActionPreference = "Continue"
git merge $mergeRef --no-edit --quiet --no-stat
$mergeExit = $LASTEXITCODE
$ErrorActionPreference = "Stop"

if ($mergeExit -eq 0) {
	Write-Host "Merge completed successfully." -ForegroundColor Green
	exit 0
}

# A non-zero exit means either real conflicts or a plain failure (e.g. a dirty
# working tree that git refused to overwrite). Only launch the conflict resolver
# when there are genuinely unmerged paths; otherwise report git's own message.
$ErrorActionPreference = "Continue"
$unmerged = @(git diff --name-only --diff-filter=U 2>$null)
$ErrorActionPreference = "Stop"

if ($unmerged.Count -eq 0) {
	Write-Host "Merge failed (see the message above). Nothing was changed." -ForegroundColor Red
	Wait-AnyKey
	exit $mergeExit
}

$conflictFiles = $unmerged -join ", "
$conflictsScript = Join-Path $PSScriptRoot "conflicts.ps1"
& $conflictsScript -AbortCommand "merge --abort" -CommitMessage "Merged $baseBranch. Conflicts resolved in: $conflictFiles"
exit $LASTEXITCODE