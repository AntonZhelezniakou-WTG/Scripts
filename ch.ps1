param(
	[string]$WorkDir,
	[string]$Branch
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$UP   = [char]0x2191  # ↑
$DOWN = [char]0x2193  # ↓
$EQ   = [char]0x2261  # ≡

# Show a fzf menu of the current user's open PRs (authored, assigned, review-requested).
# Returns the branch name of the selected PR, or $null if cancelled.
function Select-PR {
	if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
		Write-Host "GitHub CLI (gh) is not installed. Install it from https://cli.github.com" -ForegroundColor Red
		Wait-AnyKey
		return $null
	}

	Write-Host "Fetching PRs..." -ForegroundColor DarkGray

	$ErrorActionPreference = "Continue"
	$authored = gh pr list --author "@me"           --state open --json number,title,headRefName,isDraft,comments 2>$null | ConvertFrom-Json
	$assigned = gh pr list --assignee "@me"         --state open --json number,title,headRefName,isDraft,comments 2>$null | ConvertFrom-Json
	$review   = gh pr list --review-requested "@me" --state open --json number,title,headRefName,isDraft,comments 2>$null | ConvertFrom-Json
	$ErrorActionPreference = "Stop"

	$allPRs = @($authored) + @($assigned) + @($review) |
		Where-Object { $_ -ne $null } |
		Group-Object number |
		ForEach-Object { $_.Group[0] }

	if (-not $allPRs) {
		Write-Host "No open PRs found." -ForegroundColor Yellow
		Wait-AnyKey
		return $null
	}

	$maxNumLen = ($allPRs | ForEach-Object { "#$($_.number)".Length } | Measure-Object -Maximum).Maximum

	$menuEntries = $allPRs | ForEach-Object {
		$num      = "#$($_.number)".PadRight($maxNumLen)
		$status   = if ($_.isDraft) { "[draft]" } else { "[open] " }
		$comments = if ($_.comments.totalCount -gt 0) { "($($_.comments.totalCount) comments)" } else { "              " }
		"$num  $status  $comments  $($_.title)"
	}

	$selected = $menuEntries | fzf `
		--style=minimal --no-input --disabled --height=50% --no-info --layout=reverse `
		--pointer=">" --gutter=" " `
		--color="pointer:green,fg+:green:bold,bg+:-1" `
		--header="Select PR (Enter to checkout):" `
		--header-first

	if (-not $selected) { return $null }

	$prNum = ($selected.Trim() -split "\s+")[0] -replace "^#", ""
	$pr    = $allPRs | Where-Object { $_.number -eq [int]$prNum } | Select-Object -First 1
	return $pr.headRefName
}

# Merge $SourceBranch into current branch with conflict resolution via GitExtensions.
function Invoke-MergeWithResolution {
	param([string]$SourceBranch)

	$currentBranch = git symbolic-ref --short HEAD 2>$null
	$gitExtensions = "C:\Program Files\GitExtensions\GitExtensions.exe"

	Write-Host ""
	Write-Host "Merge '$SourceBranch' into '$currentBranch'? [Y/n] " -ForegroundColor Cyan -NoNewline
	$key = [Console]::ReadKey($true)
	Write-Host $key.KeyChar
	if ($key.KeyChar -notmatch '^[Yy]$' -and $key.Key -ne 'Enter') {
		Write-Host "Cancelled." -ForegroundColor Yellow
		return
	}

	Write-Host ""
	Write-Host "== Merging '$SourceBranch' into '$currentBranch' ==" -ForegroundColor Cyan

	$ErrorActionPreference = "Continue"
	git merge $SourceBranch --no-edit --quiet --no-stat
	$mergeExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"

	if ($mergeExit -eq 0) {
		Write-Host "Merge completed successfully." -ForegroundColor Green
		return
	}

	Write-Host ""
	Write-Host "[warn] Merge conflicts detected." -ForegroundColor Yellow

	if (Test-Path $gitExtensions) {
		Write-Host "[info] Launching GitExtensions merge conflicts UI..." -ForegroundColor DarkGray
		& $gitExtensions mergeconflicts
	} else {
		Write-Host "[info] GitExtensions not found. Resolve conflicts manually." -ForegroundColor Yellow
	}

	while ($true) {
		Write-Host ""
		Write-Host "Conflicts resolved? [Y=continue / A=abort] " -ForegroundColor Yellow -NoNewline
		$k = [Console]::ReadKey($true)
		Write-Host $k.KeyChar

		if ($k.KeyChar -match '^[Aa]$') {
			Write-Host "[info] Aborting merge..." -ForegroundColor Yellow
			git merge --abort
			return
		}

		$unresolved = git status --porcelain 2>$null | Where-Object { $_ -match '^UU' }
		if ($unresolved) {
			Write-Host "[warn] Conflicts still present. Resolve them first." -ForegroundColor Yellow
			if (Test-Path $gitExtensions) { & $gitExtensions mergeconflicts }
			continue
		}

		$ErrorActionPreference = "Continue"
		git diff --cached --exit-code 2>$null
		$hasStagedChanges = $LASTEXITCODE -ne 0
		$ErrorActionPreference = "Stop"

		if ($hasStagedChanges) {
			$conflictFiles = (git diff --name-only --diff-filter=U 2>$null) -join ", "
			git add .
			git commit -m "Merged $SourceBranch. Conflicts resolved in: $conflictFiles"
			if ($LASTEXITCODE -ne 0) {
				Write-Host "Commit failed." -ForegroundColor Red
				return
			}
		}

		Write-Host "Merge committed successfully." -ForegroundColor Green
		return
	}
}

# Delete a branch by delegating to dd.ps1 which lives next to this script.
function Remove-Branch {
	param([string]$BranchName)

	if ($BranchName -eq "master" -or $BranchName -eq "main") {
		Write-Host "Cannot delete protected branch: $BranchName" -ForegroundColor Red
		Wait-AnyKey
		return
	}

	$ddPs1 = Join-Path $PSScriptRoot "dd.ps1"
	if (-not (Test-Path $ddPs1)) {
		Write-Host "Error: dd.ps1 not found next to ch.ps1" -ForegroundColor Red
		Wait-AnyKey
		return
	}

	& $ddPs1 -WorkDir $WorkDir -Target $BranchName
}

if ($WorkDir) { Set-Location $WorkDir }

# Validate git repository
git rev-parse --is-inside-work-tree 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
	Write-Host "Error: not a git repository." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

# If branch was passed as argument — handle it directly without menu
if ($Branch) {
	$worktreeBranches = git branch |
		Where-Object { $_.TrimStart().StartsWith("+") } |
		ForEach-Object { $_.Trim() -replace "^\+ ", "" }
	$localBranches = git branch |
		ForEach-Object { $_.Trim() -replace "^[*+] ", "" } |
		Where-Object { $_ -ne "" }

	$isLocal    = $localBranches -contains $Branch
	$isWorktree = $worktreeBranches -contains $Branch

	if ($isWorktree) {
		$wt = Get-WtPath $Branch
		if ($env:WT_SESSION) {
			$safeLabel = $Branch -replace "/", "_"
			$tabScript = Join-Path $env:TEMP "git-wt-tab-${safeLabel}.cmd"
			$wtPathStr = $wt.WtPath
			@"
@echo off
cd /d "$wtPathStr"
git fetch origin "${Branch}:refs/remotes/origin/${Branch}"
echo.
echo == Worktree: $Branch ==
echo.
cmd /k
"@ | Set-Content $tabScript -Encoding ASCII
			wt --window 0 new-tab --title $Branch --startingDirectory $wt.WtPath cmd /k $tabScript
			Write-Host "Opened WT tab for worktree: $Branch" -ForegroundColor Cyan
		} else {
			Ensure-FetchRefspec $Branch
			Fetch-Branch $Branch
			Write-Host ""
			Write-Host "  Worktree path: $($wt.WtPath)" -ForegroundColor Cyan
			Write-Host "  Run: cd `"$($wt.WtPath)`"" -ForegroundColor Cyan
			Write-Host ""
		}
		exit 0
	}

	if ($isLocal) {
		git checkout $Branch
		exit $LASTEXITCODE
	}

	$remoteRef = git ls-remote --heads origin $Branch | Select-Object -First 1
	if (-not $remoteRef) {
		Write-Host "Error: branch '$Branch' not found on origin." -ForegroundColor Red
		Wait-AnyKey
		exit 1
	}

	if (-not (Ensure-Fzf)) { Wait-AnyKey; exit 1 }

	$options = @("Create worktree", "Plain checkout")
	$choice  = Invoke-Fzf -Entries $options -ExtraArgs @("--pointer=>", "--color=pointer:green,fg+:green:bold,bg+:-1")
	if (-not $choice) { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }

	$useWorktree = $choice.Trim() -eq $options[0]
	Ensure-FetchRefspec $Branch
	Fetch-Branch $Branch

	if ($useWorktree) {
		$wt = Get-WtPath $Branch
		Write-Host "== Creating worktree at '$($wt.WtPath)' =="
		if (-not (Test-Path $wt.WtRoot)) { New-Item -ItemType Directory -Path $wt.WtRoot | Out-Null }
		$updCall    = Get-UpdCall $wt.WtRoot
		$copyGhLine = Get-CopyGitHubLine $wt.RepoRoot $wt.WtPath
		if ($env:WT_SESSION) {
			$safeLabel = $Branch -replace "/", "_"
			$tabScript = Join-Path $env:TEMP "git-wt-tab-${safeLabel}.cmd"
			$wtPathStr = $wt.WtPath
			$repoRoot  = $wt.RepoRoot
			$updLine   = if ($updCall) { $updCall } else { "echo [info] No upd.cmd found for this repo, skipping." }
			@"
@echo off
git worktree add --track -b "$Branch" "$wtPathStr" "origin/$Branch"
if errorlevel 1 ( echo git worktree add failed. & pause & exit /b 1 )
$copyGhLine
cd /d "$wtPathStr"
$updLine
echo.
echo == Changes relative to master ==
echo.
changes
"@ | Set-Content $tabScript -Encoding ASCII
			wt --window 0 new-tab --title $Branch --startingDirectory $repoRoot cmd /k $tabScript
		} else {
			git worktree add --track -b $Branch $wt.WtPath "origin/$Branch"
			Copy-GitHubFolder $wt.RepoRoot $wt.WtPath
			$updCmd = Join-Path $wt.WtRoot "upd.cmd"
			if (Test-Path $updCmd) {
				Write-Host "Running upd.cmd..." -ForegroundColor DarkGray
				Push-Location $wt.WtPath
				& cmd /c $updCmd full
				Pop-Location
			}
		}
	} else {
		Write-Host "== Checking out '$Branch' from origin =="
		git checkout -b $Branch "origin/$Branch"
	}
	exit $LASTEXITCODE
}

# No branch specified — show interactive menu
if (-not (Ensure-Fzf)) { Wait-AnyKey; exit 1 }

while ($true) {
	$worktreeBranches = git branch |
		Where-Object { $_.TrimStart().StartsWith("+") } |
		ForEach-Object { $_.Trim() -replace "^\+ ", "" }
	$localBranches = git branch |
		ForEach-Object { $_.Trim() -replace "^[*+] ", "" } |
		Where-Object { $_ -ne "" }
	$wtSet         = $worktreeBranches
	$currentBranch = git symbolic-ref --short HEAD 2>$null
	$baseBranch    = $localBranches | Where-Object { $_ -eq "master" -or $_ -eq "main" } | Select-Object -First 1

	$rawEntries = @()
	if ($PSVersionTable.PSVersion.Major -ge 7) {
		$rawEntries = $localBranches | ForEach-Object -Parallel {
			$b         = $_
			$currentB  = $using:currentBranch
			$baseB     = $using:baseBranch
			$UP        = $using:UP
			$DOWN      = $using:DOWN
			$EQ        = $using:EQ
			$isCurrent = $b -eq $currentB
			$isWt      = $using:wtSet -contains $b
			$marker    = if ($isCurrent) { "*" } elseif ($isWt) { "+" } else { " " }

			$ErrorActionPreference = "Continue"

			$syncOrigin = ""
			$hasOrigin  = git rev-parse --verify "refs/remotes/origin/${b}" 2>$null
			if ($LASTEXITCODE -eq 0) {
				$ab = git rev-list --left-right --count "refs/remotes/origin/${b}...${b}" 2>$null
				if ($ab -match "^\s*(\d+)\s+(\d+)\s*$") {
					$behind = [int]$Matches[1]; $ahead = [int]$Matches[2]
					$syncOrigin = if ($ahead -gt 0 -and $behind -gt 0) { "ORIGIN: ${UP}${ahead} ${DOWN}${behind}" }
					              elseif ($ahead  -gt 0)               { "ORIGIN: ${UP}${ahead}"                  }
					              elseif ($behind -gt 0)               { "ORIGIN: ${DOWN}${behind}"               }
					              else                                  { "ORIGIN: ${EQ}"                          }
				}
			} else { $syncOrigin = "ORIGIN: n/a" }

			$syncBase = ""
			if ($baseB -and $b -ne $baseB) {
				$ab2 = git rev-list --left-right --count "${baseB}...${b}" 2>$null
				if ($ab2 -match "^\s*(\d+)\s+(\d+)\s*$") {
					$behind2 = [int]$Matches[1]; $ahead2 = [int]$Matches[2]
					$syncBase = if ($ahead2 -gt 0 -and $behind2 -gt 0) { "from ${baseB}: ${UP}${ahead2} ${DOWN}${behind2}" }
					            elseif ($ahead2  -gt 0)                { "from ${baseB}: ${UP}${ahead2}"                   }
					            elseif ($behind2 -gt 0)                { "from ${baseB}: ${DOWN}${behind2}"                }
					            else                                   { "from ${baseB}: ${EQ}"                             }
				}
			}

			$dirtyStr = ""
			if ($isCurrent) {
				if (git status --porcelain --ignored=no 2>$null) { $dirtyStr = " [dirty]" }
			}

			[PSCustomObject]@{ Marker = $marker; Branch = $b; SyncOrigin = $syncOrigin; SyncBase = $syncBase; Dirty = $dirtyStr }
		} -ThrottleLimit 8
	} else {
		$rawEntries = $localBranches | ForEach-Object {
			$b         = $_
			$isCurrent = $b -eq $currentBranch
			$isWt      = $wtSet -contains $b
			$marker    = if ($isCurrent) { "*" } elseif ($isWt) { "+" } else { " " }

			$ErrorActionPreference = "Continue"

			$syncOrigin = ""
			$hasOrigin  = git rev-parse --verify "refs/remotes/origin/${b}" 2>$null
			if ($LASTEXITCODE -eq 0) {
				$ab = git rev-list --left-right --count "refs/remotes/origin/${b}...${b}" 2>$null
				if ($ab -match "^\s*(\d+)\s+(\d+)\s*$") {
					$behind = [int]$Matches[1]; $ahead = [int]$Matches[2]
					$syncOrigin = if ($ahead -gt 0 -and $behind -gt 0) { "ORIGIN: ${UP}${ahead} ${DOWN}${behind}" }
					              elseif ($ahead  -gt 0)               { "ORIGIN: ${UP}${ahead}"                  }
					              elseif ($behind -gt 0)               { "ORIGIN: ${DOWN}${behind}"               }
					              else                                  { "ORIGIN: ${EQ}"                          }
				}
			} else { $syncOrigin = "ORIGIN: n/a" }

			$syncBase = ""
			if ($baseBranch -and $b -ne $baseBranch) {
				$ab2 = git rev-list --left-right --count "${baseBranch}...${b}" 2>$null
				if ($ab2 -match "^\s*(\d+)\s+(\d+)\s*$") {
					$behind2 = [int]$Matches[1]; $ahead2 = [int]$Matches[2]
					$syncBase = if ($ahead2 -gt 0 -and $behind2 -gt 0) { "from ${baseBranch}: ${UP}${ahead2} ${DOWN}${behind2}" }
					            elseif ($ahead2  -gt 0)                { "from ${baseBranch}: ${UP}${ahead2}"                   }
					            elseif ($behind2 -gt 0)                { "from ${baseBranch}: ${DOWN}${behind2}"                }
					            else                                   { "from ${baseBranch}: ${EQ}"                             }
				}
			}

			$dirtyStr = ""
			if ($isCurrent) {
				if (git status --porcelain --ignored=no 2>$null) { $dirtyStr = " [dirty]" }
			}

			[PSCustomObject]@{ Marker = $marker; Branch = $b; SyncOrigin = $syncOrigin; SyncBase = $syncBase; Dirty = $dirtyStr }
		}
	}

	$maxLen     = ($rawEntries | ForEach-Object { $_.Branch.Length   } | Measure-Object -Maximum).Maximum
	$maxBaseLen = ($rawEntries | ForEach-Object { $_.SyncBase.Length } | Measure-Object -Maximum).Maximum

	$sortedEntries = $rawEntries | Sort-Object {
		if ($_.Marker -eq "*") { 0 }
		elseif ($_.Branch -eq "master" -or $_.Branch -eq "main") { 1 }
		elseif ($_.Marker -eq "+") { 2 }
		else { 3 }
	}, Branch

	$esc    = [char]27
	$yellow = "$esc[93m"
	$bold   = "$esc[1m"
	$reset  = "$esc[0m"

	$menuEntries = $sortedEntries | ForEach-Object {
		$padded  = $_.Branch.PadRight($maxLen)
		$padBase = $_.SyncBase.PadRight($maxBaseLen)
		$line    = "$($_.Marker) $padded    $padBase    $($_.SyncOrigin)$($_.Dirty)"
		if ($_.Marker -eq "*") { "${bold}${yellow}${line}${reset}" } else { $line }
	}

	$lines = $menuEntries | fzf `
		--style=minimal --no-input --disabled --height=40% --no-info --layout=reverse `
		--pointer=">" --gutter=" " `
		--color="pointer:green,fg+:green:bold,bg+:-1" `
		--ansi `
		--header="Select branch or worktree (Del=delete, +=PRs, m=merge into current, Esc=quit):" `
		--header-first `
		--expect="del,+,esc,m"

	if (-not $lines) { exit 0 }

	$keyUsed        = $lines[0].Trim()
	$rawLine        = if ($lines.Count -gt 1) { $lines[1].Trim() } else { "" }
	$branchSelected = $rawLine -replace "^[*+ ] ", "" -replace "\s{2,}.*$", ""

	if ($keyUsed -eq "esc") { exit 0 }

	if ($keyUsed -eq "m") {
		if ($branchSelected) {
			Invoke-MergeWithResolution -SourceBranch $branchSelected
			Wait-AnyKey
		}
		continue
	}

	if ($keyUsed -eq "+") {
		$prBranch = Select-PR
		if (-not $prBranch) { continue }
		$branchSelected = $prBranch
	}

	if (-not $branchSelected) { continue }

	if ($keyUsed -eq "del") {
		Remove-Branch -BranchName $branchSelected
		$ErrorActionPreference = "Continue"
		git worktree prune 2>$null
		$ErrorActionPreference = "Stop"
		continue
	}

	# --- Act on selected branch ---
	$isLocal    = $localBranches -contains $branchSelected
	$isWorktree = $worktreeBranches -contains $branchSelected

	if ($isWorktree) {
		$wt = Get-WtPath $branchSelected
		if ($env:WT_SESSION) {
			$safeLabel = $branchSelected -replace "/", "_"
			$tabScript = Join-Path $env:TEMP "git-wt-tab-${safeLabel}.cmd"
			$wtPathStr = $wt.WtPath
			@"
@echo off
cd /d "$wtPathStr"
git fetch origin "${branchSelected}:refs/remotes/origin/${branchSelected}"
echo.
echo == Worktree: $branchSelected ==
echo.
cmd /k
"@ | Set-Content $tabScript -Encoding ASCII
			wt --window 0 new-tab --title $branchSelected --startingDirectory $wt.WtPath cmd /k $tabScript
			Write-Host "Opened WT tab for worktree: $branchSelected" -ForegroundColor Cyan
		} else {
			Ensure-FetchRefspec $branchSelected
			Fetch-Branch $branchSelected
			Write-Host ""
			Write-Host "  Worktree path: $($wt.WtPath)" -ForegroundColor Cyan
			Write-Host "  Run: cd `"$($wt.WtPath)`"" -ForegroundColor Cyan
			Write-Host ""
		}
		exit 0
	}

	if ($isLocal) {
		git checkout $branchSelected
		exit $LASTEXITCODE
	}

	# Branch not local — check remote
	$remoteRef = git ls-remote --heads origin $branchSelected | Select-Object -First 1
	if (-not $remoteRef) {
		Write-Host "Error: branch '$branchSelected' not found on origin." -ForegroundColor Red
		Wait-AnyKey
		continue
	}

	Write-Host ""
	Write-Host "Branch '$branchSelected' does not exist locally." -ForegroundColor Cyan
	Write-Host ""

	$options = @("Create worktree", "Plain checkout")
	$choice  = Invoke-Fzf -Entries $options -ExtraArgs @("--pointer=>", "--color=pointer:green,fg+:green:bold,bg+:-1")

	if (-not $choice) { continue }

	$useWorktree = $choice.Trim() -eq $options[0]
	Ensure-FetchRefspec $branchSelected
	Fetch-Branch $branchSelected

	if ($useWorktree) {
		$wt = Get-WtPath $branchSelected
		Write-Host "== Creating worktree at '$($wt.WtPath)' =="
		if (-not (Test-Path $wt.WtRoot)) { New-Item -ItemType Directory -Path $wt.WtRoot | Out-Null }
		$updCall    = Get-UpdCall $wt.WtRoot
		$copyGhLine = Get-CopyGitHubLine $wt.RepoRoot $wt.WtPath
		if ($env:WT_SESSION) {
			$safeLabel = $branchSelected -replace "/", "_"
			$tabScript = Join-Path $env:TEMP "git-wt-tab-${safeLabel}.cmd"
			$wtPathStr = $wt.WtPath
			$repoRoot  = $wt.RepoRoot
			$updLine   = if ($updCall) { $updCall } else { "echo [info] No upd.cmd found for this repo, skipping." }
			@"
@echo off
git worktree add --track -b "$branchSelected" "$wtPathStr" "origin/$branchSelected"
if errorlevel 1 ( echo git worktree add failed. & pause & exit /b 1 )
$copyGhLine
cd /d "$wtPathStr"
$updLine
echo.
echo == Changes relative to master ==
echo.
changes
"@ | Set-Content $tabScript -Encoding ASCII
			wt --window 0 new-tab --title $branchSelected --startingDirectory $repoRoot cmd /k $tabScript
		} else {
			git worktree add --track -b $branchSelected $wt.WtPath "origin/$branchSelected"
			Copy-GitHubFolder $wt.RepoRoot $wt.WtPath
			$updCmd = Join-Path $wt.WtRoot "upd.cmd"
			if (Test-Path $updCmd) {
				Write-Host "Running upd.cmd..." -ForegroundColor DarkGray
				Push-Location $wt.WtPath
				& cmd /c $updCmd full
				Pop-Location
			}
		}
	} else {
		Write-Host "== Checking out '$branchSelected' from origin =="
		git checkout -b $branchSelected "origin/$branchSelected"
	}
	exit $LASTEXITCODE
}