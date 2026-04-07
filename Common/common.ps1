# Shared functions for git workflow scripts.
# Usage: . (Join-Path $PSScriptRoot "Common\common.ps1")

. (Join-Path $PSScriptRoot "Git.ps1")
. (Join-Path $PSScriptRoot "Stash.ps1")
. (Join-Path $PSScriptRoot "FzfTree.ps1")

# Pause until any key is pressed.
function Wait-AnyKey {
	Write-Host "Press any key to continue..." -ForegroundColor Yellow
	$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# Prompt user with [Y/n]. Returns $true if confirmed.
function Confirm-Action {
	param([string]$Message, [ConsoleColor]$Color = "Cyan")
	Write-Host "$Message [Y/n] " -ForegroundColor $Color -NoNewline
	$key = [Console]::ReadKey($true)
	Write-Host $key.KeyChar
	return ($key.KeyChar -match '^[Yy]$' -or $key.Key -eq 'Enter')
}

# Get repo root from $PWD, preserving symlinks (unlike git rev-parse --show-toplevel).
function Get-RepoRoot {
	$gitCwd     = (git rev-parse --show-prefix 2>$null)
	if ($null -eq $gitCwd) { return $null }
	$gitCwd     = $gitCwd.TrimEnd('/')
	$currentDir = (Get-Location).Path
	if ($gitCwd) {
		$depth = ($gitCwd -split '/').Count
		$root  = $currentDir
		for ($i = 0; $i -lt $depth; $i++) { $root = Split-Path $root -Parent }
		return $root
	}
	return $currentDir
}

# Load Paths.json config. Returns defaults if file is missing.
function Get-PathsConfig {
	$configPath = Join-Path $PSScriptRoot "..\Configuration\Paths.json"
	if (Test-Path $configPath) {
		return Get-Content $configPath -Raw | ConvertFrom-Json
	}
	return [PSCustomObject]@{
		githubBase      = "C:\git\GitHub"
		worktreeBase    = "D:\wt"
		defaultOwner    = "WiseTechGlobal"
		ownerAliases    = @()
		worktreeAliases = @()
	}
}

# Get remote repo names for a GitHub owner from Configuration\RepoCache.json.
# Fetches via gh CLI when ForceRefresh is set or entry is absent.
# Cache has no automatic expiry — refresh explicitly with -ForceRefresh.
function Get-CachedRemoteRepos {
	param([string]$Owner, [switch]$ForceRefresh)

	$cachePath = Join-Path $PSScriptRoot "..\Configuration\RepoCache.json"
	$cache = @{}
	if (Test-Path $cachePath) {
		try { $cache = Get-Content $cachePath -Raw | ConvertFrom-Json -AsHashtable } catch {}
	}

	if (-not $ForceRefresh -and $cache.ContainsKey($Owner) -and $cache[$Owner].repos) {
		return @($cache[$Owner].repos)
	}

	if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
		return if ($cache.ContainsKey($Owner)) { @($cache[$Owner].repos) } else { @() }
	}

	$ErrorActionPreference = "Continue"
	$json = gh repo list $Owner --limit 200 --json name 2>$null
	$ErrorActionPreference = "Stop"

	$repos = @()
	if ($json) {
		try { $repos = @(($json | ConvertFrom-Json) | ForEach-Object { $_.name }) } catch {}
	}

	$cache[$Owner] = @{ cachedAt = (Get-Date -Format 'o'); repos = $repos }

	$configDir = Join-Path $PSScriptRoot "..\Configuration"
	if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
	$cache | ConvertTo-Json -Depth 3 | Set-Content $cachePath -Encoding UTF8

	return $repos
}

# Compute the worktree subfolder name from a branch name.
# Short mode (shortFolderNames = true in config):
#   - drops path prefix (e.g. AEM/ is stripped)
#   - strips leading WI (case-insensitive) when immediately followed by a digit
#   - truncates to 30 characters
# Standard mode: replaces / with _
function Get-WtFolderName {
	param([string]$BranchName, [bool]$Short = $false)
	if ($Short) {
		$name = $BranchName -replace '^.+/', ''          # drop prefix: AEM/foo -> foo
		$name = $name -replace '(?i)^WI(?=\d)', ''       # WI00123... -> 00123...
		if ($name.Length -gt 30) { $name = $name.Substring(0, 30) }
		return $name
	}
	return $BranchName -replace '/', '_'
}

# Resolve worktree root and target path for a branch.
# Worktrees are stored under worktreeBase (Paths.json), e.g. D:\wt\{repo}\{branch}.
# worktreeAliases can override the folder name and enable short folder names (max 30 chars).
function Get-WtPath {
	param([string]$BranchName)
	$config   = Get-PathsConfig
	$wtBase   = $config.worktreeBase
	$repoRoot = Get-RepoRoot
	$repoName = Split-Path $repoRoot -Leaf

	# Derive full repo name (Owner/Repo) from remote URL for alias lookup
	$ErrorActionPreference = "Continue"
	$remoteUrl = git remote get-url origin 2>$null
	$ErrorActionPreference = "Stop"
	$fullName = if ($remoteUrl -match 'github\.com[/:](.+?)(?:\.git)?\s*$') { $Matches[1].Trim() } else { $repoName }

	# Check worktree aliases for folder name override and short-name flag
	$wtFolder  = $repoName
	$useShort  = $false
	foreach ($alias in $config.worktreeAliases) {
		if ($alias.repo -ieq $fullName) {
			if ($alias.worktreeFolder) { $wtFolder = $alias.worktreeFolder }
			$useShort = [bool]$alias.shortFolderNames
			break
		}
	}

	$wtRoot     = Join-Path $wtBase $wtFolder
	$folderName = Get-WtFolderName -BranchName $BranchName -Short $useShort
	return [PSCustomObject]@{
		WtRoot   = $wtRoot
		WtPath   = Join-Path $wtRoot $folderName
		RepoRoot = $repoRoot
	}
}

# Find the main worktree path (where .git is a directory, not a file).
# Falls back to git worktree list, which handles both old (.{repo}.wt) and
# new (D:\wt\{folder}) worktree locations.
function Get-MainWorktreePath {
	param([string]$RepoRoot)
	if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot }
	$gitEntry = Join-Path $RepoRoot ".git"

	# Already main worktree — .git is a directory
	if ([System.IO.Directory]::Exists($gitEntry)) { return $RepoRoot }

	# Fallback: git worktree list
	# git outputs paths with forward slashes on Windows — normalise to backslashes
	# so that string comparisons (StartsWith etc.) work correctly against PS paths.
	$lines = git worktree list --porcelain 2>$null
	foreach ($line in $lines) {
		if ($line -match '^worktree (.+)') {
			$wt = $Matches[1].Trim().Replace('/', '\')
			if ([System.IO.Directory]::Exists((Join-Path $wt ".git"))) {
				return $wt
			}
		}
	}
	return $null
}

# Run fzf with standard minimal style. Pass extra args as needed.
function Invoke-Fzf {
	param(
		[string[]]$Entries,
		[string[]]$ExtraArgs
	)
	$Entries | fzf `
		--style=minimal --no-input --disabled --height=40% --no-info --layout=reverse `
		--pointer=" " --gutter=" " `
		@ExtraArgs
}

# Register a fetch refspec for a branch in .git/config if not already present.
function Ensure-FetchRefspec {
	param([string]$BranchName)
	$refspec      = "+refs/heads/${BranchName}:refs/remotes/origin/${BranchName}"
	$gitCommonDir = git rev-parse --git-common-dir
	$existing     = git config --file "$gitCommonDir/config" --get-all remote.origin.fetch 2>$null
	if ($existing -notcontains $refspec) {
		git config --file "$gitCommonDir/config" --add remote.origin.fetch $refspec
		Write-Host "[config] Registered fetch refspec for: $BranchName" -ForegroundColor DarkGray
	}
}

# Fetch a single branch from origin.
function Fetch-Branch {
	param([string]$BranchName)
	$ErrorActionPreference = "Continue"
	git fetch origin "${BranchName}:refs/remotes/origin/${BranchName}" 2>$null
	$ErrorActionPreference = "Stop"
}

# Remove fetch refspec, remote-tracking ref, and branch config section.
function Remove-GitBranchConfig {
	param([string]$BranchName)
	$gitCommonDir = git rev-parse --git-common-dir
	$configFile   = "$gitCommonDir/config"

	# Remove fetch refspec
	$refspec  = "+refs/heads/${BranchName}:refs/remotes/origin/${BranchName}"
	$existing = git config --file $configFile --get-all remote.origin.fetch 2>$null
	if ($existing -contains $refspec) {
		git config --file $configFile --unset remote.origin.fetch ([regex]::Escape($refspec))
		Write-Host "[config] Removed fetch refspec for: $BranchName" -ForegroundColor DarkGray
	}

	# Remove remote-tracking ref
	$ErrorActionPreference = "Continue"
	git update-ref -d "refs/remotes/origin/$BranchName" 2>$null
	$ErrorActionPreference = "Stop"

	# Remove [branch "name"] config section
	$ErrorActionPreference = "Continue"
	git config --file $configFile --remove-section "branch.$BranchName" 2>$null
	$ErrorActionPreference = "Stop"

	Write-Host "[config] Cleaned git config for: $BranchName" -ForegroundColor DarkGray
}

# Prompt user to choose a name for the main branch via fzf.
# Shows the detected remote name first. Returns branch name or $null if cancelled.
function Select-MainBranchName {
	param([string]$DetectedBranch)

	if (-not (Ensure-Fzf)) { return $DetectedBranch }

	$options = @($DetectedBranch)
	$alt = if ($DetectedBranch -eq "master") { "main" } elseif ($DetectedBranch -eq "main") { "master" } else { $null }
	if ($alt) { $options += $alt }
	$options += "custom..."

	$picked = $options | fzf `
		--style=minimal --no-input --disabled --height=~5 --no-info --layout=reverse `
		--pointer=">" --gutter=" " `
		--color="pointer:green,fg+:green:bold,bg+:-1" `
		--header="Main branch name (remote: $DetectedBranch):" `
		--header-first

	if (-not $picked) { return $null }

	if ($picked -eq "custom...") {
		Write-Host "Branch name: " -NoNewline -ForegroundColor Cyan
		$branchName = ([Console]::ReadLine()).Trim()
		if (-not $branchName) { return $null }
		return $branchName
	}

	return $picked
}

# Rename the default branch locally and on the remote.
# Must be called from within the repo directory.
function Rename-DefaultBranch {
	param(
		[string]$OldBranch,
		[string]$NewBranch,
		[string]$RepoUrl
	)

	Write-Host "Renaming default branch: $OldBranch -> $NewBranch..." -ForegroundColor Cyan

	# Rename local branch
	git branch -m $OldBranch $NewBranch

	# Push new branch to remote and set tracking
	git push -u origin $NewBranch
	if ($LASTEXITCODE -ne 0) {
		Write-Host "Error: failed to push '$NewBranch' to remote." -ForegroundColor Red
		return $false
	}

	# Change default branch on GitHub via API
	$ghUpdated = $false
	if ($RepoUrl -match 'github\.com[/:](.+?)(?:\.git)?$') {
		$slug = $Matches[1]
		$ErrorActionPreference = "Continue"
		$null = gh api "repos/$slug" -X PATCH -f default_branch=$NewBranch 2>$null
		$ghUpdated = ($LASTEXITCODE -eq 0)
		$ErrorActionPreference = "Stop"
	}

	if ($ghUpdated) {
		# Delete old remote branch
		$ErrorActionPreference = "Continue"
		git push origin --delete $OldBranch 2>$null
		$ErrorActionPreference = "Stop"
	} else {
		Write-Host "Warning: could not update default branch on GitHub (gh CLI needed). Old branch '$OldBranch' retained on remote." -ForegroundColor Yellow
	}

	# Clean up old remote-tracking ref
	$ErrorActionPreference = "Continue"
	git update-ref -d "refs/remotes/origin/$OldBranch" 2>$null
	$ErrorActionPreference = "Stop"

	# Fix fetch refspec (--single-branch clone has exactly one)
	git config remote.origin.fetch "+refs/heads/${NewBranch}:refs/remotes/origin/${NewBranch}"

	# Update remote HEAD ref
	git remote set-head origin $NewBranch

	return $true
}

# Prompt user to pick an initial branch name for an empty repo via fzf.
# Returns the branch name, or $null if cancelled.
function Select-InitialBranch {
	if (-not (Ensure-Fzf)) { return $null }

	Write-Host "Repository is empty. Choose a name for the initial branch:" -ForegroundColor Yellow

	$picked = @("master", "main", "custom...") | fzf `
		--style=minimal --no-input --disabled --height=~5 --no-info --layout=reverse `
		--pointer=">" --gutter=" " `
		--color="pointer:green,fg+:green:bold,bg+:-1" `
		--header="Select initial branch name:" `
		--header-first

	if (-not $picked) { return $null }

	if ($picked -eq "custom...") {
		Write-Host "Branch name: " -NoNewline -ForegroundColor Cyan
		$branchName = ([Console]::ReadLine()).Trim()
	} else {
		$branchName = $picked
	}

	if (-not $branchName) { return $null }
	return $branchName
}

# Initialize an empty repo: set HEAD to the chosen branch, create an initial commit, push.
# Returns $true on success, $false on failure.
function Initialize-EmptyRepoBranch {
	param([string]$BranchName)

	git symbolic-ref HEAD "refs/heads/$BranchName"
	git commit --allow-empty -m "Initial commit"
	git push -u origin $BranchName
	$pushExit = $LASTEXITCODE

	if ($pushExit -ne 0) {
		Write-Host "Error: failed to push initial branch '$BranchName'." -ForegroundColor Red
		return $false
	}

	Write-Host "Done. Created branch '$BranchName' and pushed initial commit." -ForegroundColor Green
	return $true
}

# Check if fzf is installed; offer to install via winget if not.
function Ensure-Fzf {
	if (Get-Command fzf -ErrorAction SilentlyContinue) { return $true }

	Write-Host "fzf is not installed. It is required for interactive menus." -ForegroundColor Yellow
	Write-Host ""
	Write-Host -NoNewline "Install fzf now via winget? [Y/n]: "
	$key = [Console]::ReadKey($true)
	Write-Host $key.KeyChar

	if ($key.Key -eq "Enter" -or $key.KeyChar -match "^[Yy]$") {
		winget install fzf
		if ($LASTEXITCODE -ne 0 -or -not (Get-Command fzf -ErrorAction SilentlyContinue)) {
			Write-Host "Failed to install fzf. Please install it manually: winget install fzf" -ForegroundColor Red
			return $false
		}
		$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
		            [System.Environment]::GetEnvironmentVariable("PATH", "User")
		Write-Host "fzf installed successfully." -ForegroundColor Green
		return $true
	}

	Write-Host "Aborted." -ForegroundColor Red
	return $false
}

# Copy .github folder from main repo root into worktree if it exists.
function Copy-GitHubFolder {
	param([string]$RepoRoot, [string]$WtPath)
	$src = Join-Path $RepoRoot ".github"
	if (Test-Path $src) {
		$dst = Join-Path $WtPath ".github"
		Copy-Item -Path $src -Destination $dst -Recurse -Force
		Write-Host "[info] Copied .github from repo root" -ForegroundColor DarkGray
	}
}

# Build xcopy command for .github in cmd tab scripts. Returns empty string if not needed.
function Get-CopyGitHubLine {
	param([string]$RepoRoot, [string]$WtPath)
	$ghSrc = Join-Path $RepoRoot ".github"
	if (Test-Path $ghSrc) {
		return "xcopy `"$ghSrc`" `"$WtPath\.github`" /E /I /Y /Q >nul"
	}
	return ""
}

# Build upd.cmd call for tab scripts. Returns empty string if not found.
function Get-UpdCall {
	param([string]$WtRoot)
	$updCmd = Join-Path $WtRoot "upd.cmd"
	if (Test-Path $updCmd) {
		return "`"$updCmd`" full"
	}
	return ""
}