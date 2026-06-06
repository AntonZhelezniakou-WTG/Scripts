param(
	[string]$WorkDir
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common\common.ps1")

if ($WorkDir) { Set-Location $WorkDir }

# ── Helpers ─────────────────────────────────────────────────────────────────

function Ensure-Micro {
	if (Get-Command micro -ErrorAction SilentlyContinue) { return $true }

	Write-Host "micro editor is not installed. It is used to edit the commit message." -ForegroundColor Yellow
	Write-Host ""
	Write-Host -NoNewline "Install micro now via winget? [Y/n]: "
	$key = [Console]::ReadKey($true)
	Write-Host $key.KeyChar

	if ($key.Key -eq "Enter" -or $key.KeyChar -match "^[Yy]$") {
		winget install zyedidia.micro
		if ($LASTEXITCODE -ne 0 -or -not (Get-Command micro -ErrorAction SilentlyContinue)) {
			$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
			            [System.Environment]::GetEnvironmentVariable("PATH", "User")
			if (-not (Get-Command micro -ErrorAction SilentlyContinue)) {
				Write-Host "Failed to install micro. Please install it manually: winget install zyedidia.micro" -ForegroundColor Red
				return $false
			}
		}
		Write-Host "micro installed successfully." -ForegroundColor Green
		return $true
	}

	Write-Host "Skipped." -ForegroundColor DarkGray
	return $false
}


function Get-AiCommitMessage {
	param([string]$Diff)
	if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) { return $null }

	$diff = $Diff
	if ($diff.Length -gt 8000) {
		$diff = $diff.Substring(0, 8000) + "`n... (truncated)"
	}

	Write-Host "Generating commit message..." -ForegroundColor DarkGray

	$prompt = @"
Write a git commit message for this diff. Describe the PURPOSE and ESSENCE of the changes — what was done and why.
NEVER list file names or paths. NEVER enumerate changes file-by-file.
First line: imperative mood, max 72 chars.
If more context is needed, add a body after a blank line.
Output ONLY the raw commit message text. No markdown, no quotes, no prefixes.

$diff
"@

	$ErrorActionPreference = "Continue"
	$model = "gpt-5.4-mini"
	$errFile = [System.IO.Path]::GetTempFileName()
	$result = (copilot -p $prompt -s --no-auto-update --effort medium "--model=$model" 2>$errFile)
	$exit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"

	$errText = if (Test-Path $errFile) { (Get-Content $errFile -Raw -ErrorAction SilentlyContinue) } else { "" }
	Remove-Item $errFile -ErrorAction SilentlyContinue

	if ($exit -ne 0 -or -not $result) {
		$msg = if ($errText) { $errText.Trim() } else { "exit $exit, no output" }
		Write-Host "[warn] copilot: $msg" -ForegroundColor Yellow
		return $null
	}

	$text = ($result -join "`n").Trim()
	# Strip Co-authored-by trailers added by Copilot
	$text = ($text -replace '(?m)^\s*Co-authored-by:.*$', '').Trim()
	if ($text) { return $text }
	return $null
}

# Edit an AI/seed message in micro (or inline fallback). Returns trimmed text.
function Get-EditedCommitMessage {
	param([string]$AiMessage)
	$tempFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.txt'
	Set-Content $tempFile $AiMessage -Encoding UTF8
	if (Ensure-Micro) {
		micro $tempFile
	} else {
		Write-Host ""
		Write-Host "Commit message:" -ForegroundColor Cyan
		Write-Host $AiMessage -ForegroundColor White
		Write-Host ""
		Write-Host "Press Enter to keep, or type a new message: " -ForegroundColor Cyan -NoNewline
		$userInput = [Console]::ReadLine()
		if ($userInput.Trim()) { Set-Content $tempFile $userInput.Trim() -Encoding UTF8 }
	}
	$msg = (Get-Content $tempFile -Raw -Encoding UTF8).Trim()
	Remove-Item $tempFile -ErrorAction SilentlyContinue
	return $msg
}

# ── jj (Jujutsu) commit path ─────────────────────────────────────────────────
#
# No staging area: @ already holds the changes. A partial selection is realised
# with `jj split` (selected files -> committed change @-, the rest stay in @).
# After committing, the chosen bookmark is advanced onto the committed change.
function Invoke-JjCommit {
	if (-not (Ensure-Fzf)) { Wait-AnyKey; return }

	$root = Get-JjRoot
	if ($root) { Set-Location $root }

	if (@(jj diff --summary -r '@' 2>$null).Count -eq 0) {
		Write-Host "No changes to commit." -ForegroundColor Yellow
		return
	}

	# ── Interactive file review ──────────────────────────────────────────
	$selections = $null
	$parsed     = $null
	while ($true) {
		$summary = @(jj diff --summary -r '@' 2>$null)
		if ($summary.Count -eq 0) {
			Write-Host "No changes remaining." -ForegroundColor Yellow
			return
		}

		$parsed     = Parse-JjStatusLines $summary
		$fzfEntries = Build-FzfEntries $parsed

		$fzfArgs = @(
			'--multi', '--ansi', '--sync'
			'--style=minimal', '--height=80%', '--no-info', '--layout=reverse'
			'--pointer=>', '--gutter= ', '--marker=>'
			'--color=pointer:green,fg+:green:bold,bg+:-1'
			'--header=Space=toggle  -=none  +=all  Del=discard  Ctrl+Enter=confirm  Esc=cancel'
			'--header-first'
			"--delimiter=`t"
			'--with-nth=1'
			'--preview=jj diff --git -r @ -- {2}'
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

		if (-not $lines) { Write-Host "Cancelled." -ForegroundColor DarkGray; return }

		$keyUsed    = $lines[0].Trim()
		$selections = @($lines | Select-Object -Skip 1 | Where-Object { $_ })

		# Del — discard changes for highlighted file (jj restore reverts to @-)
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

			# Renames touch two paths — restore both so the rename fully reverts.
			$restorePaths = @($fileInfo.Path; if ($fileInfo.OldPath) { $fileInfo.OldPath })
			$ErrorActionPreference = "Continue"
			jj restore @restorePaths 2>$null | Out-Null
			$ErrorActionPreference = "Stop"
			Write-Host "Discarded: $filePath" -ForegroundColor Green
			Start-Sleep -Milliseconds 400
			continue
		}

		break
	}

	$selectedPaths = @($selections | ForEach-Object { Extract-PathFromFzfLine $_ })
	$allPaths      = @($parsed | ForEach-Object { $_.Path })
	if ($selectedPaths.Count -eq 0) {
		Write-Host "No files selected for commit." -ForegroundColor Yellow
		return
	}
	$isPartial = ($selectedPaths.Count -lt $allPaths.Count)

	Write-Host ""
	Write-Host "$($selectedPaths.Count) file(s) to commit." -ForegroundColor Cyan

	# Map selection back to parsed entries; renames contribute both old and new
	# paths so `jj split` and the diff include the full change.
	$selectedParsed = @($parsed | Where-Object { $selectedPaths -contains $_.Path })
	$jjPaths        = @($selectedParsed | ForEach-Object { $_.Path; if ($_.OldPath) { $_.OldPath } })

	# ── Commit message ───────────────────────────────────────────────────
	$diff = (jj diff --git -r '@' -- @jjPaths 2>$null) -join "`n"
	$aiMessage = Get-AiCommitMessage $diff
	if (-not $aiMessage) {
		$aiMessage = ""
		Write-Host "[info] AI unavailable (install copilot CLI for auto-generation)." -ForegroundColor DarkGray
	}

	$commitMessage = Get-EditedCommitMessage $aiMessage
	if (-not $commitMessage) {
		Write-Host "Empty commit message. Aborted." -ForegroundColor Red
		return
	}

	Write-Host ""
	Write-Host "Commit message:" -ForegroundColor Cyan
	Write-Host $commitMessage -ForegroundColor White
	Write-Host ""
	if (-not (Confirm-Action "Commit?")) { Write-Host "Aborted." -ForegroundColor DarkGray; return }

	# ── Choose bookmark BEFORE committing (selection is relative to @) ────
	$bookmark = Select-JjBookmarkForCommit

	# ── Commit ───────────────────────────────────────────────────────────
	$ErrorActionPreference = "Continue"
	if ($isPartial) {
		jj split @jjPaths --message $commitMessage
		$commitExit  = $LASTEXITCODE
		$targetRev   = '@-'
	} else {
		jj describe -m $commitMessage
		$commitExit  = $LASTEXITCODE
		$targetRev   = '@'
	}
	$ErrorActionPreference = "Stop"

	if ($commitExit -ne 0) {
		Write-Host "Commit failed." -ForegroundColor Red
		Wait-AnyKey
		return
	}

	# Advance the chosen bookmark onto the committed change.
	if ($bookmark) {
		if (Set-JjBookmark -Name $bookmark -Revision $targetRev) {
			Write-Host "Bookmark '$bookmark' -> committed change." -ForegroundColor DarkGray
		}
	}

	# For a full commit, open a fresh empty working copy on top (git-like).
	if (-not $isPartial) {
		$ErrorActionPreference = "Continue"
		jj new 2>&1 | Out-Null
		$ErrorActionPreference = "Stop"
	}

	Write-Host "Committed." -ForegroundColor Green

	# ── Offer push ───────────────────────────────────────────────────────
	if (-not $bookmark) { return }
	if ($bookmark -in @('main', 'master')) { return }

	Write-Host ""
	$Host.UI.RawUI.FlushInputBuffer()
	Write-Host "Push bookmark '$bookmark'? [y/N] " -ForegroundColor Cyan -NoNewline
	$pushKey = [Console]::ReadKey($true)
	Write-Host $pushKey.KeyChar
	if ($pushKey.KeyChar -notmatch '^[Yy]$') { Write-Host "Push skipped." -ForegroundColor DarkGray; return }

	Write-Host ""
	Write-Host "Pushing bookmark '$bookmark'..." -ForegroundColor Cyan
	$ErrorActionPreference = "Continue"
	jj git push -b $bookmark
	$pushExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($pushExit -ne 0) {
		Write-Host "Push failed." -ForegroundColor Red
		return
	}
	Write-Host "Pushed." -ForegroundColor Green
	Ensure-JjFetchRefspec $bookmark

	Invoke-JjPrCreate -Bookmark $bookmark
}

# ── Validate ────────────────────────────────────────────────────────────────

$script:VcsBackend = Get-VcsBackend
if (-not $script:VcsBackend) {
	Write-Host "Not a repository." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}
if ($script:VcsBackend -eq 'jj') { Invoke-JjCommit; exit 0 }

git rev-parse --is-inside-work-tree 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
	Write-Host "Not a git repository." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

if (-not (Ensure-Fzf)) { Wait-AnyKey; exit 1 }

$repoRoot = Get-RepoRoot
Set-Location $repoRoot

# ── Phase 1: Stage all ──────────────────────────────────────────────────────

git add -A

$statusLines = @(git diff --cached --name-status)
if ($statusLines.Count -eq 0) {
	Write-Host "No changes to commit." -ForegroundColor Yellow
	exit 0
}

# ── Phase 2: Interactive file review ────────────────────────────────────────

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
		'--header=Space=toggle  -=none  +=all  Del=discard  Ctrl+Enter=confirm  Esc=cancel'
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

	if (-not $lines) { Write-Host "Cancelled." -ForegroundColor DarkGray; exit 0 }

	$keyUsed    = $lines[0].Trim()
	$selections = @($lines | Select-Object -Skip 1 | Where-Object { $_ })

	# Del — discard changes for highlighted file
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

	# Enter — proceed with selected files
	break
}

# Unstage deselected files
$selectedPaths = @($selections | ForEach-Object { Extract-PathFromFzfLine $_ })
$allPaths      = @($parsed | ForEach-Object { $_.Path })
$toUnstage     = @($allPaths | Where-Object { $selectedPaths -notcontains $_ })

if ($toUnstage) {
	foreach ($f in $toUnstage) {
		git reset HEAD -- $f 2>$null
	}
}

# Verify something is still staged
$staged = @(git diff --cached --name-only)
if ($staged.Count -eq 0) {
	Write-Host "No files selected for commit." -ForegroundColor Yellow
	exit 0
}

Write-Host ""
Write-Host "$($staged.Count) file(s) staged." -ForegroundColor Cyan

# ── Phase 3: Generate commit message ────────────────────────────────────────

$aiMessage = Get-AiCommitMessage ((git diff --cached) -join "`n")
if (-not $aiMessage) {
	$aiMessage = ""
	Write-Host "[info] AI unavailable (install copilot CLI for auto-generation)." -ForegroundColor DarkGray
}

# ── Phase 4: Edit commit message ────────────────────────────────────────────

$tempFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.txt'

Set-Content $tempFile $aiMessage -Encoding UTF8

if (Ensure-Micro) {
	micro $tempFile
} else {
	# Fallback: show message and offer inline edit
	Write-Host ""
	Write-Host "Commit message:" -ForegroundColor Cyan
	Write-Host $aiMessage -ForegroundColor White
	Write-Host ""
	Write-Host "Press Enter to keep, or type a new message: " -ForegroundColor Cyan -NoNewline
	$userInput = [Console]::ReadLine()
	if ($userInput.Trim()) {
		Set-Content $tempFile $userInput.Trim() -Encoding UTF8
	} elseif (-not $aiMessage) {
		Write-Host "No message entered. Aborted." -ForegroundColor Red
		Remove-Item $tempFile -ErrorAction SilentlyContinue
		git reset HEAD 2>$null
		exit 1
	}
}

$commitMessage = (Get-Content $tempFile -Raw -Encoding UTF8).Trim()

Remove-Item $tempFile -ErrorAction SilentlyContinue

if (-not $commitMessage) {
	Write-Host "Empty commit message. Aborted." -ForegroundColor Red
	git reset HEAD 2>$null
	exit 1
}

# Show staged files and final message
$stagedFiles = @(git diff --cached --name-status)
$stagedParsed = Parse-StatusLines $stagedFiles
$total = $stagedParsed.Count
$shown = $stagedParsed | Select-Object -First 20

Write-Host ""
foreach ($f in $shown) {
	$color = switch ($f.Status) { 'A' { "Green" } 'D' { "Red" } 'M' { "DarkYellow" } default { "DarkGray" } }
	$display = if ($f.OldPath) { "$($f.OldPath) -> $($f.Path)" } else { $f.Path }
	Write-Host "  $($f.Status)  $display" -ForegroundColor $color
}
if ($total -gt 20) {
	Write-Host "  ... and $($total - 20) more" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Commit message:" -ForegroundColor Cyan
Write-Host $commitMessage -ForegroundColor White
Write-Host ""
if (-not (Confirm-Action "Commit?")) {
	Write-Host "Aborted." -ForegroundColor DarkGray
	git reset HEAD 2>$null
	exit 0
}

# ── Phase 5: Commit ─────────────────────────────────────────────────────────

$msgFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "COMMIT_MSG.txt")
Set-Content $msgFile $commitMessage -Encoding UTF8

Write-Host ""
git commit -F $msgFile
$commitExit = $LASTEXITCODE

Remove-Item $msgFile -ErrorAction SilentlyContinue

if ($commitExit -ne 0) {
	Write-Host "Commit failed." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

Write-Host "Committed." -ForegroundColor Green

# ── Phase 6: Offer push ────────────────────────────────────────────────────

$pushBranch = git rev-parse --abbrev-ref HEAD 2>$null
if (-not $pushBranch -or $pushBranch -eq 'HEAD') { exit 0 }

$ErrorActionPreference = "Continue"
$pushRemote = git config --get "branch.$pushBranch.remote" 2>$null
$ErrorActionPreference = "Stop"
if (-not $pushRemote) { $pushRemote = "origin" }

Write-Host ""
$Host.UI.RawUI.FlushInputBuffer()
Write-Host "Push? [y/N] " -ForegroundColor Cyan -NoNewline
$pushKey = [Console]::ReadKey($true)
Write-Host $pushKey.KeyChar

if ($pushKey.KeyChar -match '^[Yy]$') {
	$ErrorActionPreference = "Continue"
	$aheadCommits = @(git log --format="%H" "${pushRemote}/${pushBranch}..HEAD" 2>$null)
	$ErrorActionPreference = "Stop"

	$doPush = $true
	if ($aheadCommits.Count -gt 1) {
		$doPush = Invoke-PushReview -Remote $pushRemote -Branch $pushBranch
	}

	if ($doPush) {
		Write-Host ""
		Write-Host "Pushing to $pushRemote/$pushBranch..." -ForegroundColor Cyan
		$ErrorActionPreference = "Continue"
		git push -u $pushRemote $pushBranch
		$pushExit = $LASTEXITCODE
		$ErrorActionPreference = "Stop"
		if ($pushExit -ne 0) {
			Write-Host "Push failed." -ForegroundColor Red
		} else {
			Write-Host "Pushed." -ForegroundColor Green
			Invoke-PrCreate
		}
	} else {
		Write-Host "Push skipped." -ForegroundColor DarkGray
	}
} else {
	Write-Host "Push skipped." -ForegroundColor DarkGray
}
