# VCS backend detection and Jujutsu (jj) helpers.
#
# jj is git-compatible: remotes, push/fetch and PR creation go through the git
# backend and `gh`. The model differs from git: there is no staging area (the
# working copy `@` IS a commit) and the branch analogue is a *bookmark* that,
# unlike a git branch, does NOT advance automatically on commit.
#
# In a colocated repo (.git + .jj both present) jj takes priority.
#
# Discipline: parse jj output only through explicit `-T '... ++ "\n"'` templates
# with `--no-graph` — never the decorated/graph output. Wrap every control-flow
# jj call in the Continue -> $LASTEXITCODE -> Stop pattern. jj exits 0 even with
# conflicts, so detect conflicts via the `conflicts()` revset, never the exit code.

# ── Detection ────────────────────────────────────────────────────────────────

# Walk parent directories from $StartDir (inclusive) looking for a .jj directory.
function Test-IsJjRepo {
	param([string]$StartDir)
	if (-not $StartDir) { $StartDir = (Get-Location).Path }
	$dir = $StartDir
	while ($dir) {
		if ([System.IO.Directory]::Exists((Join-Path $dir ".jj"))) { return $true }
		$parent = Split-Path $dir -Parent
		if ($parent -eq $dir) { break }
		$dir = $parent
	}
	return $false
}

# Directory containing .jj — jj analogue of Get-RepoRoot (preserves symlinks).
function Get-JjRoot {
	param([string]$StartDir)
	if (-not $StartDir) { $StartDir = (Get-Location).Path }
	$dir = $StartDir
	while ($dir) {
		if ([System.IO.Directory]::Exists((Join-Path $dir ".jj"))) { return $dir }
		$parent = Split-Path $dir -Parent
		if ($parent -eq $dir) { break }
		$dir = $parent
	}
	return $null
}

# Single source of truth for backend selection. jj wins in colocated repos.
# Returns 'jj', 'git', or $null (not a repo).
function Get-VcsBackend {
	param([string]$StartDir)
	if (Test-IsJjRepo $StartDir) { return 'jj' }
	$ErrorActionPreference = "Continue"
	git rev-parse --is-inside-work-tree 2>&1 | Out-Null
	$inGit = ($LASTEXITCODE -eq 0)
	$ErrorActionPreference = "Stop"
	if ($inGit) { return 'git' }
	return $null
}

# True if a revset/revision resolves (e.g. a bookmark name or "<base>@origin").
function Test-JjRevExists {
	param([Parameter(Mandatory)][string]$Rev)
	$ErrorActionPreference = "Continue"
	jj log --no-graph -r $Rev -T '"x"' 2>$null | Out-Null
	$exit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	return ($exit -eq 0)
}

# Number of commits a revset resolves to (e.g. ahead/behind ranges like "b@origin..b").
function Get-JjRevCount {
	param([Parameter(Mandatory)][string]$Revset)
	$ErrorActionPreference = "Continue"
	$out = jj log --no-graph -r $Revset -T '"x\n"' 2>$null
	$ErrorActionPreference = "Stop"
	return @($out | Where-Object { $_ -and $_.Trim() }).Count
}

# Base bookmark for rebase/merge: explicit name, else local main/master, else a
# remote-only main/master (a fresh colocated clone may have no local bookmark yet).
function Get-JjBaseBookmark {
	param([string]$Explicit)
	if ($Explicit) { return $Explicit }
	$all = Get-JjBookmarks
	foreach ($b in @('main', 'master')) { if ($all -contains $b) { return $b } }
	foreach ($b in @('main', 'master')) { if (Test-JjRevExists "$b@origin") { return $b } }
	return $null
}

# True if the conflicts() revset is non-empty (jj returns 0 even with conflicts).
function Test-JjHasConflicts {
	$ErrorActionPreference = "Continue"
	$out = jj log --no-graph -r 'conflicts()' -T 'change_id.short() ++ "\n"' 2>$null
	$ErrorActionPreference = "Stop"
	return @($out | Where-Object { $_ -and $_.Trim() }).Count -gt 0
}

# ── Bookmarks ────────────────────────────────────────────────────────────────

# All local bookmark names. The present/remote filter matters: a deleted but
# still-tracked bookmark lingers as "<name> (deleted)" plus its @origin entry,
# and a bare 'name' template would keep resurrecting it in every list.
function Get-JjBookmarks {
	$ErrorActionPreference = "Continue"
	$out = jj bookmark list -T 'if(self.present() && !self.remote(), name ++ "\n", "")' 2>$null
	$ErrorActionPreference = "Stop"
	return @($out | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } | Select-Object -Unique)
}

# Local bookmark names pointing exactly at the working copy (@).
function Get-JjBookmarkOnWorkingCopy {
	$ErrorActionPreference = "Continue"
	$out = jj log --no-graph -r 'bookmarks() & @' -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' 2>$null
	$ErrorActionPreference = "Stop"
	return @($out | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}

# Names on the closest bookmarked ancestor(s) of @ — the "nearest bookmark in the
# branch". heads() drops anything shadowed by a nearer bookmark on the same line;
# several names mean parallel heads (genuinely ambiguous).
function Get-JjNearestAncestorBookmarks {
	$ErrorActionPreference = "Continue"
	$out = jj log --no-graph -r 'heads(bookmarks() & ::@)' -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' 2>$null
	$ErrorActionPreference = "Stop"
	return @($out | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}

# Move (or create) a bookmark onto a revision (default @ — the committed change).
# The user has explicitly chosen this bookmark, so --allow-backwards permits the
# move even when the target isn't a descendant (e.g. a non-ancestor bookmark).
function Set-JjBookmark {
	param(
		[Parameter(Mandatory)][string]$Name,
		[string]$Revision = '@'
	)
	$existing = Get-JjBookmarks
	$ErrorActionPreference = "Continue"
	if ($existing -contains $Name) {
		jj bookmark set $Name -r $Revision --allow-backwards | Out-Host
	} else {
		jj bookmark create $Name -r $Revision | Out-Host
	}
	$exit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	return ($exit -eq 0)
}

# fzf picker over bookmark candidates, reusing the repo's inline minimal style.
# With -AllowNew, appends a "+ new bookmark…" entry; returns the literal sentinel
# '<new>' when chosen. Returns $null on cancel.
function Select-JjBookmarkViaFzf {
	param(
		[string[]]$Candidates,
		[string]$Header = "Pick a bookmark:",
		[switch]$AllowNew
	)
	$entries = @($Candidates)
	if ($AllowNew) { $entries += "+ new bookmark…" }

	$fzfArgs = @(
		'--ansi', '--sync'
		'--style=minimal', '--height=~10', '--no-info', '--layout=reverse'
		'--pointer=>', '--gutter= '
		'--color=pointer:green,fg+:green:bold,bg+:-1'
		"--header=$Header"
		'--header-first'
		'--bind=start:hide-input'
	)
	$picked = $entries | fzf @fzfArgs
	if (-not $picked) { return $null }
	$picked = $picked.Trim()
	if ($AllowNew -and $picked -eq "+ new bookmark…") { return '<new>' }
	return $picked
}

# Prompt inline for a new bookmark name. Returns trimmed name or $null.
function Read-JjBookmarkName {
	Write-Host ""
	Write-Host "New bookmark name (empty to skip): " -ForegroundColor Cyan -NoNewline
	$name = [Console]::ReadLine()
	if ($name) { $name = $name.Trim() }
	if ($name) { return $name }
	return $null
}

# Decide which bookmark to advance onto @ at commit time, per the spec:
#   - exactly one bookmark on @            -> use it
#   - several bookmarks on @               -> ask
#   - none on @, single nearest ancestor   -> use it ("ближайший bookmark")
#   - none on @, exactly one bookmark total-> use it ("единственный в репозитории")
#   - none on @, several nearest ancestors -> ask
#   - none on @/nearest, several elsewhere -> ask (+ create new)
#   - no bookmarks at all                  -> prompt new name or skip
# Returns the chosen bookmark name, or $null to skip (commit without a bookmark).
function Select-JjBookmarkForCommit {
	$onWc    = @(Get-JjBookmarkOnWorkingCopy)
	$nearest = @(Get-JjNearestAncestorBookmarks)
	$all     = @(Get-JjBookmarks)

	if ($onWc.Count -eq 1) { return $onWc[0] }
	if ($onWc.Count -gt 1) {
		return (Select-JjBookmarkViaFzf -Candidates $onWc -Header "Several bookmarks on this change — which to commit into?")
	}

	if ($nearest.Count -eq 1) { return $nearest[0] }
	if ($all.Count -eq 1)     { return $all[0] }
	if ($nearest.Count -gt 1) {
		return (Select-JjBookmarkViaFzf -Candidates $nearest -Header "Several nearby bookmarks — which to commit into?")
	}
	if ($all.Count -gt 1) {
		$pick = Select-JjBookmarkViaFzf -Candidates $all -Header "No bookmark on this line — pick one (or create):" -AllowNew
		if ($pick -eq '<new>') { return (Read-JjBookmarkName) }
		return $pick
	}

	# No bookmarks at all.
	return (Read-JjBookmarkName)
}

# Pick the bookmark associated with the current change: the one on @,
# else the single nearest ancestor, else the sole bookmark; ambiguity -> fzf.
# Returns $null when the repo has no bookmark. -Header customises the fzf
# prompt for the caller's operation (push by default, pull, etc.).
function Select-JjBookmarkForPush {
	param([string]$Header = "Which bookmark to push?")
	$onWc = @(Get-JjBookmarkOnWorkingCopy)
	if ($onWc.Count -eq 1) { return $onWc[0] }
	if ($onWc.Count -gt 1) { return (Select-JjBookmarkViaFzf -Candidates $onWc -Header $Header) }

	$nearest = @(Get-JjNearestAncestorBookmarks)
	if ($nearest.Count -eq 1) { return $nearest[0] }
	if ($nearest.Count -gt 1) { return (Select-JjBookmarkViaFzf -Candidates $nearest -Header $Header) }

	$all = @(Get-JjBookmarks)
	if ($all.Count -eq 1) { return $all[0] }
	if ($all.Count -gt 1) { return (Select-JjBookmarkViaFzf -Candidates $all -Header $Header) }
	return $null
}

# jj silently skips new files larger than snapshot.max-new-file-size (default
# 1MiB): they never enter the working copy, and scripts that suppress stderr
# hide jj's warning entirely — the file just doesn't show up anywhere. Surface
# the refusal and offer to raise the repo-local limit so the files are picked up.
function Resolve-JjSnapshotRefusals {
	$ErrorActionPreference = "Continue"
	$lines = @(jj --color=never st 2>&1 | ForEach-Object { "$_" })
	$ErrorActionPreference = "Stop"
	if (-not ($lines -match 'Refused to snapshot')) { return }

	# Per-file warning line: "  <path>: <size> (<bytes> bytes); the maximum size allowed is ..."
	$refused = [ordered]@{}
	foreach ($l in $lines) {
		if ($l -match '^\s+(.+?):\s+\S+\s+\((\d+) bytes\); the maximum size allowed') {
			$refused[$Matches[1]] = [long]$Matches[2]
		}
	}
	if ($refused.Count -eq 0) { return }

	Write-Host ""
	Write-Host "[warn] jj refused to snapshot large new file(s) (over $(jj config get snapshot.max-new-file-size)):" -ForegroundColor Yellow
	foreach ($k in $refused.Keys) {
		Write-Host ("  {0} ({1:N1} MiB)" -f $k, ($refused[$k] / 1MB)) -ForegroundColor Yellow
	}
	$maxBytes = ($refused.Values | Measure-Object -Maximum).Maximum
	if (Confirm-Action "Raise this repo's snapshot.max-new-file-size to $maxBytes bytes and include them?") {
		$ErrorActionPreference = "Continue"
		jj config set --repo snapshot.max-new-file-size $maxBytes
		jj st 2>&1 | Out-Null   # re-snapshot under the new limit
		$ErrorActionPreference = "Stop"
		Write-Host "Limit raised; file(s) snapshotted." -ForegroundColor Green
	} else {
		Write-Host "Skipped. Add them to .gitignore, or raise snapshot.max-new-file-size later." -ForegroundColor DarkGray
	}
}

# Huge-repo discipline: .git/config carries narrow per-branch fetch refspecs
# instead of the +refs/heads/* glob, so refspec-driven fetches (plain
# `jj git fetch`, git tooling) stay cheap. Register the branch in a colocated
# repo's .git/config whenever a bookmark starts being pushed/pulled.
function Ensure-JjFetchRefspec {
	param([Parameter(Mandatory)][string]$Name)
	$root = Get-JjRoot
	if (-not $root) { return }
	if (-not (Test-Path (Join-Path $root ".git"))) { return } # not colocated
	Ensure-FetchRefspec $Name
}

# True if the local bookmark is in the conflicted state (e.g. it moved locally
# while origin moved too, and a fetch recorded both targets).
function Test-JjBookmarkConflicted {
	param([Parameter(Mandatory)][string]$Name)
	$ErrorActionPreference = "Continue"
	$out = jj bookmark list -T 'if(!self.remote() && self.conflict(), name ++ "\n", "")' 2>$null
	$ErrorActionPreference = "Stop"
	return (@($out | ForEach-Object { $_.Trim() }) -contains $Name)
}

# Push a bookmark safely — never force-push over origin. jj git push overwrites
# the remote bookmark (force-with-lease against the last-fetched position), so:
#  - fetch the branch first;
#  - if the fetch turns the bookmark conflicted (origin moved AND it moved
#    locally), offer to rebase the local commits onto origin and resolve;
#  - if origin is plainly ahead, offer to pull — and never push while behind.
# Returns $true when the push succeeded.
# Resolve a conflicted (diverged) bookmark: pick the local side out of the
# conflict targets, offer to rebase it onto origin, and re-point the bookmark.
# Change ids survive the rebase, so the bookmark is re-set by change id.
# Returns $true when resolved.
function Resolve-JjDivergedBookmark {
	param([Parameter(Mandatory)][string]$Bookmark)

	if (-not (Test-JjRevExists "$Bookmark@origin")) {
		Write-Host "Bookmark '$Bookmark' is conflicted (no origin side). Resolve with 'jj bookmark set $Bookmark -r <rev>'." -ForegroundColor Red
		return $false
	}

	$originCommit = (jj log --no-graph -r "$Bookmark@origin" -T 'commit_id ++ "\n"' 2>$null | Select-Object -First 1)
	$ErrorActionPreference = "Continue"
	$tmpl = 'if(!self.remote() && self.name() == "' + $Bookmark + '", self.added_targets().map(|t| t.change_id() ++ " " ++ t.commit_id()).join("\n") ++ "\n", "")'
	$targets = @(jj bookmark list -T $tmpl 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })
	$ErrorActionPreference = "Stop"
	$localChange = $targets | Where-Object { ($_ -split ' ')[1] -ne $originCommit } |
		ForEach-Object { ($_ -split ' ')[0] } | Select-Object -First 1
	if (-not $localChange) {
		Write-Host "Cannot identify the local side of '$Bookmark'. Resolve with 'jj bookmark set $Bookmark -r <rev>'." -ForegroundColor Red
		return $false
	}

	Write-Host ""
	Write-Host "[warn] origin/$Bookmark moved while '$Bookmark' also moved locally — the bookmark is diverged." -ForegroundColor Yellow
	if (-not (Confirm-Action "Rebase your commits onto origin/$Bookmark and continue?")) {
		Write-Host "Cancelled. Inspect with 'jj bookmark list', resolve with 'jj bookmark set'." -ForegroundColor Yellow
		return $false
	}

	$ErrorActionPreference = "Continue"
	jj rebase -b $localChange -d "$Bookmark@origin"
	$rbExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($rbExit -ne 0) {
		Write-Host "Rebase failed. Recover with 'jj op undo'." -ForegroundColor Red
		return $false
	}
	if (Test-JjHasConflicts) {
		Write-Host "Rebase produced conflicts. Resolve with 'jj resolve', then push again." -ForegroundColor Yellow
		return $false
	}
	$ErrorActionPreference = "Continue"
	jj bookmark set $Bookmark -r $localChange | Out-Host
	$setExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($setExit -ne 0) {
		Write-Host "Could not re-point the bookmark. Resolve with 'jj bookmark set'." -ForegroundColor Red
		return $false
	}
	Write-Host "Bookmark '$Bookmark' resolved on top of origin." -ForegroundColor Green
	return $true
}

function Invoke-JjPushBookmark {
	param([Parameter(Mandatory)][string]$Bookmark)

	$ErrorActionPreference = "Continue"
	jj git fetch --branch $Bookmark 2>&1 | Out-Null
	$ErrorActionPreference = "Stop"

	# Diverged (now or from an earlier fetch): rebase onto origin or bail —
	# jj refuses to push a conflicted bookmark anyway.
	if (Test-JjBookmarkConflicted $Bookmark) {
		if (-not (Resolve-JjDivergedBookmark $Bookmark)) {
			Write-Host "Push cancelled." -ForegroundColor Yellow
			return $false
		}
	}

	$isNew = -not (Test-JjRevExists "$Bookmark@origin")
	if (-not $isNew) {
		$behind = Get-JjRevCount "$Bookmark..$Bookmark@origin"
		if ($behind -gt 0) {
			Write-Host ""
			Write-Host "[warn] origin/$Bookmark is $behind commit(s) ahead; pushing now would overwrite and drop them." -ForegroundColor Yellow
			if (-not (Confirm-Action "Pull (rebase onto origin/$Bookmark) first?")) {
				Write-Host "Push cancelled." -ForegroundColor Yellow
				return $false
			}
			& (Join-Path (Split-Path $PSScriptRoot -Parent) "pull.ps1")
			if ($LASTEXITCODE -ne 0) {
				Write-Host "Pull failed; push cancelled." -ForegroundColor Red
				return $false
			}
			if ((Get-JjRevCount "$Bookmark..$Bookmark@origin") -gt 0) {
				Write-Host "Still behind origin/$Bookmark; push cancelled." -ForegroundColor Yellow
				return $false
			}
		}
	}

	Write-Host "Pushing bookmark '$Bookmark'..." -ForegroundColor Cyan
	$ErrorActionPreference = "Continue"
	if ($isNew) { jj git push -b $Bookmark --allow-new } else { jj git push -b $Bookmark }
	$pushExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($pushExit -ne 0) {
		Write-Host "Push failed." -ForegroundColor Red
		return $false
	}
	Write-Host "Pushed." -ForegroundColor Green
	Ensure-JjFetchRefspec $Bookmark
	return $true
}

# Offer to create a PR for a pushed bookmark (gh reads the exported git ref).
# Skips main/master and no-ops when a PR already exists.
function Invoke-JjPrCreate {
	param([Parameter(Mandatory)][string]$Bookmark)
	if ($Bookmark -in @('main', 'master')) { return }

	$ErrorActionPreference = "Continue"
	$prJson = gh pr view $Bookmark --json url 2>$null
	$prExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($prExit -eq 0 -and $prJson) {
		Write-Host "PR already exists: $(($prJson | ConvertFrom-Json).url)" -ForegroundColor DarkGray
		return
	}

	Write-Host ""
	Write-Host "Create PR? [y/N] " -ForegroundColor Cyan -NoNewline
	$prKey = [Console]::ReadKey($true)
	Write-Host $prKey.KeyChar
	if ($prKey.KeyChar -notmatch '^[Yy]$') { return }

	$ErrorActionPreference = "Continue"
	gh pr create --fill --head $Bookmark
	$ErrorActionPreference = "Stop"
}

# ── Status parsing (jj diff --summary: "<L> <path>", space-separated) ─────────

# Expand jj's rename/copy path notation "pre{old => new}post" (or "old => new")
# into the real old/new file paths. Returns @{ Old; New }.
function Expand-JjRenamePath {
	param([string]$Raw)
	if ($Raw -match '^(.*)\{(.*?) => (.*?)\}(.*)$') {
		return @{ Old = ($Matches[1] + $Matches[2] + $Matches[4]); New = ($Matches[1] + $Matches[3] + $Matches[4]) }
	}
	if ($Raw -match '^(.+?) => (.+)$') {
		return @{ Old = $Matches[1].Trim(); New = $Matches[2].Trim() }
	}
	return @{ Old = $null; New = $Raw }
}

# Parse `jj diff --summary` lines into the same shape as Parse-StatusLines so the
# shared Build-FzfEntries / display code can be reused. Renames/copies (R/C) carry
# the brace notation, expanded here into Path (new) + OldPath (old).
function Parse-JjStatusLines([string[]]$Lines) {
	$result = @()
	foreach ($line in $Lines) {
		if ($line -match '^([MADCR])\s+(.+)$') {
			$status = $Matches[1]
			$rawPath = $Matches[2].Trim()
			if ($status -in @('R', 'C')) {
				$ex = Expand-JjRenamePath $rawPath
				$result += [PSCustomObject]@{ Status = $status; Path = $ex.New; OldPath = $ex.Old }
			} else {
				$result += [PSCustomObject]@{ Status = $status; Path = $rawPath; OldPath = $null }
			}
		}
	}
	return $result | Sort-Object Path
}
