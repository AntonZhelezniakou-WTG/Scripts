param(
	[Parameter(Mandatory)]
	[string]$Repo,
	[string]$Directory,
	[string]$CdFile
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot "common.ps1")

# Build owner list from Paths.json: defaultOwner first, then all ownerAliases
$_cfg    = Get-PathsConfig
$owners  = @($_cfg.defaultOwner) + @($_cfg.ownerAliases | ForEach-Object { $_.githubOwner })

# Determine if $Repo is a full URL or just a name
if ($Repo -match "^https?://" -or $Repo -match "^git@") {
	$Url = $Repo
} else {
	# Search for repo by name across known owners
	$Url = $null
	foreach ($owner in $owners) {
		$testUrl = "https://github.com/$owner/$Repo.git"
		$ErrorActionPreference = "Continue"
		$null = git ls-remote --exit-code $testUrl HEAD 2>$null
		$ErrorActionPreference = "Stop"
		if ($LASTEXITCODE -eq 0) {
			Write-Host "Found: $owner/$Repo" -ForegroundColor Cyan
			$Url = $testUrl
			break
		}
	}
	if (-not $Url) {
		Write-Host "Error: repository '$Repo' not found in: $($owners -join ', ')" -ForegroundColor Red
		exit 1
	}
}

# Detect default branch on remote (master or main)
Write-Host "Detecting default branch..." -ForegroundColor DarkGray
$ErrorActionPreference = "Continue"
$headRef = git ls-remote --symref $Url HEAD 2>$null | Select-String "^ref:" | Select-Object -First 1
$ErrorActionPreference = "Stop"

$defaultBranch = $null
if ($headRef -and $headRef -match "refs/heads/(\S+)") {
	$defaultBranch = $Matches[1]
}

if (-not $defaultBranch) {
	# Fallback: check if master or main exists
	$ErrorActionPreference = "Continue"
	$refs = git ls-remote --heads $Url 2>$null
	$ErrorActionPreference = "Stop"
	if ($refs -match "refs/heads/master\b") {
		$defaultBranch = "master"
	} elseif ($refs -match "refs/heads/main\b") {
		$defaultBranch = "main"
	} else {
		Write-Host "Error: could not detect master or main branch on remote." -ForegroundColor Red
		exit 1
	}
}

Write-Host "Default branch: $defaultBranch" -ForegroundColor Cyan

# Determine target directory
if (-not $Directory) {
	$Directory = ($Url -replace "\.git$", "" -split "[/:]")[-1]
}

# Clone with single-branch to fetch only the default branch
git clone --single-branch --branch $defaultBranch $Url $Directory
if ($LASTEXITCODE -ne 0) {
	Write-Host "Error: clone failed." -ForegroundColor Red
	exit 1
}

Write-Host "Done. Cloned with only '$defaultBranch'." -ForegroundColor Green

# Signal cmd wrapper to cd into the cloned directory
$fullPath = (Resolve-Path $Directory).Path
if ($CdFile) {
	$fullPath | Set-Content $CdFile -Encoding ASCII
}
exit 0