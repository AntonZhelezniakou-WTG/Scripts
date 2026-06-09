param(
	[string]$WorkDir,
	[string]$Branch
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common\common.ps1")

$UP   = [char]0x2191  # ↑
$DOWN = [char]0x2193  # ↓
$EQ   = [char]0x2261  # ≡

# Parse a (possibly "dirty") GitHub PR URL or a bare #number and resolve it to the PR's
# head branch in the CURRENT repo. Returns the branch name, or $null on any problem.
# Handles trailing junk like ".../pull/50428/changes#diff-abc123".
function Resolve-PrInput {
	param([string]$Raw)

	$owner = $null; $repo = $null; $num = $null
	if ($Raw -match 'github\.com/([^/]+)/([^/]+)/pull/(\d+)') {
		$owner = $Matches[1]; $repo = $Matches[2]; $num = $Matches[3]
	} elseif ($Raw -match '^#?(\d+)$') {
		$num = $Matches[1]
	} else {
		Write-Host "Not a GitHub PR URL or number: $Raw" -ForegroundColor Red
		Wait-AnyKey
		return $null
	}

	# Current repo slug (same parse as Get-WtPath in common.ps1).
	$ErrorActionPreference = "Continue"
	$remoteUrl = git remote get-url origin 2>$null
	$ErrorActionPreference = "Stop"
	$currentSlug = if ($remoteUrl -match 'github\.com[/:](.+?)(?:\.git)?\s*$') { $Matches[1].Trim() } else { $null }

	# Only the current repo is supported — warn if the URL points elsewhere.
	if ($owner -and $repo -and $currentSlug -and "$owner/$repo" -ine $currentSlug) {
		Write-Host "PR $owner/$repo#$num is in another repo (you're in $currentSlug)." -ForegroundColor Yellow
		Write-Host "Open that repo first, then use '+' there." -ForegroundColor Yellow
		Wait-AnyKey
		return $null
	}

	Write-Host "Resolving PR #$num..." -ForegroundColor DarkGray
	$ErrorActionPreference = "Continue"
	$repoArgs = if ($owner -and $repo) { @("--repo", "$owner/$repo") } else { @() }
	$json = gh pr view $num @repoArgs --json number,title,headRefName,state,isCrossRepository 2>$null | ConvertFrom-Json
	$ErrorActionPreference = "Stop"

	if (-not $json) {
		Write-Host "PR #$num not found (or gh not authenticated)." -ForegroundColor Red
		Wait-AnyKey
		return $null
	}
	if ($json.isCrossRepository) {
		# Head branch lives on a fork, not on origin — the checkout flow below can't reach it.
		Write-Host "PR #$num comes from a fork; its branch isn't on origin. Not supported." -ForegroundColor Yellow
		Wait-AnyKey
		return $null
	}
	if ($json.state -ne "OPEN") {
		Write-Host "Note: PR #$num is $($json.state)." -ForegroundColor DarkYellow
	}
	return $json.headRefName
}

# Show a fzf menu of the current user's open PRs (authored, assigned, review-requested).
# Lets the user select a PR, or paste an arbitrary GitHub PR URL / #number to open it.
# Returns the branch name to act on, or $null if cancelled.
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

	$menuEntries = @()
	if ($allPRs) {
		$maxNumLen = ($allPRs | ForEach-Object { "#$($_.number)".Length } | Measure-Object -Maximum).Maximum
		$menuEntries = $allPRs | ForEach-Object {
			$num      = "#$($_.number)".PadRight($maxNumLen)
			$status   = if ($_.isDraft) { "[draft]" } else { "[open] " }
			$comments = if ($_.comments.totalCount -gt 0) { "($($_.comments.totalCount) comments)" } else { "              " }
			"$num  $status  $comments  $($_.title)"
		}
	}

	$header = if ($allPRs) {
		"Select a PR (Enter), or paste a GitHub PR URL / #number, then Enter (Esc=cancel):"
	} else {
		"No PRs of yours. Paste a GitHub PR URL / #number, then Enter (Esc=cancel):"
	}

	# --print-query lets the user type a PR URL/number even when it matches no list entry.
	$out = $menuEntries | fzf `
		--print-query `
		--style=minimal --height=50% --no-info --layout=reverse `
		--pointer=">" --gutter=" " `
		--color="pointer:green,fg+:green:bold,bg+:-1" `
		--header=$header `
		--header-first
	$code = $LASTEXITCODE

	# 130 = Esc/Ctrl-C -> cancel; 0 = a list entry was selected; 1 = query typed with no match.
	if ($code -eq 130) { return $null }

	if ($code -eq 0) {
		$selectedLine = "$($out | Select-Object -Last 1)"
		$prNum = ($selectedLine.Trim() -split "\s+")[0] -replace "^#", ""
		$pr    = $allPRs | Where-Object { $_.number -eq [int]$prNum } | Select-Object -First 1
		return $pr.headRefName
	}

	# Typed text (URL or number) — first output line is always the raw query.
	$query = "$($out | Select-Object -First 1)".Trim()
	if (-not $query) { return $null }
	return (Resolve-PrInput $query)
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

# Delete a branch by delegating to delete.ps1 which lives next to this script.
function Remove-Branch {
	param([string]$BranchName)

	if ($BranchName -eq "master" -or $BranchName -eq "main") {
		Write-Host "Cannot delete protected branch: $BranchName" -ForegroundColor Red
		Wait-AnyKey
		return
	}

	$ddPs1 = Join-Path $PSScriptRoot "delete.ps1"
	if (-not (Test-Path $ddPs1)) {
		Write-Host "Error: delete.ps1 not found next to branches.ps1" -ForegroundColor Red
		Wait-AnyKey
		return
	}

	& $ddPs1 -WorkDir $WorkDir -Target $BranchName
}

function Find-SiblingRepo {
	param([string]$Suffix)
	$repoRoot = git rev-parse --show-toplevel 2>$null
	if (-not $repoRoot) { return $null }
	$repoName  = Split-Path $repoRoot -Leaf
	$parentDir = Split-Path $repoRoot -Parent
	$candidate = Get-ChildItem -Path $parentDir -Directory -ErrorAction SilentlyContinue |
		Where-Object { $_.Name -ieq "$repoName.$Suffix" } |
		Select-Object -First 1
	if ($candidate) { return $candidate.FullName }
	return $null
}

function Open-SiblingRepo {
	param([string]$RepoPath, [string]$Label)
	if ($env:WT_SESSION) {
		wt --window 0 new-tab --title $Label --startingDirectory $RepoPath pwsh -NoLogo
		Write-Host "Opened tab: $RepoPath" -ForegroundColor Cyan
	} else {
		Write-Host "Found: $RepoPath" -ForegroundColor Cyan
		Write-Host "Run: cd `"$RepoPath`"" -ForegroundColor Cyan
	}
}

# ── jj backend ───────────────────────────────────────────────────────────────

# Switch onto a bookmark: start a fresh change on top of it (the usual jj
# "checkout"). Resolves a remote-only bookmark by cloning it locally first.
function Switch-JjBookmark {
	param([string]$Name)
	$root = Get-JjRoot
	if ($root) { Set-Location $root }

	if ((Get-JjBookmarks) -notcontains $Name) {
		$ErrorActionPreference = "Continue"; jj git fetch --branch $Name 2>&1 | Out-Null; $ErrorActionPreference = "Stop"
		if (Test-JjRevExists "$Name@origin") {
			$ErrorActionPreference = "Continue"; jj bookmark create $Name -r "$Name@origin"; $ErrorActionPreference = "Stop"
			Ensure-JjFetchRefspec $Name
		} else {
			Write-Host "Error: bookmark '$Name' not found locally or on origin." -ForegroundColor Red
			Wait-AnyKey
			return
		}
	}

	Write-Host ""
	Write-Host "== Starting new change on '$Name' ==" -ForegroundColor Cyan
	$ErrorActionPreference = "Continue"
	# No 2>&1: jj prints status to stderr; merging it into the success stream makes
	# PowerShell render it red as if it were an error.
	jj new $Name | Out-Host
	$ErrorActionPreference = "Stop"
}

# Merge a bookmark into the current change (jj new with two parents).
function Invoke-JjMerge {
	param([string]$Source)
	if (-not (Confirm-Action "Merge '$Source' into the current change?")) { return }
	$ErrorActionPreference = "Continue"
	jj new -m "Merge $Source" '@' $Source
	$rc = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($rc -ne 0) { Write-Host "Merge failed." -ForegroundColor Red; return }
	if (Test-JjHasConflicts) {
		Write-Host "Merge produced conflicts. Resolve with 'jj resolve', or undo with 'jj op undo'." -ForegroundColor Yellow
	} else {
		Write-Host "Merged '$Source'." -ForegroundColor Green
	}
}

# Interactive bookmark menu: list with origin/base sync, switch / delete / merge / PR.
function Invoke-JjBranches {
	param([string]$Branch)
	$root = Get-JjRoot
	if ($root) { Set-Location $root }

	if ($Branch) { Switch-JjBookmark $Branch; exit 0 }

	if (-not (Ensure-Fzf)) { Wait-AnyKey; exit 1 }

	while ($true) {
		$bookmarks = @(Get-JjBookmarks)
		if ($bookmarks.Count -eq 0) {
			Write-Host "No bookmarks. Use 'commit' or 'create' to make one." -ForegroundColor Yellow
			exit 0
		}
		$onWc = @(Get-JjBookmarkOnWorkingCopy)
		$base = Get-JjBaseBookmark
		# Resolvable ref for base-sync revsets (local bookmark, else its remote).
		$baseRef = if (-not $base) { $null }
		           elseif ($bookmarks -contains $base) { $base }
		           elseif (Test-JjRevExists "$base@origin") { "$base@origin" }
		           else { $null }

		$rawEntries = @(foreach ($b in $bookmarks) {
			$marker = if ($onWc -contains $b) { "*" } else { " " }

			$syncOrigin = "ORIGIN: n/a"
			if (Test-JjRevExists "$b@origin") {
				$ahead  = Get-JjRevCount "$b@origin..$b"
				$behind = Get-JjRevCount "$b..$b@origin"
				$syncOrigin = if ($ahead -gt 0 -and $behind -gt 0) { "ORIGIN: ${UP}${ahead} ${DOWN}${behind}" }
				              elseif ($ahead  -gt 0) { "ORIGIN: ${UP}${ahead}" }
				              elseif ($behind -gt 0) { "ORIGIN: ${DOWN}${behind}" }
				              else { "ORIGIN: ${EQ}" }
			}

			$syncBase = ""
			if ($baseRef -and $b -ne $base) {
				$ahead2  = Get-JjRevCount "$baseRef..$b"
				$behind2 = Get-JjRevCount "$b..$baseRef"
				$syncBase = if ($ahead2 -gt 0 -and $behind2 -gt 0) { "from ${base}: ${UP}${ahead2} ${DOWN}${behind2}" }
				            elseif ($ahead2  -gt 0) { "from ${base}: ${UP}${ahead2}" }
				            elseif ($behind2 -gt 0) { "from ${base}: ${DOWN}${behind2}" }
				            else { "from ${base}: ${EQ}" }
			}

			[PSCustomObject]@{ Marker = $marker; Branch = $b; SyncOrigin = $syncOrigin; SyncBase = $syncBase }
		})

		$maxLen     = ($rawEntries | ForEach-Object { $_.Branch.Length   } | Measure-Object -Maximum).Maximum
		$maxBaseLen = ($rawEntries | ForEach-Object { $_.SyncBase.Length } | Measure-Object -Maximum).Maximum

		$sortedEntries = $rawEntries | Sort-Object {
			if ($_.Marker -eq "*") { 0 }
			elseif ($_.Branch -in @('main', 'master')) { 1 }
			else { 2 }
		}, Branch

		$esc = [char]27; $yellow = "$esc[93m"; $bold = "$esc[1m"; $reset = "$esc[0m"
		$menuEntries = $sortedEntries | ForEach-Object {
			$padded  = $_.Branch.PadRight($maxLen)
			$padBase = $_.SyncBase.PadRight($maxBaseLen)
			$line    = "$($_.Marker) $padded    $padBase    $($_.SyncOrigin)"
			if ($_.Marker -eq "*") { "${bold}${yellow}${line}${reset}" } else { $line }
		}

		$lines = $menuEntries | fzf `
			--style=minimal --height=40% --no-info --layout=reverse `
			--pointer=">" --gutter=" " `
			--color="pointer:green,fg+:green:bold,bg+:-1" `
			--ansi `
			--header="Select bookmark (Del=delete, +=PRs/URL, m=merge into current, Esc=quit):" `
			--header-first `
			--expect="del,+,esc,m"

		if (-not $lines) { exit 0 }
		$keyUsed        = $lines[0].Trim()
		$rawLine        = if ($lines.Count -gt 1) { $lines[1].Trim() } else { "" }
		$branchSelected = $rawLine -replace "^[*+ ] ", "" -replace "\s{2,}.*$", ""

		if ($keyUsed -eq "esc") { exit 0 }

		if ($keyUsed -eq "m") {
			if ($branchSelected) { Invoke-JjMerge $branchSelected; Wait-AnyKey }
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
			continue
		}

		Switch-JjBookmark $branchSelected
		exit 0
	}
}

$WorkDir, $Branch = Resolve-WorkDirArg $WorkDir $Branch
if ($WorkDir) { Set-Location $WorkDir }

# Validate repository
$script:VcsBackend = Get-VcsBackend
if (-not $script:VcsBackend) {
	Write-Host "Error: not a repository." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}
if ($script:VcsBackend -eq 'jj') { Invoke-JjBranches -Branch $Branch; exit 0 }

# Handle empty repo (no commits yet)
$hasCommits = git rev-parse HEAD 2>$null
if ($LASTEXITCODE -ne 0) {
	$branchName = Select-InitialBranch
	if (-not $branchName) { exit 0 }
	$ok = Initialize-EmptyRepoBranch $branchName
	if (-not $ok) { Wait-AnyKey; exit 1 }
	exit 0
}

# If branch was passed as argument — handle it directly without menu
if ($Branch) {
	$localBranches    = Get-LocalBranches
	$worktreeBranches = Get-WorktreeBranches

	$isLocal    = $localBranches -contains $Branch
	$isWorktree = $worktreeBranches -contains $Branch

	if ($isWorktree) {
		$wtPath = Get-ExistingWtPath $Branch
		if ($env:WT_SESSION) {
			$safeLabel = $Branch -replace "/", "_"
			$tabScript = Join-Path $env:TEMP "git-wt-tab-${safeLabel}.ps1"
			@"
Set-Location -LiteralPath '$wtPath'
git fetch origin '${Branch}:refs/remotes/origin/${Branch}'
Write-Host ''
Write-Host '== Worktree: $Branch =='
Write-Host ''
"@ | Set-Content $tabScript -Encoding UTF8
			wt --window 0 new-tab --title $Branch --startingDirectory $wtPath pwsh -NoLogo -NoExit -File $tabScript
			Write-Host "Opened WT tab for worktree: $Branch" -ForegroundColor Cyan
		} else {
			Ensure-FetchRefspec $Branch
			Fetch-Branch $Branch
			Write-Host ""
			Write-Host "  Worktree path: $wtPath" -ForegroundColor Cyan
			Write-Host "  Run: cd `"$wtPath`"" -ForegroundColor Cyan
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
		$sibling = Find-SiblingRepo $Branch
		if ($sibling) {
			Open-SiblingRepo -RepoPath $sibling -Label $Branch
			exit 0
		}
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
		$copyGhLine = Get-CopyGitHubLine $wt.RepoRoot $wt.WtPath
		if ($env:WT_SESSION) {
			$safeLabel = $Branch -replace "/", "_"
			$tabScript = Join-Path $env:TEMP "git-wt-tab-${safeLabel}.ps1"
			$wtPathStr = $wt.WtPath
			$repoRoot  = $wt.RepoRoot
			@"
git worktree add --track -b '$Branch' '$wtPathStr' 'origin/$Branch'
if (`$LASTEXITCODE -ne 0) { Write-Host 'git worktree add failed.' -ForegroundColor Red; Read-Host 'Press Enter to exit'; exit 1 }
$copyGhLine
Set-Location -LiteralPath '$wtPathStr'
Write-Host ''
Write-Host '== Changes relative to master =='
Write-Host ''
changes
"@ | Set-Content $tabScript -Encoding UTF8
			wt --window 0 new-tab --title $Branch --startingDirectory $repoRoot pwsh -NoLogo -NoExit -File $tabScript
		} else {
			git worktree add --track -b $Branch $wt.WtPath "origin/$Branch"
			Copy-GitHubFolder $wt.RepoRoot $wt.WtPath
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
	$localBranches    = Get-LocalBranches
	$worktreeBranches = Get-WorktreeBranches
	$wtSet            = $worktreeBranches
	$currentBranch    = git symbolic-ref --short HEAD 2>$null
	$baseBranch       = Get-BaseBranch

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
	$cyan   = "$esc[96m"
	$bold   = "$esc[1m"
	$reset  = "$esc[0m"

	$menuEntries = $sortedEntries | ForEach-Object {
		$padded  = $_.Branch.PadRight($maxLen)
		$padBase = $_.SyncBase.PadRight($maxBaseLen)
		$line    = "$($_.Marker) $padded    $padBase    $($_.SyncOrigin)$($_.Dirty)"
		if ($_.Marker -eq "*")     { "${bold}${yellow}${line}${reset}" }
		elseif ($_.Marker -eq "+") { "${cyan}${line}${reset}" }
		else { $line }
	}

	$lines = $menuEntries | fzf `
		--style=minimal --height=40% --no-info --layout=reverse `
		--pointer=">" --gutter=" " `
		--color="pointer:green,fg+:green:bold,bg+:-1" `
		--ansi `
		--header="Select branch or worktree (Del=delete, +=PRs/URL, m=merge into current, Esc=quit):" `
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
		$wtPath = Get-ExistingWtPath $branchSelected
		if ($env:WT_SESSION) {
			$safeLabel = $branchSelected -replace "/", "_"
			$tabScript = Join-Path $env:TEMP "git-wt-tab-${safeLabel}.ps1"
			@"
Set-Location -LiteralPath '$wtPath'
git fetch origin '${branchSelected}:refs/remotes/origin/${branchSelected}'
Write-Host ''
Write-Host '== Worktree: $branchSelected =='
Write-Host ''
"@ | Set-Content $tabScript -Encoding UTF8
			wt --window 0 new-tab --title $branchSelected --startingDirectory $wtPath pwsh -NoLogo -NoExit -File $tabScript
			Write-Host "Opened WT tab for worktree: $branchSelected" -ForegroundColor Cyan
		} else {
			Ensure-FetchRefspec $branchSelected
			Fetch-Branch $branchSelected
			Write-Host ""
			Write-Host "  Worktree path: $wtPath" -ForegroundColor Cyan
			Write-Host "  Run: cd `"$wtPath`"" -ForegroundColor Cyan
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
		$sibling = Find-SiblingRepo $branchSelected
		if ($sibling) {
			Open-SiblingRepo -RepoPath $sibling -Label $branchSelected
			exit 0
		}
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
		$copyGhLine = Get-CopyGitHubLine $wt.RepoRoot $wt.WtPath
		if ($env:WT_SESSION) {
			$safeLabel = $branchSelected -replace "/", "_"
			$tabScript = Join-Path $env:TEMP "git-wt-tab-${safeLabel}.ps1"
			$wtPathStr = $wt.WtPath
			$repoRoot  = $wt.RepoRoot
			@"
git worktree add --track -b '$branchSelected' '$wtPathStr' 'origin/$branchSelected'
if (`$LASTEXITCODE -ne 0) { Write-Host 'git worktree add failed.' -ForegroundColor Red; Read-Host 'Press Enter to exit'; exit 1 }
$copyGhLine
Set-Location -LiteralPath '$wtPathStr'
Write-Host ''
Write-Host '== Changes relative to master =='
Write-Host ''
changes
"@ | Set-Content $tabScript -Encoding UTF8
			wt --window 0 new-tab --title $branchSelected --startingDirectory $repoRoot pwsh -NoLogo -NoExit -File $tabScript
		} else {
			git worktree add --track -b $branchSelected $wt.WtPath "origin/$branchSelected"
			Copy-GitHubFolder $wt.RepoRoot $wt.WtPath
		}
	} else {
		Write-Host "== Checking out '$branchSelected' from origin =="
		git checkout -b $branchSelected "origin/$branchSelected"
	}
	exit $LASTEXITCODE
}