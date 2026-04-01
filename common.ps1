# Shared functions for git workflow scripts.
# Usage: . (Join-Path $PSScriptRoot "common.ps1")

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

# Resolve worktree root (.{repo}.wt) and target path for a branch.
# Uses Get-RepoRoot to preserve symlinks.
function Get-WtPath {
	param([string]$BranchName)
	$repoRoot   = Get-RepoRoot
	$repoName   = Split-Path $repoRoot -Leaf
	$wtRoot     = Join-Path (Split-Path $repoRoot -Parent) ".$repoName.wt"
	$folderName = $BranchName -replace "/", "_"
	return [PSCustomObject]@{
		WtRoot   = $wtRoot
		WtPath   = Join-Path $wtRoot $folderName
		RepoRoot = $repoRoot
	}
}

# Find the main worktree path (where .git is a directory, not a file).
# Tries .{repo}.wt naming convention first, then falls back to git worktree list.
function Get-MainWorktreePath {
	param([string]$RepoRoot)
	if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot }
	$gitEntry = Join-Path $RepoRoot ".git"

	# Already main worktree — .git is a directory
	if ([System.IO.Directory]::Exists($gitEntry)) { return $RepoRoot }

	# Worktree — .git is a file; try .{repo}.wt convention
	$wtDir  = Split-Path $RepoRoot -Parent
	$wtName = Split-Path $wtDir -Leaf
	if ($wtName -match '^\.(.*?)\.wt$') {
		$candidate = Join-Path (Split-Path $wtDir -Parent) $Matches[1]
		if ([System.IO.Directory]::Exists((Join-Path $candidate ".git"))) {
			return $candidate
		}
	}

	# Fallback: git worktree list
	$lines = git worktree list --porcelain 2>$null
	foreach ($line in $lines) {
		if ($line -match '^worktree (.+)') {
			$wt = $Matches[1].Trim()
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