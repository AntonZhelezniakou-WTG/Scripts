param(
	[string]$WorkDir,
	[switch]$ListOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Common\common.ps1")

# This command deliberately targets the exact repository requested by the user.
$sourceRoot = 'D:\GitHub\WiseTechGlobal\CargoWise'
$folders = @('.claude', '.config', '.github', '.paket', '.venv', 'packages', 'paket-files')

function Get-CWPumpGitValue {
	param([string]$Directory, [string]$Option)

	$ErrorActionPreference = "Continue"
	$value = git -C $Directory rev-parse --path-format=absolute $Option 2>$null
	$gitExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($gitExit -ne 0 -or -not $value) {
		throw "Cannot identify a Git worktree at '$Directory'."
	}
	return $value.Trim()
}

function Get-CWPumpNormalizedPath {
	param([string]$Path)
	return [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($Path))
}

try {
	if ($WorkDir) { Set-Location -LiteralPath $WorkDir }
	if ($env:GIT_DIR -or $env:GIT_WORK_TREE -or $env:GIT_COMMON_DIR) {
		throw 'Unset GIT_DIR, GIT_WORK_TREE and GIT_COMMON_DIR before running CWPump.'
	}
	if ((Get-CWPumpGitValue (Get-Location).Path '--is-inside-work-tree') -ne 'true') {
		throw 'The current directory is not inside a Git worktree.'
	}
	$sourceCommon = Get-CWPumpNormalizedPath (Get-CWPumpGitValue $sourceRoot '--git-common-dir')
	$targetCommon = Get-CWPumpNormalizedPath (Get-CWPumpGitValue (Get-Location).Path '--git-common-dir')
	$targetGitDir = Get-CWPumpNormalizedPath (Get-CWPumpGitValue (Get-Location).Path '--absolute-git-dir')
	if ($sourceCommon -ine $targetCommon -or $targetGitDir -ieq $sourceCommon) {
		throw "Run CWPump inside a linked worktree of '$sourceRoot', not in the main checkout or another repository."
	}
	$ErrorActionPreference = "Continue"
	$targetRoot = Get-RepoRoot
	$rootExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"
	if ($rootExit -ne 0 -or -not $targetRoot) { throw 'Cannot determine the worktree root.' }

	$robocopy = (Get-Command robocopy.exe -CommandType Application -ErrorAction Stop).Source
	$robocopyHelp = & $robocopy /? | Out-String
	if ($robocopyHelp -notmatch '/NOCLONE') {
		throw 'This robocopy version does not support block cloning. Windows 11 24H2 / Windows Server 2025 or newer is required.'
	}

	Write-Host "Source:    $sourceRoot" -ForegroundColor Cyan
	Write-Host "Worktree:  $targetRoot" -ForegroundColor Cyan
	Write-Host 'Block cloning is enabled where supported (source and destination must share a ReFS volume).' -ForegroundColor DarkGray
	if ($ListOnly) { Write-Host 'Preview only; no files will be copied.' -ForegroundColor Yellow }

	# Validate all seven folders before overwriting anything. Destination links
	# could redirect writes outside this worktree, including back into the source.
	foreach ($folder in $folders) {
		$source = Join-Path $sourceRoot $folder
		$destination = Join-Path $targetRoot $folder
		$sourceItem = Get-Item -LiteralPath $source -Force
		if (-not $sourceItem.PSIsContainer -or ($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
			throw "Source must be a regular directory: '$source'."
		}
		$destinationItem = Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
		if ($destinationItem) {
			if (-not $destinationItem.PSIsContainer -or ($destinationItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
				throw "Destination must be a regular directory: '$destination'."
			}
			foreach ($link in (Get-ChildItem -LiteralPath $destination -Force -Recurse -Attributes ReparsePoint)) {
				$relativePath = [System.IO.Path]::GetRelativePath($destination, $link.FullName)
				$sourceLink = Get-Item -LiteralPath (Join-Path $source $relativePath) -Force -ErrorAction SilentlyContinue
				# /SL and /SJ handle matching source links without following them.
				# Allow these so links copied on a previous run remain repeatable.
				if ($sourceLink -and $link.LinkType -in @('SymbolicLink', 'Junction') -and
					$sourceLink.LinkType -eq $link.LinkType -and $sourceLink.LinkTarget -ceq $link.LinkTarget) {
					continue
				}
				throw "Destination contains a link without an identical source link; replace it before syncing: '$($link.FullName)'."
			}
		}
	}

	# /IS and /IT overwrite even files with equal size/timestamps or changed attributes.
	# /E preserves destination-only files; /SL and /SJ copy source links as links.
	# Modern robocopy attempts ReFS block cloning by default: do not add /NOCLONE.
	# Leave native output unpiped for live per-file percentages and ETA.
	$options = @('/E', '/COPY:DAT', '/DCOPY:DAT', '/IS', '/IT', '/SL', '/SJ', '/R:2', '/W:1', '/ETA')
	if ($ListOnly) { $options += '/L' }
	for ($index = 0; $index -lt $folders.Count; $index++) {
		$folder = $folders[$index]
		Write-Host "`n[$($index + 1)/$($folders.Count)] $folder" -ForegroundColor Cyan
		$ErrorActionPreference = "Continue"
		& $robocopy (Join-Path $sourceRoot $folder) (Join-Path $targetRoot $folder) @options
		$copyExit = $LASTEXITCODE
		$ErrorActionPreference = "Stop"
		# 0..3 allow successful copies and destination-only extras. Bit 4 means
		# a file/directory mismatch: this sync is incomplete even below code 8.
		if ($copyExit -ge 4 -or $copyExit -lt 0) {
			throw "Robocopy failed or found a file/directory mismatch in '$folder' (exit code $copyExit). Some files may already have been copied."
		}
	}
	$message = if ($ListOnly) { 'CWPump preview complete.' } else { 'CWPump complete: all 7 folders copied.' }
	Write-Host "`n$message" -ForegroundColor Green
	exit 0
} catch {
	Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
	exit 1
}
