# Interactive tree navigator using fzf.
#
# Usage:
#   $selected = Invoke-FzfTree -GetChildren { param($Path) <return child names> }
#
# GetChildren receives the current node path (string) and must return
# an array of child names (strings). An empty result means the node is a leaf.
#
# Keys:
#   Enter  — drill into node (or select if leaf)
#   Tab    — select highlighted node as-is (even if it has children)
#   ..     — go up one level
#   Esc    — cancel (returns $null)

function Invoke-FzfTree {
	param(
		[Parameter(Mandatory)]
		[scriptblock]$GetChildren,
		[string]$Root = "",
		[string]$Separator = "/",
		[string]$Header = "Navigate (Enter=open, Tab=select, Esc=cancel):"
	)

	if (-not (Ensure-Fzf)) { return $null }

	$path = @()
	if ($Root) { $path = @($Root) }

	while ($true) {
		$currentPath = if ($path.Count -gt 0) { $path -join $Separator } else { "" }
		$children = @(& $GetChildren $currentPath | Where-Object { $_ })

		# Leaf node — return immediately
		if ($children.Count -eq 0) {
			return $currentPath
		}

		$entries = @()
		if ($path.Count -gt 0) { $entries += ".." }
		$entries += $children

		$prompt = if ($currentPath) { "$currentPath$Separator" } else { "" }

		$lines = $entries | fzf `
			--style=minimal --height=40% --no-info --layout=reverse `
			--pointer=">" --gutter=" " `
			--color="pointer:green,fg+:green:bold,bg+:-1" `
			--header=$Header --header-first `
			--prompt=$prompt `
			--expect="tab"

		if (-not $lines) { return $null }

		$keyUsed  = $lines[0].Trim()
		$selected = if ($lines.Count -gt 1) { $lines[1].Trim() } else { "" }

		if (-not $selected) { return $null }

		# Navigate up
		if ($selected -eq "..") {
			$path = if ($path.Count -le 1) { @() } else { @($path[0..($path.Count - 2)]) }
			continue
		}

		$childPath = if ($currentPath) { "$currentPath$Separator$selected" } else { $selected }

		# Tab — force-select this node regardless of children
		if ($keyUsed -eq "tab") {
			return $childPath
		}

		# Enter — drill in if non-leaf, select if leaf
		$subChildren = @(& $GetChildren $childPath | Where-Object { $_ })
		if ($subChildren.Count -gt 0) {
			$path += $selected
		} else {
			return $childPath
		}
	}
}
