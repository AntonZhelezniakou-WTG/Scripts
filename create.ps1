param(
	[string]$BranchName,
	[string]$WorkDir
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common\common.ps1")

# Fetch and start a new working-copy change off the base bookmark, preferring
# the freshly-fetched base@origin over the local one. Returns $true on success.
function Start-JjChangeOffBase {
	param([Parameter(Mandatory)][string]$Base)

	Write-Host ""
	Write-Host "== Fetching '$Base' from origin ==" -ForegroundColor DarkGray
	$ErrorActionPreference = "Continue"
	jj git fetch --branch $Base | Out-Host
	$ErrorActionPreference = "Stop"

	# Prefer the freshly-fetched remote bookmark, fall back to the local one.
	$dest = if (Test-JjRevExists "$Base@origin") { "$Base@origin" }
	        elseif (Test-JjRevExists $Base)       { $Base }
	        else { $null }
	if (-not $dest) {
		Write-Host "Error: '$Base' not found locally or on origin." -ForegroundColor Red
		return $false
	}

	Write-Host ""
	Write-Host "== Starting new change off '$dest' ==" -ForegroundColor Cyan
	$ErrorActionPreference = "Continue"
	jj new $dest 2>&1 | Out-Host
	$newExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($newExit -ne 0) {
		Write-Host "Failed to start a new change off '$dest'." -ForegroundColor Red
		return $false
	}
	return $true
}

# 'create new': no name yet — just start a fresh anonymous change off the base.
# The bookmark comes later, via 'create <name>' or at commit time.
function Invoke-JjNew {
	$root = Get-JjRoot
	if ($root) { Set-Location $root }

	$base = Get-JjBaseBookmark
	if (-not $base) {
		Write-Host "Error: no base bookmark (main/master) found." -ForegroundColor Red
		Wait-AnyKey
		return
	}

	if (-not (Start-JjChangeOffBase $base)) {
		Wait-AnyKey
		return
	}

	Write-Host "Working copy is a fresh change off '$base'. Name it later with 'create <name>' or at commit time." -ForegroundColor Green
	Wait-AnyKey
}

# jj: "create a branch" = put a bookmark on the current change (the local-branch
# analogue). Workspaces (the worktree analogue) are a separate follow-up.
function Invoke-JjCreate {
	param([string]$Name)
	$root = Get-JjRoot
	if ($root) { Set-Location $root }

	if ((Get-JjBookmarks) -contains $Name -or (Test-JjRevExists "$Name@origin")) {
		Write-Host ""
		Write-Host "Bookmark '$Name' already exists." -ForegroundColor Yellow
		if (Confirm-Action "Move to it (jj edit) instead?") {
			$ErrorActionPreference = "Continue"
			jj edit $Name 2>&1 | Out-Host
			$ErrorActionPreference = "Stop"
		}
		Wait-AnyKey
		return
	}

	# Where to start: when @ is not on the base line (main/master is not the
	# nearest bookmark), offer to fork from a freshly-fetched base instead of
	# bookmarking the current change.
	$base = Get-JjBaseBookmark
	$nearBase = $base -and (@(Get-JjNearestAncestorBookmarks) -contains $base)
	if ($base -and -not $nearBase) {
		if (-not (Ensure-Fzf)) { Wait-AnyKey; return }
		$options = @("At current change (@)", "New change off '$base' (fetch from origin)")
		$choice = Invoke-Fzf -Entries $options -ExtraArgs @(
			"--header=Start '$Name' from:", "--header-first",
			"--pointer=>", "--color=pointer:green,fg+:green:bold,bg+:-1")
		if (-not $choice) {
			Write-Host "Cancelled." -ForegroundColor Yellow
			Wait-AnyKey
			return
		}
		if ($choice.Trim() -eq $options[1]) {
			if (-not (Start-JjChangeOffBase $base)) {
				Wait-AnyKey
				return
			}
		}
	}

	Write-Host ""
	Write-Host "== Creating bookmark '$Name' at the current change ==" -ForegroundColor Cyan
	$ErrorActionPreference = "Continue"
	jj bookmark create $Name -r '@'
	$createExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($createExit -ne 0) {
		Write-Host "Failed to create bookmark." -ForegroundColor Red
		Wait-AnyKey
		return
	}
	Write-Host "Bookmark created." -ForegroundColor Green

	Write-Host ""
	if (Confirm-Action "Push '$Name' to origin?") {
		$ErrorActionPreference = "Continue"
		jj git push -b $Name
		$pushExit = $LASTEXITCODE
		$ErrorActionPreference = "Stop"
		if ($pushExit -ne 0) { Write-Host "Push failed." -ForegroundColor Red }
		else {
			Write-Host "Pushed to origin/$Name." -ForegroundColor Green
			Ensure-JjFetchRefspec $Name
		}
	}
	Wait-AnyKey
}

# Backward compatibility for old positional order: create.ps1 <workdir> <branch>
if ($BranchName -and $WorkDir -and (Test-Path -LiteralPath $BranchName -PathType Container) -and -not (Test-Path -LiteralPath $WorkDir -PathType Container)) {
	$tmp = $BranchName
	$BranchName = $WorkDir
	$WorkDir = $tmp
}

if ($WorkDir) {
	if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) {
		Write-Host "Error: WorkDir does not exist: $WorkDir" -ForegroundColor Red
		Wait-AnyKey
		exit 1
	}
	Set-Location $WorkDir
}

# --- Validate repo ---
$script:VcsBackend = Get-VcsBackend
if (-not $script:VcsBackend) {
	Write-Host "Error: not a repository." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

if (-not $BranchName) {
	Write-Host "Usage: create <branch-name> | create new" -ForegroundColor Red
	Write-Host "  create new (jj): start a fresh unnamed change off main/master." -ForegroundColor DarkGray
	Wait-AnyKey
	exit 1
}

# --- 'create new': anonymous change off the base, name comes later (jj only) ---
if ($BranchName -eq 'new') {
	if ($script:VcsBackend -ne 'jj') {
		Write-Host "'create new' needs a nameless working copy — only supported in jj repos." -ForegroundColor Red
		Write-Host "In git: pick a name ('create <name>') or update main with 'pull main'." -ForegroundColor Yellow
		Wait-AnyKey
		exit 1
	}
	Invoke-JjNew
	exit 0
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

# --- jj backend: bookmark-based create ---
if ($script:VcsBackend -eq 'jj') { Invoke-JjCreate $BranchName; exit 0 }

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
		$switchPs1 = Join-Path $PSScriptRoot "branches.ps1"
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
		$tabScript = Join-Path $env:TEMP "git-wt-tab-${safeLabel}.ps1"
		$wtPathStr = $wt.WtPath
		$repoRoot  = $wt.RepoRoot
		@"
Set-Location -LiteralPath '$repoRoot'
git worktree add -b '$BranchName' '$wtPathStr'
if (`$LASTEXITCODE -ne 0) { Write-Host 'git worktree add failed.' -ForegroundColor Red; Read-Host 'Press Enter to exit'; exit 1 }
$copyGhLine
Set-Location -LiteralPath '$wtPathStr'
Write-Host -NoNewline "Push '$BranchName' to origin? [Y/n] " -ForegroundColor Cyan
`$key = [Console]::ReadKey(`$true)
Write-Host `$key.KeyChar
if (`$key.Key -eq 'Enter' -or `$key.KeyChar -match '^[Yy]$') { git push -u origin '$BranchName' }
"@ | Set-Content $tabScript -Encoding UTF8
		wt --window 0 new-tab --title $BranchName --startingDirectory $repoRoot pwsh -NoLogo -NoExit -File $tabScript
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