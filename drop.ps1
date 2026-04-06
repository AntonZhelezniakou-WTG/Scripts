param(
	[Parameter(Position = 0)]
	[string]$Command,
	[string]$WorkDir
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common\common.ps1")

if ($Command -ne "latest") {
	Write-Host "Usage: drop latest" -ForegroundColor Yellow
	Write-Host "  Permanently drops the last commit and all its changes." -ForegroundColor DarkGray
	exit 1
}

if ($WorkDir) { Set-Location $WorkDir }

$branch = git rev-parse --abbrev-ref HEAD 2>&1
if ($LASTEXITCODE -ne 0) {
	Write-Host "Not a git repository." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

# Get last commit info
$message = git log -1 --format="%s"
$hash = git log -1 --format="%h"

Write-Host ""
Write-Host "Last commit on " -NoNewline
Write-Host "$branch" -ForegroundColor Cyan -NoNewline
Write-Host ":"
Write-Host "  $hash $message" -ForegroundColor Yellow
Write-Host ""

# Show changed files (up to 20)
$files = git diff-tree --no-commit-id --name-status -r HEAD
$total = ($files | Measure-Object).Count

if ($total -eq 0) {
	Write-Host "  (no file changes)" -ForegroundColor DarkGray
} else {
	$shown = $files | Select-Object -First 20
	foreach ($line in $shown) {
		if ($line -match '^(\w)\t(.+)$') {
			$status = $Matches[1]
			$path = $Matches[2]
			$color = switch ($status) {
				'A' { "Green" }
				'D' { "Red" }
				'M' { "DarkYellow" }
				default { "DarkGray" }
			}
			Write-Host "  $status  $path" -ForegroundColor $color
		} else {
			Write-Host "  $line" -ForegroundColor DarkGray
		}
	}
	if ($total -gt 20) {
		Write-Host "  ... and $($total - 20) more" -ForegroundColor DarkGray
	}
}

Write-Host ""
Write-Host "WARNING: This will permanently discard the commit and all its changes!" -ForegroundColor Red
if (-not (Confirm-Action "Drop this commit?")) {
	Write-Host "Aborted." -ForegroundColor Red
	exit 0
}

git reset --hard HEAD~1
if ($LASTEXITCODE -ne 0) {
	Write-Host "Failed to drop commit." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

Write-Host "Commit dropped." -ForegroundColor Green
