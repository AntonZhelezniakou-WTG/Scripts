param(
	[string]$WorkDir,
	[switch]$NoCache,
	[Parameter(ValueFromRemainingArguments)]
	[string[]]$Files
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

# MSBuild tool paths
$msbuildPath = "C:\Program Files\Microsoft Visual Studio\18\Professional\MSBuild\Current\Bin\MSBuild.exe"
$devenvPath  = "C:\Program Files\Microsoft Visual Studio\18\Professional\Common7\IDE\devenv.exe"

# Allow --no-cache passed as a plain string argument (e.g. from cmd wrappers)
if ($Files -contains '--no-cache') {
	$NoCache = $true
	$Files   = @($Files | Where-Object { $_ -ne '--no-cache' })
}

# Strip empty/whitespace strings cmd may inject when %* is empty
$Files = @($Files | Where-Object { $_ -and $_.Trim() -ne '' })

if ($WorkDir) { Set-Location $WorkDir }

$ErrorActionPreference = "Continue"
$null = git rev-parse --is-inside-work-tree 2>$null
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -ne 0) {
	Write-Host "Error: not a git repository." -ForegroundColor Red
	Wait-AnyKey
	exit 1
}

# Dispatch based on file extensions passed as arguments
$solutionFiles = @($Files | Where-Object { $_ -match '\.(sln|slnx|csproj)$' })
$xmlFiles      = @($Files | Where-Object { $_ -match '(?i)Build\.xml$' })
$unknownFiles  = @($Files | Where-Object { $_ -notmatch '\.(sln|slnx|csproj)$' -and $_ -notmatch '(?i)Build\.xml$' })

if ($unknownFiles.Count -gt 0) {
	Write-Host "Error: unrecognized file type(s): $($unknownFiles -join ', ')" -ForegroundColor Red
	Write-Host "Pass .sln / .slnx / .csproj for MSBuild, or Build.xml for qgl build." -ForegroundColor Yellow
	Wait-AnyKey
	exit 1
}

# =============================================================================
# MSBuild logic — triggered by .sln / .slnx / .csproj arguments
# =============================================================================
if ($solutionFiles.Count -gt 0) {
	if (-not (Test-Path $msbuildPath)) {
		Write-Host "Error: MSBuild not found at: $msbuildPath" -ForegroundColor Red
		Wait-AnyKey
		exit 1
	}

	Write-Host ""
	Write-Host "Starting build of $($solutionFiles.Count) solution(s)..." -ForegroundColor Cyan

	foreach ($sln in $solutionFiles) {
		$name  = Split-Path $sln -Leaf
		$built = $false

		while (-not $built) {
			Write-Host ""
			Write-Host "Building: $name" -ForegroundColor Cyan
			Write-Host "Path    : $sln"  -ForegroundColor DarkGray

			$ErrorActionPreference = "Continue"
			& $msbuildPath $sln /restore /p:RestorePackagesConfig=true /p:Configuration=Debug "/p:Platform=Any CPU"
			$rc = $LASTEXITCODE
			$ErrorActionPreference = "Stop"

			if ($rc -eq 0) {
				Write-Host "Built successfully: $name" -ForegroundColor Green
				$built = $true
			} else {
				Write-Host "Build failed: $name (exit $rc)" -ForegroundColor Red

				if ((Test-Path $devenvPath) -and (Confirm-Action "Open '$name' in Visual Studio?")) {
					Start-Process $devenvPath $sln
				}

				if (-not (Confirm-Action "Retry build?")) {
					exit $rc
				}
			}
		}
	}

	Write-Host ""
	Write-Host "All solutions built successfully." -ForegroundColor Green
	exit 0
}

# =============================================================================
# qgl build logic — triggered by Build.xml argument or no arguments
# =============================================================================
$repoRoot   = Get-RepoRoot
$mainRoot   = Get-MainWorktreePath -RepoRoot $repoRoot
if (-not $mainRoot) { $mainRoot = $repoRoot }
$currentDir = (Get-Location).Path
$configDir  = Join-Path $PSScriptRoot "Configuration"
$configFile = Join-Path $configDir "Build.json"
$MAX_RECENT = 5

function Get-RepoKey {
	$key = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "get.ps1") `
		-WorkDir $mainRoot -Command repository -AsKey 2>$null
	return ($key | Select-Object -Last 1).Trim()
}

function Read-BuildConfig([string]$RepoKey) {
	if (-not (Test-Path $configFile)) { return $null }
	$config = Get-Content $configFile -Raw | ConvertFrom-Json
	if ($config.PSObject.Properties[$RepoKey]) { return $config.$RepoKey }
	return $null
}

function Write-BuildConfig([string]$RepoKey, [string[]]$BuildFiles, [string[]]$Recent) {
	$config = [ordered]@{}
	if (Test-Path $configFile) {
		$existing = Get-Content $configFile -Raw | ConvertFrom-Json
		foreach ($prop in $existing.PSObject.Properties) { $config[$prop.Name] = $prop.Value }
	}
	$config[$RepoKey] = [PSCustomObject]@{ files = $BuildFiles; recent = $Recent }
	if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir | Out-Null }

	$sb = [System.Text.StringBuilder]::new()
	$sb.AppendLine("{") | Out-Null
	$keys = @($config.Keys)
	for ($i = 0; $i -lt $keys.Count; $i++) {
		$k     = $keys[$i]
		$val   = $config[$k]
		$comma = if ($i -lt $keys.Count - 1) { "," } else { "" }
		$sb.AppendLine("    $($k | ConvertTo-Json): {") | Out-Null

		$f = @(if ($val.PSObject.Properties['files'])  { $val.files }  else { $val })
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

function Find-BuildFiles([string]$Dir) {
	foreach ($item in Get-ChildItem -LiteralPath $Dir -Force) {
		if ($item.PSIsContainer) {
			if ($item.Name -notmatch '^\.' ) { Find-BuildFiles $item.FullName }
		} elseif ($item.Name -eq "Build.xml") {
			$item.FullName
		}
	}
}

# Convert an absolute Build.xml path to a display label (directory relative to repo root)
function ConvertTo-RelEntry([string]$FilePath) {
	$dir = Split-Path $FilePath -Parent
	if ($dir.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
		$rel = $dir.Substring($repoRoot.Length).TrimStart('\')
		return ($rel -eq "") ? "." : $rel
	}
	return $dir
}

# Convert an absolute path to a repo-relative path for storage in the cache.
# Always strips the main repo root so the same relative path works in any worktree.
function ConvertTo-CacheRelPath([string]$AbsPath) {
	if ($AbsPath.StartsWith($mainRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
		return $AbsPath.Substring($mainRoot.Length).TrimStart('\')
	}
	return $AbsPath
}

$repoKey = Get-RepoKey

# If a specific Build.xml was passed, skip scanning and go straight to mode selection
if ($xmlFiles.Count -gt 0) {
	$selectedFile = (Resolve-Path $xmlFiles[0]).Path
} else {
	$forceRescan = $NoCache

	while ($true) {
		$allFiles = $null
		$recent   = @()

		if (-not $forceRescan -and $repoKey) {
			$cached = Read-BuildConfig $repoKey
			if ($cached) {
				$cachedFiles  = @(if ($cached.PSObject.Properties['files'])  { $cached.files }  else { $cached })
				$cachedRecent = @(if ($cached.PSObject.Properties['recent']) { $cached.recent } else { @() })
				# Cache stores repo-relative paths — reconstruct as absolute using the current repo root.
				# Reject old-format caches that stored absolute paths (IsPathRooted = true).
				if ($cachedFiles.Count -gt 0 -and -not [System.IO.Path]::IsPathRooted($cachedFiles[0])) {
					$allFiles = @($cachedFiles  | ForEach-Object { Join-Path $repoRoot $_ })
					$recent   = @($cachedRecent | ForEach-Object { Join-Path $repoRoot $_ })
				}
			}
		}

		if (-not $allFiles) {
			Write-Host "Scanning for Build.xml files..." -ForegroundColor DarkGray
			# Always scan from the main repo root so the full file list is cached once,
			# then reconstruct with $repoRoot so paths exist on disk in this worktree too.
			$scannedFiles = @(Find-BuildFiles $mainRoot)
			if ($scannedFiles.Count -eq 0) {
				Write-Host "No Build.xml files found." -ForegroundColor Yellow
				Wait-AnyKey
				exit 0
			}
			$allFiles = @($scannedFiles | ForEach-Object { Join-Path $repoRoot (ConvertTo-CacheRelPath $_) })
			if ($repoKey) {
				$relFiles = @($scannedFiles | ForEach-Object { ConvertTo-CacheRelPath $_ })
				Write-BuildConfig $repoKey $relFiles @()
			}
		}

		$forceRescan = $false

		$visibleFiles = @($allFiles | Where-Object { $_.StartsWith($currentDir, [System.StringComparison]::OrdinalIgnoreCase) })
		if ($visibleFiles.Count -eq 0) {
			Write-Host "No Build.xml files found under current directory." -ForegroundColor Yellow
			Wait-AnyKey
			exit 0
		}

		$allEntries    = @($visibleFiles | ForEach-Object { ConvertTo-RelEntry $_ })
		$recentEntries = @($recent | Where-Object {
			$_.StartsWith($currentDir, [System.StringComparison]::OrdinalIgnoreCase)
		} | ForEach-Object { ConvertTo-RelEntry $_ } | Where-Object { $allEntries -contains $_ })
		$restEntries   = @($allEntries | Where-Object { $recentEntries -notcontains $_ })

		$menuEntries = if ($recentEntries.Count -gt 0) {
			@($recentEntries) + @("") + @($restEntries)
		} else {
			@($restEntries)
		}

		$output = $menuEntries | fzf `
			--style=minimal --no-input --disabled --height=50% --no-info --layout=reverse `
			--pointer=">" --gutter=" " `
			--color="pointer:green,fg+:green:bold,bg+:-1" `
			--header="Select Build.xml (Ctrl+R: rescan):" `
			--header-first `
			--expect="ctrl-r"

		$lines    = @($output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
		$key      = if ($lines.Count -ge 2) { $lines[0] } else { "" }
		$selected = if ($lines.Count -ge 2) { $lines[1] } elseif ($lines.Count -eq 1 -and $key -ne "ctrl-r") { $lines[0] } else { "" }

		if ($key -eq "ctrl-r") {
			Write-Host "Rescanning for Build.xml files..." -ForegroundColor Cyan
			$forceRescan = $true
			continue
		}

		if (-not $selected -or $selected.Trim() -eq "") { exit 0 }

		$idx = for ($i = 0; $i -lt $allEntries.Count; $i++) {
			if ($allEntries[$i] -eq $selected) { $i; break }
		}
		$selectedFile = $visibleFiles[$idx]

		$newRecent = @($selectedFile) + @($recent | Where-Object { $_ -ne $selectedFile }) | Select-Object -First $MAX_RECENT
		if ($repoKey) {
			$relFiles  = @($allFiles  | ForEach-Object { ConvertTo-CacheRelPath $_ })
			$relRecent = @($newRecent | ForEach-Object { ConvertTo-CacheRelPath $_ })
			Write-BuildConfig $repoKey $relFiles $relRecent
		}
		break
	}
}

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
