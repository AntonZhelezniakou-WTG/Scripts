param(
	[string]$WorkDir
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

if ($WorkDir) { Set-Location $WorkDir }

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

git rev-parse --is-inside-work-tree 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
	Write-Host "Error: not a git repository." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

if (-not (Ensure-Fzf)) { Wait-AnyKey; exit 1 }

while ($true) {
	$stashes = Get-Stashes

	if ($stashes.Count -eq 0) {
		Write-Host "No stashes found." -ForegroundColor Yellow
		Wait-AnyKey
		exit 0
	}

	$menuEntries = $stashes | ForEach-Object { $_.Name }

	$lines = $menuEntries | fzf `
		--style=minimal --no-input --disabled --height=40% --no-info --layout=reverse `
		--pointer=">" --gutter=" " `
		--color="pointer:green,fg+:green:bold,bg+:-1" `
		--header="Select stash (Enter=apply, Del=drop, Esc=quit):" `
		--header-first `
		--expect="del,esc"

	if (-not $lines) { exit 0 }

	$keyUsed = $lines[0].Trim()
	$rawLine = if ($lines.Count -gt 1) { $lines[1].Trim() } else { "" }

	if ($keyUsed -eq "esc" -or -not $rawLine) { exit 0 }

	$selectedName = $rawLine.Trim()
	$stash        = $stashes | Where-Object { $_.Name -eq $selectedName } | Select-Object -First 1
	if (-not $stash) { continue }

	# DELETE
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

	# APPLY
	if (-not (Confirm-Action "Apply '$($stash.Name)'?")) {
		continue
	}

	$ErrorActionPreference = "Continue"
	$dirtyBefore = git status --porcelain --ignored=no 2>$null
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