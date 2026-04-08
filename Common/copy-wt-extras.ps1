# Copies extra (non-git-tracked) folders from the main repo root into a new worktree.
#
# Global folders (all repos): edit $GlobalExtraFolders below.
# Per-repo folders: edit Configuration\Paths.json — "wtExtraFolders" array,
#   each entry: { "repo": "Owner/Name", "folders": [ ".config", ".idea" ] }
#
# Usage (PowerShell): . copy-wt-extras.ps1; Copy-WtExtras -RepoRoot <path> -WtPath <path>
# Usage (cmd tab):    pwsh -NoProfile -ExecutionPolicy Bypass -File "<path>\copy-wt-extras.ps1" -RepoRoot <path> -WtPath <path>

param(
	[string]$RepoRoot,
	[string]$WtPath
)

# ── Global folders (copied for every repo) ────────────────────────────────────
$GlobalExtraFolders = @(
	".github"
)
# ─────────────────────────────────────────────────────────────────────────────

function Copy-WtExtras {
	param([string]$RepoRoot, [string]$WtPath)

	$folders = [System.Collections.Generic.List[string]]::new()
	foreach ($f in $GlobalExtraFolders) { $folders.Add($f) }

	# Load per-repo folders from Paths.json
	$configPath = Join-Path $PSScriptRoot "..\Configuration\Paths.json"
	if (Test-Path $configPath) {
		$ErrorActionPreference = "Continue"
		$config = Get-Content $configPath -Raw | ConvertFrom-Json
		$ErrorActionPreference = "Stop"

		if ($config.wtExtraFolders) {
			$ErrorActionPreference = "Continue"
			$remoteUrl = git -C $RepoRoot remote get-url origin 2>$null
			$ErrorActionPreference = "Stop"
			$repoFullName = if ($remoteUrl -match 'github\.com[/:](.+?)(?:\.git)?\s*$') { $Matches[1].Trim() } else { $null }

			if ($repoFullName) {
				$entry = $config.wtExtraFolders | Where-Object { $_.repo -ieq $repoFullName } | Select-Object -First 1
				if ($entry -and $entry.folders) {
					foreach ($f in $entry.folders) { if ($f -notin $folders) { $folders.Add($f) } }
				}
			}
		}
	}

	foreach ($folder in $folders) {
		$src = Join-Path $RepoRoot $folder
		if (-not (Test-Path $src)) { continue }
		$dst = Join-Path $WtPath $folder
		Copy-Item -Path $src -Destination $dst -Recurse -Force
		Write-Host "[info] Copied $folder" -ForegroundColor DarkGray
	}
}

# Allow running as a standalone script (called from cmd tab scripts)
if ($RepoRoot -and $WtPath) {
	Copy-WtExtras -RepoRoot $RepoRoot -WtPath $WtPath
}
