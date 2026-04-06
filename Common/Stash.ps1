# Stash helpers.

# Stash changes with a label. Returns $true if something was actually stashed.
function Invoke-Stash([string]$RepoPath, [string]$Label) {
	$before = (git -C $RepoPath stash list 2>$null | Measure-Object).Count
	$ErrorActionPreference = "Continue"
	git -C $RepoPath stash push -m $Label 2>$null | Out-Host
	$exit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($exit -ne 0) {
		Write-Host "Stash failed." -ForegroundColor Red
		Wait-AnyKey
		exit 1
	}
	$after = (git -C $RepoPath stash list 2>$null | Measure-Object).Count
	return [bool]($after -gt $before)
}

# Pop the top stash entry, resolving conflicts via conflicts.ps1 if needed.
function Invoke-StashPop([string]$RepoPath) {
	Write-Host "Restoring stashed changes..." -ForegroundColor Cyan

	$stashRef = git -C $RepoPath stash list --max-count=1 --format="%gd" 2>$null

	$ErrorActionPreference = "Continue"
	git -C $RepoPath stash pop | Out-Host
	$exit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"

	if ($exit -ne 0) {
		$conflictsScript = Join-Path (Split-Path $PSScriptRoot -Parent) "conflicts.ps1"
		Push-Location $RepoPath
		& $conflictsScript -Mode stash -StashRef $stashRef
		Pop-Location
	}
}
