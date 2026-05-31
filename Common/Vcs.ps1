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

# All local bookmark names.
function Get-JjBookmarks {
	$ErrorActionPreference = "Continue"
	$out = jj bookmark list -T 'name ++ "\n"' 2>$null
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
		jj bookmark set $Name -r $Revision --allow-backwards 2>&1 | Out-Host
	} else {
		jj bookmark create $Name -r $Revision 2>&1 | Out-Host
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

# Pick the bookmark associated with the current change for push: the one on @,
# else the single nearest ancestor, else the sole bookmark; ambiguity -> fzf.
# Returns $null when the repo has no bookmark to push.
function Select-JjBookmarkForPush {
	$onWc = @(Get-JjBookmarkOnWorkingCopy)
	if ($onWc.Count -eq 1) { return $onWc[0] }
	if ($onWc.Count -gt 1) { return (Select-JjBookmarkViaFzf -Candidates $onWc -Header "Which bookmark to push?") }

	$nearest = @(Get-JjNearestAncestorBookmarks)
	if ($nearest.Count -eq 1) { return $nearest[0] }
	if ($nearest.Count -gt 1) { return (Select-JjBookmarkViaFzf -Candidates $nearest -Header "Which bookmark to push?") }

	$all = @(Get-JjBookmarks)
	if ($all.Count -eq 1) { return $all[0] }
	if ($all.Count -gt 1) { return (Select-JjBookmarkViaFzf -Candidates $all -Header "Which bookmark to push?") }
	return $null
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
