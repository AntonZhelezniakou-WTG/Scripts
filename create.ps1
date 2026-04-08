param(
	[string]$WorkDir,
	[string]$BranchName
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common\common.ps1")

if ($WorkDir) { Set-Location $WorkDir }

# --- Validate repo ---
git rev-parse --is-inside-work-tree 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
	Write-Host "Error: not a git repository." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

if (-not $BranchName) {
	Write-Host "Usage: create <branch-name>" -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

# --- Offer AEM/ prefix ---
if ($BranchName -notmatch '^AEM/') {
	Write-Host ""
	Write-Host "Branch name does not start with 'AEM/'. Add prefix? [Y/n] " -ForegroundColor Cyan -NoNewline
	$key = [Console]::ReadKey($true)
	Write-Host $key.KeyChar
	if ($key.KeyChar -match '^[Yy]$' -or $key.Key -eq 'Enter') {
		$BranchName = "AEM/$BranchName"
	}
}

Write-Host ""
Write-Host "Branch: $BranchName" -ForegroundColor Cyan

# --- Check remote (case-insensitive) ---
Write-Host "Checking remote..." -ForegroundColor DarkGray
$ErrorActionPreference = "Continue"
$remoteRefs = git ls-remote --heads origin 2>$null
$ErrorActionPreference = "Stop"

$alreadyExistsCI = $remoteRefs | Where-Object {
	$_ -match 'refs/heads/(.+)$' -and $Matches[1] -ieq $BranchName
} | Select-Object -First 1

if ($alreadyExistsCI) {
	$existingName = if ($alreadyExistsCI -match 'refs/heads/(.+)$') { $Matches[1] } else { $BranchName }
	Write-Host ""
	Write-Host "Branch '$existingName' already exists on remote." -ForegroundColor Yellow
	Write-Host ""
	Write-Host "Switch to it instead? [Y/n] " -ForegroundColor Cyan -NoNewline
	$key = [Console]::ReadKey($true)
	Write-Host $key.KeyChar
	if ($key.KeyChar -match '^[Yy]$' -or $key.Key -eq 'Enter') {
		$switchPs1 = Join-Path $PSScriptRoot "switch.ps1"
		& $switchPs1 -WorkDir $WorkDir -Branch $existingName
		exit $LASTEXITCODE
	}
	exit 0
}

# --- Choose: worktree or local branch ---
if (-not (Ensure-Fzf)) { Wait-AnyKey; exit 1 }

$options = @("Create worktree", "Create local branch")
$choice  = Invoke-Fzf -Entries $options -ExtraArgs @("--pointer=>", "--color=pointer:green,fg+:green:bold,bg+:-1")

if (-not $choice) {
	Write-Host "Cancelled." -ForegroundColor Yellow
	Wait-AnyKey
	exit 0
}

$useWorktree = $choice.Trim() -eq $options[0]

$wt = Get-WtPath $BranchName

if ($useWorktree) {
	if (-not (Test-Path $wt.WtRoot)) {
		New-Item -ItemType Directory -Path $wt.WtRoot | Out-Null
	}

	$copyGhLine = Get-CopyGitHubLine $wt.RepoRoot $wt.WtPath

	if ($env:WT_SESSION) {
		$safeLabel = $BranchName -replace "/", "_"
		$tabScript = Join-Path $env:TEMP "git-wt-tab-${safeLabel}.cmd"
		$wtPathStr = $wt.WtPath
		$repoRoot  = $wt.RepoRoot
		@"
@echo off
cd /d "$repoRoot"
git worktree add -b "$BranchName" "$wtPathStr"
if errorlevel 1 ( echo git worktree add failed. & pause & exit /b 1 )
$copyGhLine
cd /d "$wtPathStr"
choice /C YN /M "Push '$BranchName' to origin?"
if errorlevel 2 goto :skip_push
git push -u origin "$BranchName"
:skip_push
"@ | Set-Content $tabScript -Encoding ASCII
		wt --window 0 new-tab --title $BranchName --startingDirectory $repoRoot cmd /k $tabScript
		Write-Host "Opened WT tab for new worktree: $BranchName" -ForegroundColor Cyan
		exit 0
	}

	Write-Host ""
	Write-Host "== Creating worktree at '$($wt.WtPath)' ==" -ForegroundColor Cyan
	git worktree add -b $BranchName $wt.WtPath
	if ($LASTEXITCODE -ne 0) {
		Write-Host "Failed to create worktree." -ForegroundColor Red
		Wait-AnyKey
		exit 1
	}

	Copy-GitHubFolder $wt.RepoRoot $wt.WtPath

	Write-Host "Worktree created: $($wt.WtPath)" -ForegroundColor Green
} else {
	Write-Host ""
	Write-Host "== Creating local branch '$BranchName' ==" -ForegroundColor Cyan
	git checkout -b $BranchName
	if ($LASTEXITCODE -ne 0) {
		Write-Host "Failed to create branch." -ForegroundColor Red
		Wait-AnyKey
		exit 1
	}
	Write-Host "Branch created and checked out." -ForegroundColor Green
}

# --- Offer to push to remote ---
Write-Host ""
if (Confirm-Action "Push '$BranchName' to origin?") {
	$ErrorActionPreference = "Continue"
	git push -u origin $BranchName
	$pushExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"

	if ($pushExit -ne 0) {
		Write-Host "Push failed." -ForegroundColor Red
	} else {
		Write-Host "Pushed to origin/$BranchName." -ForegroundColor Green
		Ensure-FetchRefspec $BranchName
	}
}

Wait-AnyKey
exit 0