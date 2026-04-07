# Git branch helpers.

# Get local branch names (strips git markers * and +).
function Get-LocalBranches {
	return @(git branch | ForEach-Object { $_.Trim() -replace "^[*+] ", "" } | Where-Object { $_ -ne "" })
}

# Get worktree branch names (branches marked with +).
function Get-WorktreeBranches {
	return @(git branch | Where-Object { $_.TrimStart().StartsWith("+") } | ForEach-Object { $_.Trim() -replace "^\+ ", "" })
}

# Find master or main from local branches.
function Get-BaseBranch {
	$local = Get-LocalBranches
	return $local | Where-Object { $_ -eq "master" -or $_ -eq "main" } | Select-Object -First 1
}

# Parse `git diff --cached --name-status` (or similar) lines into objects.
function Parse-StatusLines([string[]]$Lines) {
	$result = @()
	foreach ($line in $Lines) {
		if ($line -match '^([MADRCT])\d*\t(.+?)(?:\t(.+))?$') {
			$status  = $Matches[1]
			$oldPath = $Matches[2]
			$newPath = $Matches[3]
			$result += [PSCustomObject]@{
				Status  = $status
				Path    = if ($newPath) { $newPath } else { $oldPath }
				OldPath = if ($newPath) { $oldPath } else { $null }
			}
		}
	}
	return $result | Sort-Object Path
}

# Build coloured, tab-separated fzf entries from parsed status objects.
# Format: <coloured display>\t<clean path>
function Build-FzfEntries($Parsed) {
	$esc   = [char]27
	$reset = "$esc[0m"
	return @($Parsed | ForEach-Object {
		$color = switch ($_.Status) {
			'M' { "$esc[33m" }
			'A' { "$esc[32m" }
			'D' { "$esc[31m" }
			'R' { "$esc[36m" }
			'C' { "$esc[36m" }
			default { "" }
		}
		$display = if ($_.OldPath) { "$($_.OldPath) -> $($_.Path)" } else { $_.Path }
		"${color}$($_.Status)${reset}   $display`t$($_.Path)"
	})
}

# Extract the clean file path from a tab-separated fzf output line.
function Extract-PathFromFzfLine([string]$Line) {
	$parts = $Line -split "`t"
	if ($parts.Count -ge 2) { return $parts[1].Trim() }
	$clean = $Line -replace '\e\[[0-9;]*m', ''
	$path  = ($clean -split '\s+', 2)[1].Trim()
	if ($path -match ' -> (.+)$') { return $Matches[1] }
	return $path
}
