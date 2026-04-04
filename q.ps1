param(
	[string]$WorkDir,
	[switch]$NoCache
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$MAX_RECENT = 5

if ($WorkDir) { Set-Location $WorkDir }

# Find repo root preserving symlinks
$ErrorActionPreference = "Continue"
$null = git rev-parse --is-inside-work-tree 2>$null
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -ne 0) {
	Write-Host "Error: not a git repository." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

$repoRoot   = Get-RepoRoot
$currentDir = (Get-Location).Path

$configDir  = Join-Path $PSScriptRoot "Configuration"
$configFile = Join-Path $configDir "Build.json"

function Get-RepoKey {
	$key = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "get.ps1") `
		-WorkDir $repoRoot -Command repository -AsKey 2>$null
	return ($key | Select-Object -Last 1).Trim()
}

function Read-BuildConfig([string]$RepoKey) {
	if (-not (Test-Path $configFile)) { return $null }
	$config = Get-Content $configFile -Raw | ConvertFrom-Json
	if ($config.PSObject.Properties[$RepoKey]) {
		return $config.$RepoKey
	}
	return $null
}

function Write-BuildConfig([string]$RepoKey, [string[]]$Files, [string[]]$Recent) {
	$config = [ordered]@{}
	if (Test-Path $configFile) {
		$existing = Get-Content $configFile -Raw | ConvertFrom-Json
		foreach ($prop in $existing.PSObject.Properties) {
			$config[$prop.Name] = $prop.Value
		}
	}
	$config[$RepoKey] = [PSCustomObject]@{
		files  = $Files
		recent = $Recent
	}
	if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir | Out-Null }

	# Serialize with compact arrays
	$sb = [System.Text.StringBuilder]::new()
	$sb.AppendLine("{") | Out-Null
	$keys = @($config.Keys)
	for ($i = 0; $i -lt $keys.Count; $i++) {
		$k     = $keys[$i]
		$val   = $config[$k]
		$comma = if ($i -lt $keys.Count - 1) { "," } else { "" }
		$sb.AppendLine("    $($k | ConvertTo-Json): {") | Out-Null

		$f = @(if ($val.PSObject.Properties['files']) { $val.files } else { $val })
		$sb.AppendLine("        `"files`": [") | Out-Null
		for ($j = 0; $j -lt $f.Count; $j++) {
			$vc = if ($j -lt $f.Count - 1) { "," } else { "" }
			$sb.AppendLine("            $($f[$j] | ConvertTo-Json)$vc") | Out-Null
		}
		$sb.AppendLine("        ],") | Out-Null

		$r = @(if ($val.PSObject.Properties['recent']) { $val.recent } else { @() })
		$sb.AppendLine("        `"recent`": [") | Out-Null
		for ($j = 0; $j -lt $r.Count; $j++) {
			$vc = if ($j -lt $r.Count - 1) { "," } else { "" }
			$sb.AppendLine("            $($r[$j] | ConvertTo-Json)$vc") | Out-Null
		}
		$sb.AppendLine("        ]") | Out-Null

		$sb.AppendLine("    }$comma") | Out-Null
	}
	$sb.Append("}") | Out-Null
	$sb.ToString() | Set-Content $configFile -Encoding UTF8
}

# Recursively find Build.xml files, excluding dot-folders at any level
function Find-BuildFiles([string]$Dir) {
	foreach ($item in Get-ChildItem -LiteralPath $Dir -Force) {
		if ($item.PSIsContainer) {
			if ($item.Name -notmatch '^\.' ) {
				Find-BuildFiles $item.FullName
			}
		} elseif ($item.Name -eq "Build.xml") {
			$item.FullName
		}
	}
}

function ConvertTo-RelEntry([string]$FilePath) {
	$dir = Split-Path $FilePath -Parent
	if ($dir.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
		$rel = $dir.Substring($repoRoot.Length).TrimStart('\')
		if ($rel -eq "") { return "." } else { return $rel }
	}
	return $dir
}

# ── Resolve file list ─────────────────────────────────────────────────────────

$scanMessageShown = $false

if ($NoCache -or -not (Test-Path $configFile)) {
	Write-Host "Scanning for Build.xml files..." -ForegroundColor DarkGray
	$scanMessageShown = $true
}

$repoKey = Get-RepoKey
$files   = $null
$recent  = @()

if (-not $NoCache -and $repoKey) {
	$cached = Read-BuildConfig $repoKey
	if ($cached) {
		$cachedFiles  = @(if ($cached.PSObject.Properties['files'])  { $cached.files }  else { $cached })
		$recent       = @(if ($cached.PSObject.Properties['recent']) { $cached.recent } else { @() })
		# Check if cached files match current repo root (may differ for worktrees vs main repo)
		if ($cachedFiles.Count -gt 0 -and $cachedFiles[0].StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
			$files = $cachedFiles
		}
	}
}

if (-not $files) {
	if (-not $scanMessageShown) {
		Write-Host "Scanning for Build.xml files..." -ForegroundColor DarkGray
	}
	$files = @(Find-BuildFiles $repoRoot)
	if ($files.Count -eq 0) {
		Write-Host "No Build.xml files found." -ForegroundColor Yellow
		Wait-AnyKey
		exit 0
	}
	if ($repoKey) { Write-BuildConfig $repoKey $files $recent }
}

# Filter to files under current directory for display, but keep full list for cache
$visibleFiles = @($files | Where-Object { $_.StartsWith($currentDir, [System.StringComparison]::OrdinalIgnoreCase) })

if ($visibleFiles.Count -eq 0) {
	Write-Host "No Build.xml files found under current directory." -ForegroundColor Yellow
	Wait-AnyKey
	exit 0
}

# ── Build display entries ─────────────────────────────────────────────────────

$allEntries    = @($visibleFiles | ForEach-Object { ConvertTo-RelEntry $_ })
$recentEntries = @($recent | Where-Object {
	$_.StartsWith($currentDir, [System.StringComparison]::OrdinalIgnoreCase)
} | ForEach-Object { ConvertTo-RelEntry $_ } | Where-Object { $allEntries -contains $_ })

$restEntries = @($allEntries | Where-Object { $recentEntries -notcontains $_ })

$menuEntries = if ($recentEntries.Count -gt 0) {
	@($recentEntries) + @("") + @($restEntries)
} else {
	@($restEntries)
}

$selected = $menuEntries | fzf `
	--style=minimal --no-input --disabled --height=50% --no-info --layout=reverse `
	--pointer=">" --gutter=" " `
	--color="pointer:green,fg+:green:bold,bg+:-1" `
	--header="Select Build.xml:" `
	--header-first

if (-not $selected -or $selected.Trim() -eq "") { exit 0 }

# Find matching full path
$idx = for ($i = 0; $i -lt $allEntries.Count; $i++) {
	if ($allEntries[$i] -eq $selected) { $i; break }
}

$selectedFile = $visibleFiles[$idx]

# Update recent list — prepend selected, deduplicate, keep last 5
$newRecent = @($selectedFile) + @($recent | Where-Object { $_ -ne $selectedFile }) | Select-Object -First $MAX_RECENT
if ($repoKey) { Write-BuildConfig $repoKey $files $newRecent }

# Select build mode
$mode = @("FullBuild", "Build", "QuickBuild") | fzf `
	--style=minimal --no-input --disabled --height=~5 --no-info --layout=reverse `
	--pointer=">" --gutter=" " `
	--color="pointer:green,fg+:green:bold,bg+:-1" `
	--header="Select build mode:" `
	--header-first

if (-not $mode) { exit 0 }

$buildDir = Split-Path $selectedFile -Parent
$cmd = "qgl build -m $mode --skip-network-check -p `"$buildDir`""
Write-Host $cmd -ForegroundColor DarkGray
Invoke-Expression $cmd