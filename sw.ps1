param(
	[string]$Param1,
	[string]$Param2
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

# ---------------------------------------------------------
# Paths
# ---------------------------------------------------------
$GIT_BASE            = "C:\git"
$GITHUB_BASE         = "$GIT_BASE\GitHub"
$GITHUB_WTG_BASE     = "$GITHUB_BASE\WiseTechGlobal"
$GITHUB_WTG_PERSONAL = "$GITHUB_WTG_BASE\Personal"
$CargoWise           = "$GITHUB_WTG_BASE\CargoWise"

# ---------------------------------------------------------
# Aliases: name -> path
# ---------------------------------------------------------
$aliases = [ordered]@{
	"cw"             = $CargoWise
	"dev"            = $CargoWise
	"customs"        = "$GITHUB_WTG_BASE\CargoWise.Customs"
	"refdata"        = "$GIT_BASE\wtg\RefDataRepo\RefDataRepo"
	"shared"         = "$GITHUB_WTG_BASE\CargoWise.Shared"
	"devtools"       = "$GITHUB_WTG_BASE\DevTools"
	"db"             = "$GITHUB_WTG_BASE\CargoWise.Database"
	"scripts"        = "$GITHUB_WTG_PERSONAL\Scripts"
	"shared.old"     = "$GIT_BASE\wtg\CargoWise\Shared"
	"shared.refdata" = "$GIT_BASE\wtg\RefDataRepo\Shared"
	"review"         = "$GITHUB_BASE\Review\CargoWise"
}

# ---------------------------------------------------------
# Helpers
# ---------------------------------------------------------
function Set-LocationSafe([string]$Path) {
	if (Test-Path $Path) {
		Set-Location $Path
		return $true
	}
	Write-Host "Path not found: $Path" -ForegroundColor Red
	return $false
}

function Show-ActiveBranch {
	$b = git symbolic-ref --short HEAD 2>$null
	if ($b) {
		Write-Host "Active branch: " -ForegroundColor DarkGray -NoNewline
		Write-Host $b -ForegroundColor Cyan
	}
}

function Has-UncommittedChanges {
	$status = git status --porcelain 2>$null
	return ($null -ne $status -and $status.Trim() -ne "")
}

function Test-GitRepo([string]$Path) {
	$gitPath = Join-Path $Path ".git"
	return ([System.IO.File]::Exists($gitPath) -or [System.IO.Directory]::Exists($gitPath))
}

# ---------------------------------------------------------
# Recent repos config
# ---------------------------------------------------------
$recentConfigPath = Join-Path $PSScriptRoot "Configuration\RecentRepos.json"

function Get-RecentRepos([string]$Context) {
	if (-not (Test-Path $recentConfigPath)) { return @() }
	$map = Get-Content $recentConfigPath -Raw | ConvertFrom-Json -AsHashtable
	if ($map.ContainsKey($Context)) { return @($map[$Context]) }
	return @()
}

function Save-RecentRepo([string]$Context, [string]$RepoName) {
	$map = @{}
	if (Test-Path $recentConfigPath) {
		$map = Get-Content $recentConfigPath -Raw | ConvertFrom-Json -AsHashtable
	}
	$list = @($RepoName)
	if ($map.ContainsKey($Context)) {
		$list += @($map[$Context]) | Where-Object { $_ -ne $RepoName }
	}
	if ($list.Count -gt 10) { $list = $list[0..9] }
	$map[$Context] = $list

	$configDir = Join-Path $PSScriptRoot "Configuration"
	if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
	$map | ConvertTo-Json -Depth 3 | Set-Content $recentConfigPath -Encoding UTF8
}

# ---------------------------------------------------------
# Context detection
# ---------------------------------------------------------
function Get-RepoContext {
	$cwd = (Get-Location).Path

	# WiseTechGlobal\Personal (personal work projects)
	if ($cwd -match '^(.+\\GitHub)\\WiseTechGlobal\\Personal(\\|$)') {
		return @{
			Context   = "wtg-personal"
			RepoBase  = "$($Matches[1])\WiseTechGlobal\Personal"
			GitHubOrg = "AntonZhelezniakou-WTG"
		}
	}

	# WiseTechGlobal (org projects)
	if ($cwd -match '^(.+\\GitHub)\\WiseTechGlobal(\\|$)') {
		return @{
			Context   = "wtg"
			RepoBase  = "$($Matches[1])\WiseTechGlobal"
			GitHubOrg = "WiseTechGlobal"
		}
	}

	# GitHub\Personal (non-work personal projects)
	if ($cwd -match '^(.+\\GitHub)\\Personal(\\|$)') {
		return @{
			Context   = "personal"
			RepoBase  = "$($Matches[1])\Personal"
			GitHubOrg = "ZelAnton"
		}
	}

	# Default: WiseTechGlobal
	return @{
		Context   = "wtg"
		RepoBase  = $GITHUB_WTG_BASE
		GitHubOrg = "WiseTechGlobal"
	}
}

# ---------------------------------------------------------
# Scan local repos
# ---------------------------------------------------------
function Get-LocalRepos([string]$RepoBase) {
	if (-not (Test-Path $RepoBase)) { return @() }
	Get-ChildItem -Path $RepoBase -Directory |
		Where-Object { $_.Name -notmatch '^\.' -and $_.Name -ne 'Personal' } |
		Where-Object { Test-GitRepo $_.FullName } |
		ForEach-Object { $_.Name } |
		Sort-Object
}

# ---------------------------------------------------------
# Clone from GitHub
# ---------------------------------------------------------
function Invoke-CloneFromGitHub([string]$GitHubOrg, [string]$RepoBase, [string]$Context) {
	$ghCmd = Get-Command gh -ErrorAction SilentlyContinue
	if (-not $ghCmd) {
		Write-Host "GitHub CLI (gh) is required. Install from https://cli.github.com" -ForegroundColor Red
		Wait-AnyKey
		return $null
	}

	Write-Host "Fetching repos from $GitHubOrg..." -ForegroundColor Cyan
	$ErrorActionPreference = "Continue"
	$remoteRepos = gh repo list $GitHubOrg --limit 200 --json name -q ".[].name" 2>$null
	$ErrorActionPreference = "Stop"
	if (-not $remoteRepos) {
		Write-Host "No repos found or access denied." -ForegroundColor Red
		Wait-AnyKey
		return $null
	}

	# Exclude already cloned
	$localRepos = Get-LocalRepos $RepoBase
	$available = @($remoteRepos) | Where-Object { $localRepos -notcontains $_ } | Sort-Object
	if (-not $available) {
		Write-Host "All repos already cloned." -ForegroundColor Yellow
		Wait-AnyKey
		return $null
	}

	[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
	$selected = $available | fzf `
		--style=minimal --height=50% --no-info --layout=reverse `
		--pointer=">" --gutter=" " `
		--color="pointer:green,fg+:green:bold,bg+:-1" `
		--header="Clone from $GitHubOrg (Enter to clone, Esc to cancel):" `
		--header-first

	if (-not $selected) { return $null }

	$targetDir = Join-Path $RepoBase $selected
	$cloneScript = Join-Path $PSScriptRoot "clone.ps1"
	& $cloneScript -Repo "https://github.com/$GitHubOrg/$selected.git" -Directory $targetDir
	if ($LASTEXITCODE -ne 0) {
		Write-Host "Clone failed." -ForegroundColor Red
		Wait-AnyKey
		return $null
	}

	Save-RecentRepo $Context $selected
	return $targetDir
}

# ---------------------------------------------------------
# No-param mode: interactive repo selector
# ---------------------------------------------------------
if (-not $Param1) {
	$ctx = Get-RepoContext
	$context   = $ctx.Context
	$repoBase  = $ctx.RepoBase
	$githubOrg = $ctx.GitHubOrg

	$allRepos = Get-LocalRepos $repoBase
	$recent   = Get-RecentRepos $context | Where-Object { $allRepos -contains $_ }

	# Build fzf input: recent, separator, rest
	$separator = [string][char]0x2500 * 30
	$nonRecent = $allRepos | Where-Object { $recent -notcontains $_ }

	$fzfInput = @()
	if ($recent.Count -gt 0) {
		$fzfInput += $recent
		$fzfInput += $separator
	}
	$fzfInput += $nonRecent

	if ($fzfInput.Count -eq 0) {
		Write-Host "No repositories found in $repoBase" -ForegroundColor Yellow
		Write-Host "Press Ctrl+N to clone from GitHub." -ForegroundColor DarkGray
	}

	[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
	$output = $fzfInput | fzf `
		--style=minimal --height=50% --no-info --layout=reverse `
		--pointer=">" --gutter=" " `
		--color="pointer:green,fg+:green:bold,bg+:-1" `
		--header="Select repository (Ctrl+N: clone from $githubOrg):" `
		--header-first `
		--expect="ctrl-n"

	$lines = @($output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
	$key      = if ($lines.Count -ge 2) { $lines[0] } else { "" }
	$selected = if ($lines.Count -ge 2) { $lines[1] } elseif ($lines.Count -eq 1 -and $key -ne "ctrl-n") { $lines[0] } else { "" }

	# Handle Ctrl+N: clone from GitHub
	if ($key -eq "ctrl-n") {
		$clonedPath = Invoke-CloneFromGitHub $githubOrg $repoBase $context
		if ($clonedPath -and $env:WT_SESSION) {
			$tabTitle = Split-Path $clonedPath -Leaf
			wt --window 0 new-tab --title $tabTitle --startingDirectory $clonedPath cmd /k
		}
		exit 0
	}

	# Ignore separator selection or empty
	if (-not $selected -or $selected -match "^$([char]0x2500)+$") {
		exit 0
	}

	$targetPath = Join-Path $repoBase $selected
	if (-not (Test-Path $targetPath)) {
		Write-Host "Path not found: $targetPath" -ForegroundColor Red
		exit 1
	}

	Save-RecentRepo $context $selected

	if ($env:WT_SESSION) {
		wt --window 0 new-tab --title $selected --startingDirectory $targetPath cmd /k
	}
	exit 0
}

# ---------------------------------------------------------
# 1) Try param1 as alias
# ---------------------------------------------------------
$aliasFolder = $null
$branch      = $null

if ($aliases.Contains($Param1)) {
	$aliasFolder = $aliases[$Param1]
	if (-not (Set-LocationSafe $aliasFolder)) { exit 1 }
	$verb = if ($env:WT_SESSION) { "Opening" } else { "Switching to" }
	Write-Host "$verb repo: $aliasFolder"

	if ($Param2) {
		$branch = $Param2
	} else {
		if ($env:WT_SESSION) {
			wt --window 0 new-tab --title $Param1 --startingDirectory $aliasFolder cmd /k "git symbolic-ref --short HEAD"
		} else {
			Show-ActiveBranch
		}
		exit 0
	}
}

# ---------------------------------------------------------
# 2) Try param1 as absolute path, repo name, or branch
# ---------------------------------------------------------
if (-not $aliasFolder) {
	if ([System.IO.Path]::IsPathRooted($Param1) -and (Test-Path $Param1)) {
		# Absolute path
		if (-not (Set-LocationSafe $Param1)) { exit 1 }
		$verb = if ($env:WT_SESSION) { "Opening" } else { "Switching to" }
		Write-Host "${verb}: $Param1"

		if ($Param2) {
			$branch = $Param2
		} else {
			$folderTitle = Split-Path $Param1 -Leaf
			if ($env:WT_SESSION) {
				wt --window 0 new-tab --title $folderTitle --startingDirectory (Get-Location).Path cmd /k "git symbolic-ref --short HEAD"
			} else {
				Show-ActiveBranch
			}
			exit 0
		}
	} else {
		# Try as repo name in context-appropriate base directory
		$ctx = Get-RepoContext
		$candidatePath = Join-Path $ctx.RepoBase $Param1
		# Try with CargoWise. prefix for WiseTechGlobal repos
		$cwCandidatePath = Join-Path $ctx.RepoBase "CargoWise.$Param1"
		$resolvedName = $null

		if ((Test-Path $candidatePath) -and (Test-GitRepo $candidatePath)) {
			$resolvedName = (Get-Item $candidatePath).Name
		} elseif ($ctx.Context -eq "wtg" -and (Test-Path $cwCandidatePath) -and (Test-GitRepo $cwCandidatePath)) {
			$candidatePath = $cwCandidatePath
			$resolvedName = (Get-Item $cwCandidatePath).Name
		}

		if ($resolvedName) {
			$aliasFolder = $candidatePath
			if (-not (Set-LocationSafe $aliasFolder)) { exit 1 }
			Save-RecentRepo $ctx.Context $resolvedName
			$verb = if ($env:WT_SESSION) { "Opening" } else { "Switching to" }
			Write-Host "$verb repo: $aliasFolder"

			if ($Param2) {
				$branch = $Param2
			} else {
				$tabTitle = $resolvedName
				if ($env:WT_SESSION) {
					wt --window 0 new-tab --title $tabTitle --startingDirectory $aliasFolder cmd /k "git symbolic-ref --short HEAD"
				} else {
					Show-ActiveBranch
				}
				exit 0
			}
		} else {
			# Try to find on GitHub and offer to clone
			$ghCmd = Get-Command gh -ErrorAction SilentlyContinue
			$foundRemote = $false
			$remoteRepoName = $null
			if ($ghCmd) {
				# Try exact name first
				$ErrorActionPreference = "Continue"
				$realName = gh repo view "$($ctx.GitHubOrg)/$Param1" --json name -q ".name" 2>$null
				if ($LASTEXITCODE -eq 0 -and $realName) {
					$foundRemote = $true
					$remoteRepoName = $realName.Trim()
				} elseif ($ctx.Context -eq "wtg") {
					# Try with CargoWise. prefix
					$realName = gh repo view "$($ctx.GitHubOrg)/CargoWise.$Param1" --json name -q ".name" 2>$null
					if ($LASTEXITCODE -eq 0 -and $realName) {
						$foundRemote = $true
						$remoteRepoName = $realName.Trim()
					}
				}
				$ErrorActionPreference = "Stop"
			}

			if ($foundRemote) {
				$repoUrl = "https://github.com/$($ctx.GitHubOrg)/$remoteRepoName.git"
				$targetDir = Join-Path $ctx.RepoBase $remoteRepoName
				if (Confirm-Action "Repository '$remoteRepoName' not found locally. Clone from $($ctx.GitHubOrg)?") {
					$cloneScript = Join-Path $PSScriptRoot "clone.ps1"
					& $cloneScript -Repo $repoUrl -Directory $targetDir
					if ($LASTEXITCODE -ne 0) {
						Write-Host "Clone failed." -ForegroundColor Red
						Wait-AnyKey
						exit 1
					}
					Save-RecentRepo $ctx.Context $remoteRepoName
					$aliasFolder = $targetDir
					Set-Location $targetDir
					if ($Param2) {
						$branch = $Param2
					} else {
						if ($env:WT_SESSION) {
							wt --window 0 new-tab --title $remoteRepoName --startingDirectory $targetDir cmd /k
						}
						exit 0
					}
				} else {
					exit 0
				}
			} else {
				# Treat as branch name
				$branch = $Param1
			}
		}
	}
}

# ---------------------------------------------------------
# 3) Branch switch
# ---------------------------------------------------------
if (-not $branch) {
	Write-Host "You must specify a valid branch name." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

# Discard uncommitted changes if any
if (Has-UncommittedChanges) {
	Write-Host "Local changes detected:" -ForegroundColor Yellow
	git status --short
	Write-Host ""
	if (-not (Confirm-Action "Discard all uncommitted changes?")) {
		Write-Host "Operation aborted." -ForegroundColor Yellow
		exit 1
	}
	Write-Host "Discarding all uncommitted changes..." -ForegroundColor Cyan
	git reset --hard
	git clean -df
}

# ---------------------------------------------------------
# 4) Switch to branch
# ---------------------------------------------------------
$null = git rev-parse --verify $branch 2>$null
if ($LASTEXITCODE -ne 0) {
	Write-Host "Branch '$branch' does not exist locally. Attempting to check out from remote..." -ForegroundColor Cyan
	$ErrorActionPreference = "Continue"
	git checkout -b $branch origin/$branch
	$checkoutExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($checkoutExit -ne 0) {
		Write-Host "Error while checking out branch '$branch' from remote." -ForegroundColor Red
		Wait-AnyKey
		exit 1
	}
	Write-Host "Successfully checked out branch '$branch' from remote." -ForegroundColor Green
} else {
	$ErrorActionPreference = "Continue"
	git switch $branch --quiet
	if ($LASTEXITCODE -ne 0) {
		git checkout $branch
		if ($LASTEXITCODE -ne 0) {
			Write-Host "Error while switching to branch '$branch'." -ForegroundColor Red
			$ErrorActionPreference = "Stop"
			Wait-AnyKey
			exit 1
		}
	}
	$ErrorActionPreference = "Stop"
	Write-Host "Switched to branch '$branch'." -ForegroundColor Green
}

# ---------------------------------------------------------
# 5) Pull current branch (skip for master)
# ---------------------------------------------------------
if ($branch -ne "master" -and $branch -ne "main") {
	$pullScript = Join-Path $PSScriptRoot "pull.ps1"
	$ErrorActionPreference = "Continue"
	& $pullScript -WorkDir (Get-Location).Path
	$ErrorActionPreference = "Stop"
}

# ---------------------------------------------------------
# 6) Merge master into current branch (skip for master)
# ---------------------------------------------------------
if ($branch -ne "master" -and $branch -ne "main") {
	$mmScript = Join-Path $PSScriptRoot "mm.ps1"
	& $mmScript -WorkDir (Get-Location).Path
}

# ---------------------------------------------------------
# 7) Done — open new tab only
# ---------------------------------------------------------
$targetDir = if ($aliasFolder) { $aliasFolder } else { (Get-Location).Path }
$tabTitle  = if ($aliasFolder) { $Param1 } else { Split-Path $targetDir -Leaf }

Write-Host ""
Write-Host "Switched to branch '$branch'." -ForegroundColor Green
if ($aliasFolder) {
	Write-Host "Working directory: $aliasFolder"
}

if ($env:WT_SESSION) {
	wt --window 0 new-tab --title $tabTitle --startingDirectory $targetDir cmd /k
}
exit 0