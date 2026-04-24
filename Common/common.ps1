# Shared functions for git workflow scripts.
# Usage: . (Join-Path $PSScriptRoot "Common\common.ps1")

. (Join-Path $PSScriptRoot "Git.ps1")
. (Join-Path $PSScriptRoot "Stash.ps1")
. (Join-Path $PSScriptRoot "FzfTree.ps1")
. (Join-Path $PSScriptRoot "copy-wt-extras.ps1")

# Pause until any key is pressed.
function Wait-AnyKey {
	Write-Host "Press any key to continue..." -ForegroundColor Yellow
	$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# Prompt user with [Y/n]. Returns $true if confirmed.
function Confirm-Action {
	param([string]$Message, [ConsoleColor]$Color = "Cyan")
	Write-Host "$Message [Y/n] " -ForegroundColor $Color -NoNewline
	$key = [Console]::ReadKey($true)
	Write-Host $key.KeyChar
	return ($key.KeyChar -match '^[Yy]$' -or $key.Key -eq 'Enter')
}

# After a successful push, check if a PR already exists for the current branch.
# If not, offer to create one (y/N, default N).
function Invoke-PrCreate {
	$ErrorActionPreference = "Continue"
	$branch = git rev-parse --abbrev-ref HEAD 2>$null
	$ErrorActionPreference = "Stop"
	if (-not $branch -or $branch -eq 'HEAD') { return }

	$ErrorActionPreference = "Continue"
	$prJson = gh pr view --json number,url 2>$null
	$prExit = $LASTEXITCODE
	$ErrorActionPreference = "Stop"

	if ($prExit -eq 0 -and $prJson) {
		$pr = $prJson | ConvertFrom-Json
		Write-Host "PR already exists: $($pr.url)" -ForegroundColor DarkGray
		return
	}

	Write-Host ""
	Write-Host "Create PR? [y/N] " -ForegroundColor Cyan -NoNewline
	$key = [Console]::ReadKey($true)
	Write-Host $key.KeyChar
	if ($key.KeyChar -notmatch '^[Yy]$') { return }

	Write-Host ""
	$ErrorActionPreference = "Continue"
	gh pr create --fill
	$ErrorActionPreference = "Stop"
}

# Get repo root from $PWD, preserving symlinks (unlike git rev-parse --show-toplevel).
function Get-RepoRoot {
	$gitCwd     = (git rev-parse --show-prefix 2>$null)
	if ($null -eq $gitCwd) { return $null }
	$gitCwd     = $gitCwd.TrimEnd('/')
	$currentDir = (Get-Location).Path
	if ($gitCwd) {
		$depth = ($gitCwd -split '/').Count
		$root  = $currentDir
		for ($i = 0; $i -lt $depth; $i++) { $root = Split-Path $root -Parent }
		return $root
	}
	return $currentDir
}

# Search parent directories (starting from $RepoPath inclusive) for a .gituser file
# and apply its settings to the repo's local .git/config, overwriting existing keys.
#
# Supports an optional [github] section:
#   [github]
#       user = MyGitHubLogin
# When present:
#   - sets credential."https://github.com".username so GCM picks the account without prompting
#   - embeds the login into remote.origin.url as a secondary hint
function Apply-GitUser {
	param([string]$RepoPath)

	$dir = $RepoPath
	while ($dir) {
		$candidate = Join-Path $dir ".gituser"
		if (Test-Path $candidate) {
			$settings = git config --file $candidate --list 2>$null
			if ($settings) {
				foreach ($line in $settings) {
					if ($line -match '^(.+?)=(.*)$') {
						git -C $RepoPath config --local $Matches[1] $Matches[2]
					}
				}
				Write-Host "Applied .gituser: $candidate" -ForegroundColor DarkGray
			}

			$githubUser = (git -C $RepoPath config --local github.user 2>$null)?.Trim()
			if ($githubUser) {
				# Tell GCM which account to use — this is what actually prevents the picker
				git -C $RepoPath config --local 'credential.https://github.com.username' $githubUser

				# Route github.com credential lookups through gh's keyring-backed token store.
				# The empty-value entry resets the inherited helper list (GCM) for github.com URLs,
				# so gh becomes the sole helper and GCM never runs its browser refresh flow here.
				$ghCmd = Get-Command gh -ErrorAction SilentlyContinue
				if ($ghCmd) {
					$ErrorActionPreference = "Continue"
					git -C $RepoPath config --local --unset-all 'credential.https://github.com.helper' 2>$null
					$ErrorActionPreference = "Stop"
					git -C $RepoPath config --local --add 'credential.https://github.com.helper' ''
					git -C $RepoPath config --local --add 'credential.https://github.com.helper' '!gh auth git-credential'
					Write-Host "  Credential helper: gh (user $githubUser)" -ForegroundColor DarkGray
				} else {
					Write-Host "  gh CLI not found — leaving GCM as credential helper" -ForegroundColor DarkYellow
				}

				# Also embed in remote URL as a secondary hint
				$currentUrl = (git -C $RepoPath remote get-url origin 2>$null)?.Trim()
				if ($currentUrl -match '^https://(?:[^@]+@)?github\.com/') {
					$newUrl = "https://$githubUser@github.com/" + ($currentUrl -replace '^https://(?:[^@]+@)?github\.com/', '')
					git -C $RepoPath remote set-url origin $newUrl
				}
				Write-Host "  GCM account: $githubUser" -ForegroundColor DarkGray
			}
			return
		}
		$parent = Split-Path $dir -Parent
		if ($parent -eq $dir) { break }
		$dir = $parent
	}
}

# Load Paths.json config. Returns defaults if file is missing.
function Get-PathsConfig {
	$configPath = Join-Path $PSScriptRoot "..\Configuration\Paths.json"
	if (Test-Path $configPath) {
		return Get-Content $configPath -Raw | ConvertFrom-Json
	}
	return [PSCustomObject]@{
		githubBase      = "C:\git\GitHub"
		worktreeBase    = "D:\wt"
		defaultOwner    = "WiseTechGlobal"
		ownerAliases    = @()
		worktreeAliases = @()
	}
}

# Get remote repo names for a GitHub owner from Configuration\RepoCache.json.
# Fetches via gh CLI when ForceRefresh is set or entry is absent.
# Cache has no automatic expiry — refresh explicitly with -ForceRefresh.
function Get-CachedRemoteRepos {
	param([string]$Owner, [switch]$ForceRefresh)

	$cachePath = Join-Path $PSScriptRoot "..\Configuration\RepoCache.json"
	$cache = @{}
	if (Test-Path $cachePath) {
		try { $cache = Get-Content $cachePath -Raw | ConvertFrom-Json -AsHashtable } catch {}
	}

	if (-not $ForceRefresh -and $cache.ContainsKey($Owner) -and $cache[$Owner].repos) {
		return @($cache[$Owner].repos)
	}

	if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
		return if ($cache.ContainsKey($Owner)) { @($cache[$Owner].repos) } else { @() }
	}

	$ErrorActionPreference = "Continue"
	$json = gh repo list $Owner --limit 200 --json name 2>$null
	$ErrorActionPreference = "Stop"

	$repos = @()
	if ($json) {
		try { $repos = @(($json | ConvertFrom-Json) | ForEach-Object { $_.name }) } catch {}
	}

	$cache[$Owner] = @{ cachedAt = (Get-Date -Format 'o'); repos = $repos }

	$configDir = Join-Path $PSScriptRoot "..\Configuration"
	if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
	$cache | ConvertTo-Json -Depth 3 | Set-Content $cachePath -Encoding UTF8

	return $repos
}

# Compute the worktree subfolder name from a branch name.
# Short mode (shortFolderNames = true in config):
#   - drops path prefix (e.g. AEM/ is stripped)
#   - strips leading WI (case-insensitive) when immediately followed by a digit
#   - truncates to 30 characters
# Standard mode: replaces / with _
function Get-WtFolderName {
	param([string]$BranchName, [bool]$Short = $false)
	if ($Short) {
		$name = $BranchName -replace '^.+/', ''          # drop prefix: AEM/foo -> foo
		$name = $name -replace '(?i)^WI(?=\d)', ''       # WI00123... -> 00123...
		if ($name.Length -gt 30) { $name = $name.Substring(0, 30) }
		return $name
	}
	return $BranchName -replace '/', '_'
}

# Resolve worktree root and target path for a branch.
# Worktrees are stored under worktreeBase (Paths.json), e.g. D:\wt\{repo}\{branch}.
# worktreeAliases can override the folder name and enable short folder names (max 30 chars).
function Get-WtPath {
	param([string]$BranchName)
	$config   = Get-PathsConfig
	$wtBase   = $config.worktreeBase
	$repoRoot = Get-RepoRoot
	$repoName = Split-Path $repoRoot -Leaf

	# Derive full repo name (Owner/Repo) from remote URL for alias lookup
	$ErrorActionPreference = "Continue"
	$remoteUrl = git remote get-url origin 2>$null
	$ErrorActionPreference = "Stop"
	$fullName = if ($remoteUrl -match 'github\.com[/:](.+?)(?:\.git)?\s*$') { $Matches[1].Trim() } else { $repoName }

	# Check worktree aliases for folder name override and short-name flag
	$wtFolder  = $repoName
	$useShort  = $false
	foreach ($alias in $config.worktreeAliases) {
		if ($alias.repo -ieq $fullName) {
			if ($alias.worktreeFolder) { $wtFolder = $alias.worktreeFolder }
			$useShort = [bool]$alias.shortFolderNames
			break
		}
	}

	$wtRoot     = Join-Path $wtBase $wtFolder
	$folderName = Get-WtFolderName -BranchName $BranchName -Short $useShort
	return [PSCustomObject]@{
		WtRoot   = $wtRoot
		WtPath   = Join-Path $wtRoot $folderName
		RepoRoot = $repoRoot
	}
}

# Resolve the actual on-disk path of an existing worktree by branch name.
# Uses `git worktree list` output, so it's immune to folder-name truncation bugs.
# Returns $null if the branch is not checked out in any worktree.
function Get-ExistingWtPath {
	param([string]$BranchName)
	$lines = git worktree list --porcelain 2>$null
	$currentPath = $null
	foreach ($line in $lines) {
		if ($line -match '^worktree\s+(.+)$') {
			$currentPath = $Matches[1].Trim()
		} elseif ($line -match '^branch\s+refs/heads/(.+)$') {
			if ($Matches[1].Trim() -eq $BranchName) {
				return $currentPath
			}
		}
	}
	return $null
}

# Find the main worktree path (where .git is a directory, not a file).
# Falls back to git worktree list, which handles both old (.{repo}.wt) and
# new (D:\wt\{folder}) worktree locations.
function Get-MainWorktreePath {
	param([string]$RepoRoot)
	if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot }
	$gitEntry = Join-Path $RepoRoot ".git"

	# Already main worktree — .git is a directory
	if ([System.IO.Directory]::Exists($gitEntry)) { return $RepoRoot }

	# Fallback: git worktree list
	# git outputs paths with forward slashes on Windows — normalise to backslashes
	# so that string comparisons (StartsWith etc.) work correctly against PS paths.
	$lines = git worktree list --porcelain 2>$null
	foreach ($line in $lines) {
		if ($line -match '^worktree (.+)') {
			$wt = $Matches[1].Trim().Replace('/', '\')
			if ([System.IO.Directory]::Exists((Join-Path $wt ".git"))) {
				return $wt
			}
		}
	}
	return $null
}

# Run fzf with standard minimal style. Pass extra args as needed.
function Invoke-Fzf {
	param(
		[string[]]$Entries,
		[string[]]$ExtraArgs
	)
	$Entries | fzf `
		--style=minimal --no-input --disabled --height=40% --no-info --layout=reverse `
		--pointer=" " --gutter=" " `
		@ExtraArgs
}

# Register a fetch refspec for a branch in .git/config if not already present.
function Ensure-FetchRefspec {
	param([string]$BranchName)
	$refspec      = "+refs/heads/${BranchName}:refs/remotes/origin/${BranchName}"
	$gitCommonDir = git rev-parse --git-common-dir
	$existing     = git config --file "$gitCommonDir/config" --get-all remote.origin.fetch 2>$null
	if ($existing -notcontains $refspec) {
		git config --file "$gitCommonDir/config" --add remote.origin.fetch $refspec
		Write-Host "[config] Registered fetch refspec for: $BranchName" -ForegroundColor DarkGray
	}
}

# Fetch a single branch from origin.
function Fetch-Branch {
	param([string]$BranchName)
	$ErrorActionPreference = "Continue"
	git fetch origin "${BranchName}:refs/remotes/origin/${BranchName}" 2>$null
	$ErrorActionPreference = "Stop"
}

# Remove fetch refspec, remote-tracking ref, and branch config section.
function Remove-GitBranchConfig {
	param([string]$BranchName)
	$gitCommonDir = git rev-parse --git-common-dir
	$configFile   = "$gitCommonDir/config"

	# Remove fetch refspec
	$refspec  = "+refs/heads/${BranchName}:refs/remotes/origin/${BranchName}"
	$existing = git config --file $configFile --get-all remote.origin.fetch 2>$null
	if ($existing -contains $refspec) {
		git config --file $configFile --unset remote.origin.fetch ([regex]::Escape($refspec))
		Write-Host "[config] Removed fetch refspec for: $BranchName" -ForegroundColor DarkGray
	}

	# Remove remote-tracking ref
	$ErrorActionPreference = "Continue"
	git update-ref -d "refs/remotes/origin/$BranchName" 2>$null
	$ErrorActionPreference = "Stop"

	# Remove [branch "name"] config section
	$ErrorActionPreference = "Continue"
	git config --file $configFile --remove-section "branch.$BranchName" 2>$null
	$ErrorActionPreference = "Stop"

	Write-Host "[config] Cleaned git config for: $BranchName" -ForegroundColor DarkGray
}

# Prompt user to choose a name for the main branch via fzf.
# Shows the detected remote name first. Returns branch name or $null if cancelled.
function Select-MainBranchName {
	param([string]$DetectedBranch)

	if (-not (Ensure-Fzf)) { return $DetectedBranch }

	$options = @($DetectedBranch)
	$alt = if ($DetectedBranch -eq "master") { "main" } elseif ($DetectedBranch -eq "main") { "master" } else { $null }
	if ($alt) { $options += $alt }
	$options += "custom..."

	$picked = $options | fzf `
		--style=minimal --no-input --disabled --height=~5 --no-info --layout=reverse `
		--pointer=">" --gutter=" " `
		--color="pointer:green,fg+:green:bold,bg+:-1" `
		--header="Main branch name (remote: $DetectedBranch):" `
		--header-first

	if (-not $picked) { return $null }

	if ($picked -eq "custom...") {
		Write-Host "Branch name: " -NoNewline -ForegroundColor Cyan
		$branchName = ([Console]::ReadLine()).Trim()
		if (-not $branchName) { return $null }
		return $branchName
	}

	return $picked
}

# Rename the default branch locally and on the remote.
# Must be called from within the repo directory.
function Rename-DefaultBranch {
	param(
		[string]$OldBranch,
		[string]$NewBranch,
		[string]$RepoUrl
	)

	Write-Host "Renaming default branch: $OldBranch -> $NewBranch..." -ForegroundColor Cyan

	# Rename local branch
	git branch -m $OldBranch $NewBranch

	# Push new branch to remote and set tracking
	git push -u origin $NewBranch
	if ($LASTEXITCODE -ne 0) {
		Write-Host "Error: failed to push '$NewBranch' to remote." -ForegroundColor Red
		return $false
	}

	# Change default branch on GitHub via API
	$ghUpdated = $false
	if ($RepoUrl -match 'github\.com[/:](.+?)(?:\.git)?$') {
		$slug = $Matches[1]
		$ErrorActionPreference = "Continue"
		$null = gh api "repos/$slug" -X PATCH -f default_branch=$NewBranch 2>$null
		$ghUpdated = ($LASTEXITCODE -eq 0)
		$ErrorActionPreference = "Stop"
	}

	if ($ghUpdated) {
		# Delete old remote branch
		$ErrorActionPreference = "Continue"
		git push origin --delete $OldBranch 2>$null
		$ErrorActionPreference = "Stop"
	} else {
		Write-Host "Warning: could not update default branch on GitHub (gh CLI needed). Old branch '$OldBranch' retained on remote." -ForegroundColor Yellow
	}

	# Clean up old remote-tracking ref
	$ErrorActionPreference = "Continue"
	git update-ref -d "refs/remotes/origin/$OldBranch" 2>$null
	$ErrorActionPreference = "Stop"

	# Fix fetch refspec (--single-branch clone has exactly one)
	git config remote.origin.fetch "+refs/heads/${NewBranch}:refs/remotes/origin/${NewBranch}"

	# Update remote HEAD ref
	git remote set-head origin $NewBranch

	return $true
}

# Prompt user to pick an initial branch name for an empty repo via fzf.
# Returns the branch name, or $null if cancelled.
function Select-InitialBranch {
	if (-not (Ensure-Fzf)) { return $null }

	Write-Host "Repository is empty. Choose a name for the initial branch:" -ForegroundColor Yellow

	$picked = @("master", "main", "custom...") | fzf `
		--style=minimal --no-input --disabled --height=~5 --no-info --layout=reverse `
		--pointer=">" --gutter=" " `
		--color="pointer:green,fg+:green:bold,bg+:-1" `
		--header="Select initial branch name:" `
		--header-first

	if (-not $picked) { return $null }

	if ($picked -eq "custom...") {
		Write-Host "Branch name: " -NoNewline -ForegroundColor Cyan
		$branchName = ([Console]::ReadLine()).Trim()
	} else {
		$branchName = $picked
	}

	if (-not $branchName) { return $null }
	return $branchName
}

# Initialize an empty repo: set HEAD to the chosen branch, create an initial commit, push.
# Returns $true on success, $false on failure.
function Initialize-EmptyRepoBranch {
	param([string]$BranchName)

	git symbolic-ref HEAD "refs/heads/$BranchName"
	git commit --allow-empty -m "Initial commit"
	git push -u origin $BranchName
	$pushExit = $LASTEXITCODE

	if ($pushExit -ne 0) {
		Write-Host "Error: failed to push initial branch '$BranchName'." -ForegroundColor Red
		return $false
	}

	Write-Host "Done. Created branch '$BranchName' and pushed initial commit." -ForegroundColor Green
	return $true
}

# Check if fzf is installed; offer to install via winget if not.
function Ensure-Fzf {
	if (Get-Command fzf -ErrorAction SilentlyContinue) { return $true }

	Write-Host "fzf is not installed. It is required for interactive menus." -ForegroundColor Yellow
	Write-Host ""
	Write-Host -NoNewline "Install fzf now via winget? [Y/n]: "
	$key = [Console]::ReadKey($true)
	Write-Host $key.KeyChar

	if ($key.Key -eq "Enter" -or $key.KeyChar -match "^[Yy]$") {
		winget install fzf
		if ($LASTEXITCODE -ne 0 -or -not (Get-Command fzf -ErrorAction SilentlyContinue)) {
			Write-Host "Failed to install fzf. Please install it manually: winget install fzf" -ForegroundColor Red
			return $false
		}
		$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
		            [System.Environment]::GetEnvironmentVariable("PATH", "User")
		Write-Host "fzf installed successfully." -ForegroundColor Green
		return $true
	}

	Write-Host "Aborted." -ForegroundColor Red
	return $false
}

# Copy extra folders from main repo root into worktree.
# The list of folders is defined in Common\copy-wt-extras.ps1.
function Copy-GitHubFolder {
	param([string]$RepoRoot, [string]$WtPath)
	Copy-WtExtras -RepoRoot $RepoRoot -WtPath $WtPath
}

# Build a pwsh call to copy extra folders for use in cmd tab scripts.
function Get-CopyGitHubLine {
	param([string]$RepoRoot, [string]$WtPath)
	$script = Join-Path $PSScriptRoot "copy-wt-extras.ps1"
	return "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$script`" -RepoRoot `"$RepoRoot`" -WtPath `"$WtPath`""
}

# Interactive pre-push review. Shows commits ahead of remote as a two-level fzf menu.
# Level 1 — commit list: Enter=inspect files, Ctrl+Enter=push, Esc=cancel.
# Level 2 — file list for a commit: preview shows file diff, Esc=back to commit list.
# Returns $true if user confirmed push (Ctrl+Enter), $false to cancel.
function Invoke-PushReview {
	param([string]$Remote, [string]$Branch)

	$esc   = [char]27
	$reset = "$esc[0m"

	while ($true) {
		$commits = @(git log --format="%H %s" "${Remote}/${Branch}..HEAD" 2>$null)

		if ($commits.Count -eq 0) {
			Write-Host "Nothing to push." -ForegroundColor Yellow
			return $false
		}

		# Build tab-separated entries: visible subject | hidden hash
		$entries = $commits | ForEach-Object {
			$hash    = $_.Substring(0, 40)
			$subject = if ($_.Length -gt 41) { $_.Substring(41) } else { "" }
			"$subject`t$hash"
		}

		$lines = $entries | fzf `
			--style=minimal --no-input --disabled --height=60% --no-info --layout=reverse `
			--ansi `
			'--header=Enter=inspect files  Ctrl+Enter=push  Esc=cancel' `
			--header-first `
			'--pointer=>' '--gutter= ' `
			'--color=pointer:green,fg+:green:bold,bg+:-1' `
			"--delimiter=`t" `
			'--with-nth=1' `
			'--preview=git show --stat --color=always {2}' `
			'--preview-window=right,60%,wrap' `
			'--expect=ctrl-j'

		if (-not $lines) { return $false }

		$keyUsed  = $lines[0].Trim()
		$selected = if ($lines.Count -gt 1) { $lines[1] } else { $null }

		if ($keyUsed -eq 'ctrl-j') { return $true }
		if (-not $selected)        { return $false }

		# Enter — drill into changed files for this commit
		$parts   = $selected -split "`t", 2
		$subject = $parts[0].Trim()
		$hash    = if ($parts.Count -ge 2) { $parts[1].Trim() } else { $null }
		if (-not $hash) { continue }

		$fileLines = @(git diff-tree --no-commit-id -r --name-status $hash 2>$null)
		if (-not $fileLines) { continue }

		$fileEntries = $fileLines | ForEach-Object {
			if ($_ -match '^([MADRCT])\s+(.+)$') {
				$st   = $Matches[1]
				$path = $Matches[2]
				$col  = switch ($st) {
					'M' { "$esc[33m" } 'A' { "$esc[32m" } 'D' { "$esc[31m" } default { "" }
				}
				"${col}${st}${reset}   ${path}`t${path}"
			}
		} | Where-Object { $_ }

		$null = $fileEntries | fzf `
			--style=minimal --no-input --disabled --height=60% --no-info --layout=reverse `
			--ansi `
			"--header=$subject  (Esc=back)" `
			--header-first `
			'--pointer=>' '--gutter= ' `
			'--color=pointer:green,fg+:green:bold,bg+:-1' `
			"--delimiter=`t" `
			'--with-nth=1' `
			"--preview=git show --color=always $hash -- {2}" `
			'--preview-window=right,60%,wrap'

		# Loop back to commit list
	}
}

# Read the current working directory of a process via PEB (Windows, 64-bit host).
# Returns the CWD string or $null on failure.
# Loaded once per session via Add-Type.
function Initialize-ProcessCwdType {
	if (([System.Management.Automation.PSTypeName]'ProcessCwd').Type) { return }
	Add-Type -ErrorAction SilentlyContinue -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class ProcessCwd {
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool   CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool   ReadProcessMemory(IntPtr hProcess, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
    [DllImport("ntdll.dll")]    static extern int    NtQueryInformationProcess(IntPtr hProcess, int cls, ref PBI pbi, int len, out int rlen);

    [StructLayout(LayoutKind.Sequential)]
    struct PBI { public IntPtr r0, PebBase, r2, r3, Pid, r5; }

    const uint QUERY = 0x0400, VMREAD = 0x0010;

    static IntPtr ReadPtr(byte[] b, int o) =>
        IntPtr.Size == 8 ? new IntPtr(BitConverter.ToInt64(b, o))
                         : new IntPtr(BitConverter.ToInt32(b, o));

    public static string Get(int pid) {
        IntPtr h = OpenProcess(QUERY | VMREAD, false, (uint)pid);
        if (h == IntPtr.Zero) return null;
        try {
            var pbi = new PBI(); int rl;
            if (NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(pbi), out rl) != 0) return null;

            // PEB: ProcessParameters pointer at 0x20 (64-bit) / 0x10 (32-bit)
            int ppOff = IntPtr.Size == 8 ? 0x20 : 0x10;
            byte[] peb = new byte[ppOff + IntPtr.Size]; IntPtr rd;
            if (!ReadProcessMemory(h, pbi.PebBase, peb, new IntPtr(peb.Length), out rd)) return null;
            IntPtr pp = ReadPtr(peb, ppOff);

            // RTL_USER_PROCESS_PARAMETERS: CurrentDirectory.DosPath (UNICODE_STRING) at 0x38 (64-bit) / 0x24 (32-bit)
            int cwdOff  = IntPtr.Size == 8 ? 0x38 : 0x24;
            int ustrSz  = IntPtr.Size == 8 ? 16   : 8;
            byte[] ppb  = new byte[cwdOff + ustrSz];
            if (!ReadProcessMemory(h, pp, ppb, new IntPtr(ppb.Length), out rd)) return null;

            ushort slen = BitConverter.ToUInt16(ppb, cwdOff);
            IntPtr sbuf = ReadPtr(ppb, cwdOff + (IntPtr.Size == 8 ? 8 : 4));
            if (slen == 0 || sbuf == IntPtr.Zero) return null;

            byte[] sb = new byte[slen];
            if (!ReadProcessMemory(h, sbuf, sb, new IntPtr(slen), out rd)) return null;
            return Encoding.Unicode.GetString(sb).TrimEnd('\\', '\0', '/');
        } catch { return null; }
        finally { CloseHandle(h); }
    }
}
'@
}

# Find processes that hold open handles on files inside $FolderPath.
# Tries handle.exe (Sysinternals) first; otherwise detects via CWD (PEB) and command-line/exe matching.
function Get-BlockingProcesses {
	param([string]$FolderPath)

	$norm = $FolderPath.TrimEnd('\', '/', ' ').Replace('/', '\')

	# --- handle.exe (Sysinternals) ---
	$handleExe = $null
	$candidates = @(
		(Get-Command "handle.exe" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
		"C:\Program Files\Sysinternals\handle.exe",
		"C:\tools\sysinternals\handle.exe",
		"$env:USERPROFILE\AppData\Local\Sysinternals\handle.exe"
	) | Where-Object { $_ }
	foreach ($c in $candidates) {
		if (Test-Path $c -ErrorAction SilentlyContinue) { $handleExe = $c; break }
	}

	if ($handleExe) {
		$raw  = & $handleExe -accepteula -nobanner $norm 2>$null
		$seen = @{}; $results = @()
		foreach ($line in $raw) {
			if ($line -match '^(.+?)\s+pid:\s*(\d+)\s+type:\S+\s+\w+:\s+(.+)$') {
				$pid_ = [int]$Matches[2]
				if (-not $seen.ContainsKey($pid_)) {
					$seen[$pid_] = $true
					$results += [PSCustomObject]@{ PID = $pid_; Name = $Matches[1].Trim(); Detail = $Matches[3].Trim() }
				} else {
					($results | Where-Object { $_.PID -eq $pid_ } | Select-Object -First 1).Detail += "; $($Matches[3].Trim())"
				}
			}
		}
		return $results
	}

	# --- Fallback: CWD via PEB + command-line/exe matching via CIM ---
	Initialize-ProcessCwdType

	$results = @{}  # keyed by PID to deduplicate

	# CWD check (catches cmd/pwsh/explorer windows sitting in the directory)
	foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
		try {
			$cwd = [ProcessCwd]::Get($p.Id)
			if ($cwd -and ($cwd -ieq $norm -or $cwd.StartsWith($norm + '\', [System.StringComparison]::OrdinalIgnoreCase))) {
				if (-not $results.ContainsKey($p.Id)) {
					$results[$p.Id] = [PSCustomObject]@{ PID = $p.Id; Name = $p.Name; Detail = "cwd: $cwd" }
				}
			}
		} catch {}
	}

	# Command-line / exe path check (catches IDE processes, build tools, etc.)
	Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
		$cmd = $_.CommandLine; $exe = $_.ExecutablePath
		if (($cmd -and $cmd -like "*$norm*") -or ($exe -and $exe -like "*$norm*")) {
			if (-not $results.ContainsKey([int]$_.ProcessId)) {
				$results[[int]$_.ProcessId] = [PSCustomObject]@{
					PID    = [int]$_.ProcessId
					Name   = $_.Name
					Detail = if ($cmd) { $cmd } else { $exe }
				}
			}
		}
	}

	return @($results.Values)
}

# Show an interactive fzf menu when a worktree folder cannot be removed.
# Del=kill selected process, Ctrl+R=refresh list, Ctrl+Enter (ctrl-j)=retry removal.
# Auto-retries removal when the list becomes empty.
# Returns $true if the folder was successfully removed, $false if the user cancelled.
function Invoke-BlockingProcessMenu {
	param([string]$FolderPath)

	function TryRemoveFolder ([string]$Path) {
		try {
			$ProgressPreference = 'SilentlyContinue'
			Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
			return $true
		} catch {
			return $false
		} finally {
			$ProgressPreference = 'Continue'
		}
	}

	while ($true) {
		$procs = Get-BlockingProcesses -FolderPath $FolderPath

		if ($procs.Count -eq 0) {
			# No processes detected — try removal; if still locked, ask via fzf
			if (TryRemoveFolder $FolderPath) { return $true }

			$choice = @("Retry removal", "Cancel") | fzf `
				--style=minimal --no-input --disabled --height=~5 --no-info --layout=reverse `
				--pointer=">" --gutter=" " `
				--color="pointer:red,fg+:red:bold,bg+:-1" `
				--header="Cannot remove: $FolderPath  (no blocking processes detected)" `
				--header-first

			if ($choice -ne "Retry removal") { return $false }
			continue
		}

		$maxNameLen = ($procs | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum

		$entries = $procs | ForEach-Object {
			$pidStr  = $_.PID.ToString().PadLeft(6)
			$nameStr = $_.Name.PadRight($maxNameLen)
			$detail  = if ($_.Detail.Length -gt 70) { $_.Detail.Substring(0, 67) + "..." } else { $_.Detail }
			"[$pidStr]  $nameStr  $detail"
		}

		$lines = $entries | fzf `
			--style=minimal --no-input --disabled --height=40% --no-info --layout=reverse `
			--pointer=">" --gutter=" " `
			--color="pointer:red,fg+:red:bold,bg+:-1" `
			--header="Cannot remove: $FolderPath  |  Del=kill  Ctrl+R=refresh  Ctrl+Enter=retry  Esc=cancel" `
			--header-first `
			--expect="del,ctrl-r,ctrl-j"

		if (-not $lines) { return $false }  # Esc / no selection

		$keyUsed  = $lines[0].Trim()
		$selected = if ($lines.Count -gt 1) { $lines[1].Trim() } else { "" }

		if ($keyUsed -eq "ctrl-r") { continue }

		if ($keyUsed -eq "ctrl-j") {
			if (TryRemoveFolder $FolderPath) { return $true }
			continue
		}

		if ($keyUsed -eq "del" -and $selected -match '^\[\s*(\d+)\]') {
			$pid_ = [int]$Matches[1]
			$proc = $procs | Where-Object { $_.PID -eq $pid_ } | Select-Object -First 1
			if ($proc) {
				Write-Host "Killing [$pid_] $($proc.Name)..." -ForegroundColor Yellow
				try {
					Stop-Process -Id $pid_ -Force -ErrorAction Stop
					Write-Host "Process killed." -ForegroundColor Green
				} catch {
					Write-Host "Failed to kill: $_" -ForegroundColor Red
					Start-Sleep -Milliseconds 800
				}
				Start-Sleep -Milliseconds 400
				# Auto-retry if no blockers remain
				$remaining = Get-BlockingProcesses -FolderPath $FolderPath
				if ($remaining.Count -eq 0 -and (TryRemoveFolder $FolderPath)) { return $true }
			}
		}
	}
}
