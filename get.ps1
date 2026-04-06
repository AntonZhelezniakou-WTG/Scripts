param(
	[string]$WorkDir,
	[string]$Command,
	[switch]$NoCache,
	[switch]$AsKey
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common\common.ps1")

function Read-RepoJson([string]$MainPath) {
	$file = Join-Path $MainPath ".repo.json"
	if (-not (Test-Path $file)) { return $null }
	return Get-Content $file -Raw | ConvertFrom-Json
}

function Write-RepoJson([string]$MainPath, [string]$Name) {
	$file = Join-Path $MainPath ".repo.json"
	$obj  = [PSCustomObject]@{ Name = $Name }
	$obj | ConvertTo-Json -Depth 2 | Set-Content $file -Encoding UTF8
}

function Update-RepositoryConfig([string]$Root, [string]$Name, [string]$Remote) {
	$configDir  = Join-Path $PSScriptRoot "Configuration"
	$configFile = Join-Path $configDir "Repositories.json"

	$repos = @()
	if (Test-Path $configFile) {
		$repos = @(Get-Content $configFile -Raw | ConvertFrom-Json)
	}

	$repos = @($repos | Where-Object { $_.Path -ne $Root })
	$repos += [PSCustomObject]@{ Path = $Root; Name = $Name; Remote = $Remote }

	if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir | Out-Null }
	$repos | ConvertTo-Json -Depth 3 | Set-Content $configFile -Encoding UTF8
}

function Get-RepositoryFromConfig([string]$Root) {
	$configFile = Join-Path $PSScriptRoot "Configuration\Repositories.json"
	if (-not (Test-Path $configFile)) { return $null }
	$repos = @(Get-Content $configFile -Raw | ConvertFrom-Json)
	return $repos | Where-Object { $_.Path -eq $Root } | Select-Object -First 1
}

function ConvertTo-JsonKey([string]$Value) {
	return $Value.Replace('\', '/').Replace(':', '_')
}

function Out-RepositoryName([string]$Name, [string]$Root) {
	$isPath = ($Name -eq $Root)
	$value  = if ($AsKey -and $isPath) { ConvertTo-JsonKey $Name } else { $Name }
	$color  = if ($isPath -and -not $AsKey) { "White" } else { "Cyan" }
	Write-Host $value -ForegroundColor $color
}

function Get-Repository {
	$root = Get-RepoRoot
	if (-not $root) {
		Write-Host "Cannot determine repository root." -ForegroundColor Red
		exit 1
	}

	$mainPath = Get-MainWorktreePath $root

	if (-not $NoCache) {
		# 1. Try .repo.json in main worktree
		if ($mainPath) {
			$repoJson = Read-RepoJson $mainPath
			if ($repoJson -and $repoJson.Name) {
				Out-RepositoryName $repoJson.Name $root
				return
			}
		}

		# 2. Try Repositories.json config
		$cached = Get-RepositoryFromConfig $root
		if ($cached -and $cached.Name) {
			Out-RepositoryName $cached.Name $root
			return
		}
	}

	# 3. Load from git remote
	$remoteUrl = git -C $root remote get-url origin 2>$null
	if ($LASTEXITCODE -ne 0 -or -not $remoteUrl) {
		$firstRemote = git -C $root remote 2>$null | Select-Object -First 1
		if ($firstRemote) {
			$remoteUrl = git -C $root remote get-url $firstRemote 2>$null
		}
	}

	if (-not $remoteUrl) {
		Update-RepositoryConfig $root $root ""
		if ($mainPath) { Write-RepoJson $mainPath $root }
		Out-RepositoryName $root $root
		return
	}

	$remoteUrl = $remoteUrl.Trim()

	if ($remoteUrl -match 'github\.com[:/](.+?)(?:\.git)?$') {
		$name = $Matches[1]
		Update-RepositoryConfig $root $name $remoteUrl
		if ($mainPath) { Write-RepoJson $mainPath $name }
		Out-RepositoryName $name $root
		return
	}

	Update-RepositoryConfig $root $root $remoteUrl
	if ($mainPath) { Write-RepoJson $mainPath $root }
	Out-RepositoryName $root $root
}

# ── Setup ────────────────────────────────────────────────────────────────────

if ($WorkDir) { Set-Location $WorkDir }

git rev-parse --is-inside-work-tree 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
	Write-Host "Error: not a git repository." -ForegroundColor Red
	exit 1
}

if (-not $Command) {
	Write-Host "Usage: get <command>" -ForegroundColor Yellow
	Write-Host "Commands: repository"
	exit 1
}

switch ($Command.ToLower()) {
	"repository" { Get-Repository }
	default {
		Write-Host "Unknown command: '$Command'" -ForegroundColor Red
		Write-Host "Commands: repository"
		exit 1
	}
}