param(
	[Parameter(Mandatory)]
	[string]$Repo,
	[string]$Directory,
	[string]$CdFile
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot "Common\common.ps1")

# Build owner list from Paths.json: defaultOwner first, then all ownerAliases
$_cfg    = Get-PathsConfig
$owners  = @($_cfg.defaultOwner) + @($_cfg.ownerAliases | ForEach-Object { $_.githubOwner })

# Determine if $Repo is a full URL or just a name
if ($Repo -match "^https?://" -or $Repo -match "^git@") {
	$Url = $Repo
	# Embed repo owner as URL username so credential manager selects the correct account
	if ($Url -match "^https://github\.com/([^/]+)/") {
		$Url = $Url -replace "^https://github\.com/", "https://$($Matches[1])@github.com/"
	}
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

$isEmptyRepo = $false

if (-not $defaultBranch) {
	# Fallback: check if master or main exists
	$ErrorActionPreference = "Continue"
	$refs = git ls-remote --heads $Url 2>$null
	$refsExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($refsExit -ne 0) {
		Write-Host "Error: repository '$Url' not found or not accessible." -ForegroundColor Red
		Write-Host "If this is a private repo, check that your git credentials have access." -ForegroundColor Yellow
		exit 1
	}
	if ($refs -match "refs/heads/master\b") {
		$defaultBranch = "master"
	} elseif ($refs -match "refs/heads/main\b") {
		$defaultBranch = "main"
	} else {
		# Empty repository — ask user to name the initial branch
		$defaultBranch = Select-InitialBranch
		if (-not $defaultBranch) { exit 0 }
		$isEmptyRepo = $true
	}
}

Write-Host "Default branch: $defaultBranch" -ForegroundColor Cyan

# Determine target directory — strip trailing slashes and .git suffix before taking the leaf name
if (-not $Directory) {
	$Directory = ($Url -replace "\.git/?$", "" -replace "/+$", "" -split "[/:]")[-1]
}

if ($isEmptyRepo) {
	# Clone the empty repo (no --branch flag), then initialise the branch and push
	git clone $Url $Directory
	if ($LASTEXITCODE -ne 0) {
		Write-Host "Error: clone failed." -ForegroundColor Red
		exit 1
	}

	$fullPath = (Resolve-Path $Directory).Path
	Push-Location $fullPath
	$ok = Initialize-EmptyRepoBranch $defaultBranch
	Pop-Location

	if (-not $ok) { exit 1 }
} else {
	# Ask user to confirm or rename the main branch
	$chosenBranch = Select-MainBranchName -DetectedBranch $defaultBranch
	if (-not $chosenBranch) { exit 0 }

	# Clone with single-branch to fetch only the default branch
	git clone --single-branch --branch $defaultBranch $Url $Directory
	if ($LASTEXITCODE -ne 0) {
		Write-Host "Error: clone failed." -ForegroundColor Red
		exit 1
	}

	if ($chosenBranch -ne $defaultBranch) {
		$fullPath = (Resolve-Path $Directory).Path
		Push-Location $fullPath
		$ok = Rename-DefaultBranch -OldBranch $defaultBranch -NewBranch $chosenBranch -RepoUrl $Url
		Pop-Location
		if (-not $ok) { exit 1 }
		$defaultBranch = $chosenBranch
	}

	Write-Host "Done. Cloned with only '$defaultBranch'." -ForegroundColor Green
}

$fullPath = (Resolve-Path $Directory).Path

# Signal cmd wrapper to cd into the cloned directory (write before Apply-GitUser so it always happens)
if ($CdFile) {
	[System.IO.File]::WriteAllText($CdFile, $fullPath, [System.Text.Encoding]::ASCII)
}

# Apply .gituser settings if found in parent hierarchy
Apply-GitUser $fullPath

# Rename current Windows Terminal tab to the repo name
if ($env:WT_SESSION) {
	$repoName = ($Url -replace "\.git/?$", "" -replace "/+$", "" -split "[/:]")[-1]
	[Console]::Write("`e]0;$repoName`a")
}

exit 0