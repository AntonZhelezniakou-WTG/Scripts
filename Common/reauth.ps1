param(
	[Parameter(ValueFromRemainingArguments)]
	[string[]]$Roots
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

if (-not $Roots -or $Roots.Count -eq 0) {
	$cfg = Get-PathsConfig
	$Roots = @($cfg.githubBase) | Where-Object { $_ -and (Test-Path $_) }
	if (-not $Roots) {
		Write-Host "Usage: reauth [<root> ...]" -ForegroundColor Yellow
		Write-Host "No default root — set githubBase in Configuration/Paths.json or pass one." -ForegroundColor Yellow
		exit 1
	}
}

$count = 0
foreach ($root in $Roots) {
	if (-not (Test-Path $root)) {
		Write-Host "Skipping (not found): $root" -ForegroundColor Yellow
		continue
	}
	Write-Host "== Scanning $root ==" -ForegroundColor Cyan

	# Depth-limited: most layouts are {root}/{owner}/{repo} or {root}/{repo}.
	# A main repo has .git as a directory; worktrees have .git as a file — skipped naturally.
	Get-ChildItem -Path $root -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
		$lvl1 = $_.FullName
		if (Test-Path (Join-Path $lvl1 '.git') -PathType Container) {
			Write-Host "  $lvl1"
			Apply-GitUser $lvl1
			$count++
			return
		}
		Get-ChildItem -Path $lvl1 -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
			$lvl2 = $_.FullName
			if (Test-Path (Join-Path $lvl2 '.git') -PathType Container) {
				Write-Host "  $lvl2"
				Apply-GitUser $lvl2
				$count++
			}
		}
	}
}

Write-Host ""
Write-Host "Reapplied to $count repo(s)." -ForegroundColor Green
