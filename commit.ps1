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

function Parse-StatusLines([string[]]$Lines) {
	$result = @()
	foreach ($line in $Lines) {
		if ($line -match '^([MADRCT])\d*\t(.+?)(?:\t(.+))?$') {
			$status  = $Matches[1]
			$oldPath = $Matches[2]
			$newPath = $Matches[3]
			$result += [PSCustomObject]@{
				Status  = $status
				Path    = if ($newPath) { $newPath } else { $oldPath }
				OldPath = if ($newPath) { $oldPath } else { $null }
			}
		}
	}
	return $result | Sort-Object Path
}

function Build-FzfEntries($Parsed) {
	$esc   = [char]27
	$reset = "$esc[0m"
	return @($Parsed | ForEach-Object {
		$color = switch ($_.Status) {
			'M' { "$esc[33m" }   # yellow
			'A' { "$esc[32m" }   # green
			'D' { "$esc[31m" }   # red
			'R' { "$esc[36m" }   # cyan
			'C' { "$esc[36m" }   # cyan
			default { "" }
		}
		$display = if ($_.OldPath) { "$($_.OldPath) -> $($_.Path)" } else { $_.Path }
		"${color}$($_.Status)${reset}   $display"
	})
}

function Extract-PathFromFzfLine([string]$Line) {
	$clean = $Line -replace '\e\[[0-9;]*m', ''
	$path  = ($clean -split '\s+', 2)[1].Trim()
	# Handle rename display: "old -> new" — take the new path
	if ($path -match ' -> (.+)$') { return $Matches[1] }
	return $path
}

function Get-AiCommitMessage {
	if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) { return $null }

	$diff = (git diff --cached) -join "`n"
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
	$result = (copilot -p $prompt -s --no-auto-update 2>$null)
	$exit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"

	if ($exit -ne 0 -or -not $result) {
		Write-Host "[warn] copilot failed (exit $exit)." -ForegroundColor Yellow
		return $null
	}

	$text = ($result -join "`n").Trim()
	# Strip Co-authored-by trailers added by Copilot
	$text = ($text -replace '(?m)^\s*Co-authored-by:.*$', '').Trim()
	if ($text) { return $text }
	return $null
}

# ── Validate ────────────────────────────────────────────────────────────────

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
		'--style=minimal', '--height=60%', '--no-info', '--layout=reverse'
		'--pointer=>', '--gutter= ', '--marker=>'
		'--color=pointer:green,fg+:green:bold,bg+:-1'
		'--header=Space=toggle, Del=discard, Enter=confirm, Esc=cancel'
		'--header-first'
		'--bind=start:select-all+hide-input'
		'--bind=space:toggle'
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

$aiMessage = Get-AiCommitMessage
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

Write-Host ""
Write-Host "Push? [y/N] " -ForegroundColor Cyan -NoNewline
$key = [Console]::ReadKey($true)
Write-Host $key.KeyChar

if ($key.KeyChar -match '^[Yy]$') {
	$pushScript = Join-Path $PSScriptRoot "push.ps1"
	& $pushScript
}
