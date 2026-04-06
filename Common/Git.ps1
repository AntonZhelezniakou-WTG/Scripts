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
