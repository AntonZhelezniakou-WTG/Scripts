# Argument completer for the repo command.
# Add to your PowerShell profile (~\Documents\PowerShell\Microsoft.PowerShell_profile.ps1):
#   . "path\to\scripts\Common\repo.completion.ps1"

$_repoCompletionDir = Split-Path $PSScriptRoot -Parent

$_repoCompleter = {
	param($wordToComplete, $commandAst, $cursorPosition)

	$configPath = Join-Path $_repoCompletionDir "Configuration\Paths.json"
	if (-not (Test-Path $configPath)) { return }
	$config = Get-Content $configPath -Raw | ConvertFrom-Json

	$cwd = (Get-Location).Path

	# List local git repo names in a base directory
	function _ListLocalRepos([string]$base) {
		if (-not (Test-Path $base)) { return @() }
		Get-ChildItem -Path $base -Directory |
			Where-Object { $_.Name -notmatch '^\.' -and $_.Name -ne 'Personal' } |
			Where-Object {
				$g = Join-Path $_.FullName ".git"
				[System.IO.File]::Exists($g) -or [System.IO.Directory]::Exists($g)
			} |
			ForEach-Object { $_.Name }
	}

	# Read remote repo names for an owner from the file cache (no network calls).
	# Cache is populated by repo.ps1 on first open or Ctrl+R refresh.
	function _ListRemoteRepos([string]$owner) {
		$cachePath = Join-Path $_repoCompletionDir "Configuration\RepoCache.json"
		if (-not (Test-Path $cachePath)) { return @() }
		try {
			$cache = Get-Content $cachePath -Raw | ConvertFrom-Json -AsHashtable
			if ($cache.ContainsKey($owner) -and $cache[$owner].repos) {
				return @($cache[$owner].repos)
			}
		} catch {}
		return @()
	}

	# Resolve context: list of (Base, Owner) pairs based on cwd
	$contexts = [System.Collections.Generic.List[hashtable]]::new()
	$matched  = $false

	$sorted = @($config.ownerAliases) | Sort-Object { $_.localPath.Length } -Descending
	foreach ($alias in $sorted) {
		$pat = '^' + [regex]::Escape($alias.localPath.TrimEnd('\')) + '(\\|$)'
		if ($cwd -imatch $pat) {
			$contexts.Add(@{ Base = $alias.localPath; Owner = $alias.githubOwner })
			$matched = $true
			break
		}
	}

	if (-not $matched) {
		$basePat = '^' + [regex]::Escape($config.githubBase.TrimEnd('\')) + '\\([^\\]+)(\\|$)'
		if ($cwd -imatch $basePat) {
			$contexts.Add(@{ Base = (Join-Path $config.githubBase $Matches[1]); Owner = $Matches[1] })
			$matched = $true
		}
	}

	if (-not $matched) {
		foreach ($alias in $config.ownerAliases) {
			$contexts.Add(@{ Base = $alias.localPath; Owner = $alias.githubOwner })
		}
		$contexts.Add(@{ Base = (Join-Path $config.githubBase $config.defaultOwner); Owner = $config.defaultOwner })
	}

	# Collect local and remote names separately
	$localSet  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	$remoteSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

	foreach ($ctx in $contexts) {
		foreach ($r in (_ListLocalRepos $ctx.Base))  { $localSet.Add($r)  | Out-Null }
		foreach ($r in (_ListRemoteRepos $ctx.Owner)) { $remoteSet.Add($r) | Out-Null }
	}

	# Folder alias names (e.g., "Personal") — shown first as navigation shortcuts
	$folderAliasSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($oa in @($config.ownerAliases)) {
		if ($oa.PSObject.Properties['alias'] -and $oa.alias) {
			$folderAliasSet.Add($oa.alias) | Out-Null
		}
	}
	$folderAliasSet |
		Where-Object { $_ -like "$wordToComplete*" } |
		Sort-Object |
		ForEach-Object {
			[System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', "[alias] $_")
		}

	# Local repos, then remote-only (not yet cloned)
	$localSet |
		Where-Object { $_ -like "$wordToComplete*" } |
		Sort-Object |
		ForEach-Object {
			[System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
		}

	$remoteSet |
		Where-Object { -not $localSet.Contains($_) -and $_ -like "$wordToComplete*" } |
		Sort-Object |
		ForEach-Object {
			[System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', "[GitHub] $_")
		}
}.GetNewClosure()

Register-ArgumentCompleter -Native -CommandName repo -ScriptBlock $_repoCompleter
