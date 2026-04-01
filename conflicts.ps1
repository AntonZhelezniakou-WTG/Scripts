# Resolve merge or stash-pop conflicts interactively.
# Called from other scripts after a merge/pull/stash-pop produces conflicts.
#
# Parameters:
#   -AbortCommand  git command to abort the operation (e.g. "merge --abort", "rebase --abort")
#                  ignored when -Mode stash is used
#   -CommitMessage commit message to use after resolving conflicts (merge mode only)
#   -Mode          "merge" (default) or "stash"
#   -StashRef      stash ref to drop after resolving (stash mode only, e.g. "stash@{0}")
#
# Exit codes:
#   0 - conflicts resolved (and committed in merge mode / stash dropped in stash mode)
#   1 - aborted or failed

param(
	[string]$AbortCommand,
	[string]$CommitMessage,
	[ValidateSet("merge", "stash")]
	[string]$Mode = "merge",
	[string]$StashRef
)

function Wait-AnyKey {
	Write-Host "Press any key to continue..." -ForegroundColor Yellow
	$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

$gitExtensions = "C:\Program Files\GitExtensions\GitExtensions.exe"

Write-Host ""
Write-Host "[warn] Conflicts detected." -ForegroundColor Yellow

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
		Write-Host "[info] Aborting..." -ForegroundColor Yellow
		if ($Mode -eq "stash") {
			git checkout HEAD -- .
		} else {
			Invoke-Expression "git $AbortCommand"
		}
		exit 1
	}

	# Check for unresolved conflicts
	$unresolved = git status --porcelain 2>$null | Where-Object { $_ -match '^(UU|AA|DD)' }
	if ($unresolved) {
		Write-Host "[warn] Conflicts still present. Resolve them first." -ForegroundColor Yellow
		if (Test-Path $gitExtensions) {
			& $gitExtensions mergeconflicts
		}
		continue
	}

	if ($Mode -eq "stash") {
		# No commit needed - just drop the stash
		if ($StashRef) {
			git stash drop $StashRef 2>$null
		}
		Write-Host "Stash conflicts resolved." -ForegroundColor Green
		exit 0
	}

	# Merge mode: stage and commit
	$ErrorActionPreference = "Continue"
	git diff --cached --exit-code 2>$null
	$hasStagedChanges = $LASTEXITCODE -ne 0
	$ErrorActionPreference = "Stop"

	if ($hasStagedChanges) {
		git add .
		git commit -m $CommitMessage
		if ($LASTEXITCODE -ne 0) {
			Write-Host "Commit failed." -ForegroundColor Red
			Wait-AnyKey
			exit 1
		}
	}

	Write-Host "Merge committed successfully." -ForegroundColor Green
	exit 0
}