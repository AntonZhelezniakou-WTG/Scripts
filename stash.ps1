param(
	[string]$WorkDir,
	[string]$Action   # "apply" = show stash list; empty = create new stash
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common\common.ps1")

if ($WorkDir) { Set-Location $WorkDir }

git rev-parse --is-inside-work-tree 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
	Write-Host "Error: not a git repository." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

if (-not (Ensure-Fzf)) { Wait-AnyKey; exit 1 }

# ── APPLY mode ───────────────────────────────────────────────────────────────

if ($Action -eq 'apply') {

	function Get-Stashes {
		$ErrorActionPreference = "Continue"
		$raw = git stash list --format="%gd|%s" 2>$null
		$ErrorActionPreference = "Stop"
		if (-not $raw) { return @() }
		$i = 0
		return @($raw | ForEach-Object {
			$parts = $_ -split '\|', 2
			[PSCustomObject]@{
				Index   = $i++
				Ref     = $parts[0].Trim()
				Message = $parts[1].Trim()
				Name    = $parts[1].Trim() -replace '^On [^:]+:\s*', ''
			}
		})
	}

	while ($true) {
		$stashes = Get-Stashes

		if ($stashes.Count -eq 0) {
			Write-Host "No stashes found." -ForegroundColor Yellow
			Wait-AnyKey
			exit 0
		}

		# Tab-separated: visible name | hidden ref (e.g. stash@{0})
		$menuEntries = $stashes | ForEach-Object { "$($_.Name)`t$($_.Ref)" }

		$lines = $menuEntries | fzf `
			--style=minimal --no-input --disabled --height=40% --no-info --layout=reverse `
			--pointer=">" --gutter=" " `
			--color="pointer:green,fg+:green:bold,bg+:-1" `
			"--delimiter=`t" '--with-nth=1' `
			'--preview=git stash show --color=always --stat {2}' `
			'--preview-window=right,60%,wrap' `
			--header="Select stash (Enter=apply, Del=drop, Esc=quit):" `
			--header-first `
			--expect="del,esc"

		if (-not $lines) { exit 0 }

		$keyUsed = $lines[0].Trim()
		$rawLine = if ($lines.Count -gt 1) { $lines[1].Trim() } else { "" }

		if ($keyUsed -eq "esc" -or -not $rawLine) { exit 0 }

		$parts        = $rawLine -split "`t", 2
		$selectedName = $parts[0].Trim()
		$stash        = $stashes | Where-Object { $_.Name -eq $selectedName } | Select-Object -First 1
		if (-not $stash) { continue }

		if ($keyUsed -eq "del") {
			if (Confirm-Action "Drop '$($stash.Name)'?") {
				$ErrorActionPreference = "Continue"
				git stash drop $stash.Ref
				$ErrorActionPreference = "Stop"
				Write-Host "Dropped '$($stash.Name)'." -ForegroundColor Green
				Start-Sleep -Milliseconds 600
			}
			continue
		}

		if (-not (Confirm-Action "Apply '$($stash.Name)'?")) { continue }

		$ErrorActionPreference = "Continue"
		$dirtyBefore     = git status --porcelain --ignored=no 2>$null
		$ErrorActionPreference = "Stop"
		$hadLocalChanges = ($dirtyBefore | Where-Object { $_ -ne "" }).Count -gt 0

		$ErrorActionPreference = "Continue"
		git stash apply $stash.Ref
		$applyExit = $LASTEXITCODE
		$ErrorActionPreference = "Stop"

		if ($applyExit -ne 0) {
			$conflictsScript = Join-Path $PSScriptRoot "conflicts.ps1"
			& $conflictsScript -Mode stash -StashRef $stash.Ref
			continue
		}

		Write-Host ""
		if ($hadLocalChanges) {
			Write-Host "[warn] You had local changes before applying the stash." -ForegroundColor Yellow
			Write-Host "       Review the result carefully - changes have been merged." -ForegroundColor Yellow
			Wait-AnyKey
		} else {
			$commitMsg = "Applying stash: $($stash.Name)"
			if (Confirm-Action "Commit applied changes?") {
				git add .
				git commit -m $commitMsg
				if ($LASTEXITCODE -eq 0) {
					Write-Host "Committed: $commitMsg" -ForegroundColor Green
				} else {
					Write-Host "Commit failed." -ForegroundColor Red
				}
				Wait-AnyKey
			}
		}
	}

	exit 0
}

# ── CREATE STASH mode ─────────────────────────────────────────────────────────

function Get-AiStashLabel {
	if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) { return $null }

	$diff = (git diff --cached) -join "`n"
	if ($diff.Length -gt 8000) { $diff = $diff.Substring(0, 8000) + "`n...(truncated)" }
	if (-not $diff) { return $null }

	$prompt = @"
Write a stash label for this diff. Maximum 4 words, lowercase, no punctuation.
Describe WHAT was changed, not that it is a stash. Be specific to the actual changes.
Examples: "fix push review fzf", "improve stash create flow", "add worktree alias support".
Output ONLY the raw label. Nothing else.

$diff
"@

	$ErrorActionPreference = "Continue"
	$errFile = [System.IO.Path]::GetTempFileName()
	$result  = (copilot -p $prompt -s --no-auto-update --effort medium "--model=gpt-5.4-mini" 2>$errFile)
	$exit    = $LASTEXITCODE
	$ErrorActionPreference = "Stop"

	$errText = if (Test-Path $errFile) { (Get-Content $errFile -Raw -ErrorAction SilentlyContinue) } else { "" }
	Remove-Item $errFile -ErrorAction SilentlyContinue

	if ($exit -ne 0 -or -not $result) {
		$msg = if ($errText) { $errText.Trim() } else { "exit $exit, no output" }
		Write-Host "[warn] copilot: $msg" -ForegroundColor Yellow
		return $null
	}

	$text  = ($result -join " ").Trim() -replace '["""''`]', '' -replace '\s+', ' '
	$words = ($text -split '\s+') | Select-Object -First 4
	return ($words -join ' ').ToLower()
}

git add -A

$statusLines = @(git diff --cached --name-status)
if ($statusLines.Count -eq 0) {
	Write-Host "No changes to stash." -ForegroundColor Yellow
	exit 0
}

$repoRoot = Get-RepoRoot
Set-Location $repoRoot

# ── Phase 1: File selection ───────────────────────────────────────────────────

$selections = @()

while ($true) {
	git add -A
	$statusLines = @(git diff --cached --name-status)
	if ($statusLines.Count -eq 0) {
		Write-Host "No changes remaining." -ForegroundColor Yellow
		exit 0
	}

	$parsed     = Parse-StatusLines $statusLines
	$fzfEntries = Build-FzfEntries $parsed

	$fzfArgs = @(
		'--multi', '--ansi', '--sync'
		'--style=minimal', '--height=80%', '--no-info', '--layout=reverse'
		'--pointer=>', '--gutter= ', '--marker=>'
		'--color=pointer:green,fg+:green:bold,bg+:-1'
		'--header=Space=toggle  -=none  +=all  Del=discard  Ctrl+Enter=stash  Esc=cancel'
		'--header-first'
		"--delimiter=`t"
		'--with-nth=1'
		'--preview=git diff --cached --color=always -- {2}'
		'--preview-window=right,60%,wrap'
		'--bind=start:select-all+hide-input'
		'--bind=space:toggle'
		'--bind=-:deselect-all'
		'--bind=+:select-all'
		'--bind=enter:ignore'
		'--bind=ctrl-j:accept'
		'--expect=del'
	)
	$lines = $fzfEntries | fzf @fzfArgs

	if (-not $lines) {
		Write-Host "Cancelled." -ForegroundColor DarkGray
		git reset HEAD 2>$null
		exit 0
	}

	$keyUsed    = $lines[0].Trim()
	$selections = @($lines | Select-Object -Skip 1 | Where-Object { $_ })

	if ($keyUsed -eq "del") {
		if (-not $selections) { continue }
		$filePath = Extract-PathFromFzfLine $selections[0]
		$fileInfo = $parsed | Where-Object { $_.Path -eq $filePath } | Select-Object -First 1
		if (-not $fileInfo) { continue }

		$statusLabel = switch ($fileInfo.Status) {
			'A' { "DELETE new file" }
			'D' { "RESTORE deleted file" }
			default { "DISCARD changes in" }
		}

		Write-Host ""
		if (-not (Confirm-Action "$statusLabel '$filePath'?")) { continue }

		switch ($fileInfo.Status) {
			'A' {
				git rm --cached -- $filePath 2>$null
				$fullPath = Join-Path $repoRoot $filePath
				if (Test-Path $fullPath) { Remove-Item $fullPath -Force }
				Write-Host "Deleted: $filePath" -ForegroundColor Green
			}
			default {
				$ErrorActionPreference = "Continue"
				git checkout HEAD -- $filePath 2>$null
				$ErrorActionPreference = "Stop"
				Write-Host "Discarded: $filePath" -ForegroundColor Green
			}
		}
		Start-Sleep -Milliseconds 400
		continue
	}

	# Ctrl+Enter — proceed
	break
}

# Unstage files the user deselected
$selectedPaths = @($selections | ForEach-Object { Extract-PathFromFzfLine $_ })
$allPaths      = @($parsed | ForEach-Object { $_.Path })
$toUnstage     = @($allPaths | Where-Object { $selectedPaths -notcontains $_ })
foreach ($f in $toUnstage) { git reset HEAD -- $f 2>$null }

# ── Phase 2: Generate stash label ─────────────────────────────────────────────

Write-Host ""
Write-Host "Generating stash label..." -ForegroundColor DarkGray
$label = Get-AiStashLabel
if (-not $label) { $label = "wip" }

Write-Host "Stash label: " -ForegroundColor Cyan -NoNewline
Write-Host $label -ForegroundColor White
Write-Host "Edit label (Enter=keep, Esc=cancel): " -ForegroundColor DarkGray -NoNewline

$sb = [System.Text.StringBuilder]::new()
$cancelled = $false
while ($true) {
	$ki = [Console]::ReadKey($true)
	if ($ki.Key -eq 'Escape') { $cancelled = $true; break }
	if ($ki.Key -eq 'Enter')  { Write-Host ""; break }
	if ($ki.Key -eq 'Backspace') {
		if ($sb.Length -gt 0) {
			$sb.Remove($sb.Length - 1, 1) | Out-Null
			Write-Host "`b `b" -NoNewline
		}
		continue
	}
	if ($ki.KeyChar -ne [char]0) {
		$sb.Append($ki.KeyChar) | Out-Null
		Write-Host $ki.KeyChar -NoNewline
	}
}

if ($cancelled) {
	Write-Host ""
	Write-Host "Cancelled." -ForegroundColor DarkGray
	git reset HEAD 2>$null
	exit 0
}

$userInput = $sb.ToString()
if ($userInput.Trim()) { $label = $userInput.Trim() }

# ── Phase 3: Stash staged files ───────────────────────────────────────────────

Write-Host ""
$ErrorActionPreference = "Continue"
git stash push --staged -m $label
$stashExit = $LASTEXITCODE
$ErrorActionPreference = "Stop"

if ($stashExit -ne 0) {
	Write-Host "Stash failed." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

Write-Host "Stashed: $label" -ForegroundColor Green
