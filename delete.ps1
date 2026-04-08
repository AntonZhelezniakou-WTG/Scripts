param(
	[string]$WorkDir,
	[string]$Target
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common\common.ps1")

# Switch the repo (or worktree) to master/main before deleting current branch.
function Switch-ToDefault {
	$default = Get-BaseBranch

	if (-not $default) {
		Write-Host "ERROR: Cannot find master or main branch to switch to." -ForegroundColor Red
		return $false
	}

	Write-Host "== Switching to '$default' before deletion =="
	$ErrorActionPreference = "Continue"
	git checkout $default
	$ErrorActionPreference = "Stop"
	return $true
}

if ($WorkDir) { Set-Location $WorkDir }

# Validate git repository
git rev-parse --is-inside-work-tree 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
	Write-Host "Error: not a git repository." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

if (-not $Target) {
	Write-Host "Usage: delete <branch> | <worktree-name> | <worktree-path>" -ForegroundColor Yellow
	exit 1
}

# Resolve target: could be a branch name, worktree folder name, or full worktree path.
$allWorktrees = git worktree list --porcelain 2>$null
$worktreeInfo = @()
$current = @{}
foreach ($line in $allWorktrees) {
	if ($line -match "^worktree (.+)$")   { $current.Path   = $Matches[1].Trim() }
	if ($line -match "^branch (.+)$")     { $current.Branch = ($Matches[1].Trim() -replace "^refs/heads/", "") }
	if ($line -match "^HEAD (.+)$")       { $current.Head   = $Matches[1].Trim() }
	if ($line -eq "") {
		if ($current.Count -gt 0) { $worktreeInfo += [PSCustomObject]$current }
		$current = @{}
	}
}
if ($current.Count -gt 0) { $worktreeInfo += [PSCustomObject]$current }

$matchedWorktree = $worktreeInfo | Where-Object {
	$_.Path   -eq $Target -or
	$_.Path   -like "*$Target" -or
	$_.Branch -eq $Target
} | Select-Object -First 1

$branchName   = $null
$worktreePath = $null
$isWorktree   = $false

if ($matchedWorktree) {
	$branchName   = $matchedWorktree.Branch
	$worktreePath = $matchedWorktree.Path
	$isWorktree   = $true
} else {
	$exists = git branch --list $Target | Where-Object { $_ -ne "" }
	if (-not $exists) {
		Write-Host "Error: '$Target' is not a known branch or worktree." -ForegroundColor Red
		exit 1
	}
	$branchName = $Target

	$wt = Get-WtPath $branchName
	if (Test-Path $wt.WtPath) {
		$worktreePath = $wt.WtPath
		$isWorktree   = $true
	}
}

if ($branchName -eq "master" -or $branchName -eq "main") {
	Write-Host "ERROR: Cannot delete protected branch: $branchName" -ForegroundColor Red
	exit 1
}

Write-Host ""
Write-Host "Target branch : $branchName" -ForegroundColor Cyan
if ($isWorktree) {
	Write-Host "Worktree path : $worktreePath" -ForegroundColor Cyan
}
Write-Host ""

$currentBranchHere = git symbolic-ref --short HEAD 2>$null
$repoRoot          = Get-RepoRoot
$currentBranchMain = git -C $repoRoot symbolic-ref --short HEAD 2>$null
$isCurrentBranch   = ($currentBranchHere -eq $branchName) -or ($currentBranchMain -eq $branchName)

$currentDir       = (Get-Location).Path
$isInsideWorktree = $isWorktree -and $currentDir.StartsWith($worktreePath, [System.StringComparison]::OrdinalIgnoreCase)

if ($isInsideWorktree) {
	Write-Host "You are currently inside the worktree being deleted." -ForegroundColor Yellow
	Write-Host "Will switch to main repo root after deletion." -ForegroundColor Yellow
	Write-Host ""
}

if ($isCurrentBranch) {
	Write-Host "WARNING: '$branchName' is the currently active branch." -ForegroundColor Yellow
	if (-not (Confirm-Action "Switch to master/main and then delete '$branchName'?" -Color Yellow)) {
		Write-Host "Aborted." -ForegroundColor DarkGray
		exit 0
	}
	if (-not (Switch-ToDefault)) { exit 1 }
}

# Check for uncommitted changes in the worktree
if ($isWorktree -and (Test-Path $worktreePath)) {
	$dirty = git -C $worktreePath status --porcelain --ignored=no 2>$null
	if ($dirty) {
		$preview = $dirty | Select-Object -First 20
		Write-Host ""
		Write-Host "WARNING: WORKTREE HAS UNCOMMITTED CHANGES:" -ForegroundColor Red
		$preview | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
		if ($dirty.Count -gt 20) {
			Write-Host "  ... and $($dirty.Count - 20) more." -ForegroundColor Red
		}
		Write-Host ""
		if (-not (Confirm-Action "ARE YOU SURE YOU WANT TO DELETE WITH UNCOMMITTED CHANGES? (first confirmation)" -Color Red)) {
			Write-Host "Aborted." -ForegroundColor DarkGray
			exit 0
		}
		Write-Host ""
		if (-not (Confirm-Action "CONFIRM AGAIN - ALL UNCOMMITTED CHANGES WILL BE LOST PERMANENTLY." -Color Red)) {
			Write-Host "Aborted." -ForegroundColor DarkGray
			exit 0
		}
	}
}

# Check for commits not pushed to origin/<branch>
$hasOriginRef = git rev-parse --verify "refs/remotes/origin/$branchName" 2>$null
$unpushed = if ($hasOriginRef) {
	git log "refs/remotes/origin/${branchName}..${branchName}" --oneline 2>$null
} else {
	$null
}
if ($unpushed) {
	$baseLabel = "origin/$branchName"
	Write-Host ""
	Write-Host "WARNING: BRANCH HAS $($unpushed.Count) COMMIT(S) NOT IN ${baseLabel}:" -ForegroundColor Red
	$unpushed | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
	Write-Host ""
	if (-not (Confirm-Action "ARE YOU SURE YOU WANT TO DELETE WITH COMMITS NOT IN ${baseLabel}? (first confirmation)" -Color Red)) {
		Write-Host "Aborted." -ForegroundColor DarkGray
		exit 0
	}
	Write-Host ""
	if (-not (Confirm-Action "CONFIRM AGAIN - ALL COMMITS NOT IN ${baseLabel} WILL BE LOST PERMANENTLY." -Color Red)) {
		Write-Host "Aborted." -ForegroundColor DarkGray
		exit 0
	}
}

# Final confirmation
if (-not (Confirm-Action "Delete branch '$branchName'$(if ($isWorktree) { " and its worktree" })?" -Color Yellow)) {
	Write-Host "Aborted." -ForegroundColor DarkGray
	exit 0
}

Write-Host ""

# Step 1: Remove worktree
if ($isWorktree) {
	$ErrorActionPreference = "Continue"
	if (Test-Path $worktreePath) {
		Write-Host "== Removing worktree at '$worktreePath' =="
		git worktree remove --force $worktreePath
		Write-Host "Worktree removed." -ForegroundColor Green
	} else {
		Write-Host "== Pruning stale worktree registration for '$worktreePath' =="
		git worktree prune
		Write-Host "Worktree registration pruned." -ForegroundColor Green
	}
	$ErrorActionPreference = "Stop"
}

# Step 2: Remove local branch
Write-Host "== Deleting local branch '$branchName' =="
$ErrorActionPreference = "Continue"
git branch -D $branchName
$ErrorActionPreference = "Stop"
Write-Host "Branch deleted." -ForegroundColor Green

# Step 3: Clean up git config
Remove-GitBranchConfig -BranchName $branchName

Write-Host ""
Write-Host "Done: '$branchName' deleted." -ForegroundColor Green

# Step 4: If we were inside the deleted worktree, show main repo path
if ($isInsideWorktree) {
	if ($repoRoot) {
		Write-Host ""
		Write-Host "  Left worktree. Main repo: $repoRoot" -ForegroundColor Cyan
		Write-Host "  Run: cd `"$repoRoot`"" -ForegroundColor Cyan
	}
}