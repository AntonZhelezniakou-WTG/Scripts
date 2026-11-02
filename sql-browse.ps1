<#
.SYNOPSIS
Shows saved SQL Server connections and their database aliases as a tree in fzf, with actions for them. Run "sql-browse -Help" for keys.
#>

# The profile library needs .NET 5 APIs, so PowerShell 7.0 and Windows PowerShell 5.1 cannot run it.
#Requires -Version 7.1
param(
	[string]$StorePath,
	[Alias('h')]
	[switch]$Help,
	# Collects stray values, so that a misplaced value gets a message instead of a binding error that echoes it.
	# Its position keeps a stray first value out of -StorePath.
	[Parameter(Position = 0, ValueFromRemainingArguments = $true, DontShow = $true)]
	[object[]]$UnexpectedArguments
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common\common.ps1')

function Show-SqlBrowseHelp {
	Write-Host @'
Saved SQL Server connections and database aliases as a tree (Windows / PowerShell 7)

Usage: sql-browse [-StorePath <directory>]

The tree shows each saved connection with its server, and below it the
aliases of its databases. The right pane shows the selected item: its
description and its connection string, with the password hidden.

Keys:
  Enter       Show the actions of the selected item.
  n           Add a connection. Then you can test it and add aliases.
  a / Insert  Add an alias for a database on the selected connection.
  e / F2      Edit the selected connection or alias.
  t           Test: open the connection, or the database of the alias.
  d / Del     Delete the selected connection or alias.
  r / F5      Read the store again.
  q / Esc     Quit.

Test, and the database list of add and edit, connect to SQL Server; they
only read. Delete changes no database. The connection string prompt hides
input. Access ReadOnly or ReadWrite is a rule for agents and scripts; SQL
Server does not enforce it.

Arguments:
  -StorePath  Override %LOCALAPPDATA%\SqlConnections.
  -Help / -h  Show this help (/? or --help alone also work).

Needs fzf and an interactive console. In scripts, use sql-connection and
sql-database.
'@
}

$esc = [char]27
$ansi = @{
	Reset = "$esc[0m"
	Bold = "$esc[1m"
	Gray = "$esc[90m"
	Red = "$esc[31m"
	Green = "$esc[32m"
	Yellow = "$esc[33m"
	Cyan = "$esc[36m"
}
$fzfStyle = @('--style=minimal', '--no-info', '--layout=reverse', '--pointer=>', '--gutter= ', '--color=pointer:green,fg+:green:bold,bg+:-1')
$consoleMissing = 'sql-browse needs an interactive console.'

# Store values can contain control characters: a tab would split the fzf fields, and an escape could change the terminal.
function Format-SqlBrowseText {
	param([string]$Text, [int]$Width = 0)
	$value = ([string]$Text) -replace '[\x00-\x1f\x7f-\x9f]', ' '
	if ($Width -gt 0 -and $value.Length -gt $Width) { $value = $value.Substring(0, $Width - 1) + '…' }
	return $value
}

# fzf cuts header lines at the width of the list, so headers use short lines. Keep the breaks; clean each line.
function Format-SqlBrowseHeader {
	param([string]$Text)
	return @($Text -split "`n" | ForEach-Object { Format-SqlBrowseText $_ }) -join "`n"
}

# True when a store file exists but cannot be read. The tree cannot show such a file, so the add flows offer to replace it.
function Test-SqlBrowseDamagedFile {
	param([string]$Path, [scriptblock]$Reader)
	if (-not [IO.File]::Exists($Path)) { return $false }
	try {
		$null = & $Reader $Path
		return $false
	} catch {
		return $true
	}
}

function Test-SqlBrowseDamagedProfile {
	param([string]$Name, [string]$Store)
	return Test-SqlBrowseDamagedFile (Get-SqlConnectionProfilePath -Name $Name -StorePath $Store) { param($path) Read-SqlConnectionProfile -Path $path }
}

function Test-SqlBrowseDamagedAlias {
	param([string]$Alias, [string]$Store)
	return Test-SqlBrowseDamagedFile (Get-SqlDatabaseAliasPath -Alias $Alias -StorePath $Store) { param($path) Read-SqlDatabaseAlias -Path $path }
}

# The same key as the library's name hash, so that the tree groups names as the store does.
function Get-SqlBrowseKey {
	param([string]$Name)
	return $Name.Trim().Normalize().ToUpperInvariant()
}

# Runs a library call without its warnings about store files that it cannot read: the tree shows those once.
# Other warnings, for example about a file that a delete cannot remove, still show. $Action runs in this scope.
function Invoke-SqlBrowseQuietly {
	param([scriptblock]$Action)
	& $Action 3>&1 | ForEach-Object {
		if ($_ -isnot [System.Management.Automation.WarningRecord]) { $_ }
		elseif ($_.Message -notmatch "^Skipped '.*': it is not a readable ") { Write-Warning $_.Message }
	}
}

# Prompts until $Validate accepts the value. Enter returns '', which the prompt explains (cancel or keep).
# $Validate runs in this scope, so it can use the variables of the caller.
function Read-SqlBrowseText {
	param([string]$Prompt, [scriptblock]$Validate)
	while ($true) {
		$value = Read-SqlCliText $Prompt -Missing $consoleMissing
		if (-not $value -or -not $Validate) { return $value }
		try {
			$null = & $Validate $value
			return $value
		} catch {
			Write-Host $_.Exception.Message -ForegroundColor Red
		}
	}
}

# Returns $null to keep the description, '' to clear it, or the new text.
function Read-SqlBrowseDescription {
	param([string]$Current)
	Write-Host "Current description: $(Format-SqlBrowseText $Current)"
	$value = Read-SqlBrowseText 'New description (Enter keeps it; - clears it)' {
		param($value)
		Assert-SqlConnectionPublicText -Value $value -Subject 'The description'
	}
	if (-not $value) { return $null }
	if ($value -eq '-') { return '' }
	return $value
}

# Prompts with hidden input until the connection string can be protected.
# Returns the encrypted text, or $null when the user presses Enter.
function Read-SqlBrowseConnectionString {
	param([string]$Prompt)
	while ($true) {
		$secret = Read-SqlConnectionSecret $Prompt -Missing $consoleMissing
		try {
			if ($null -eq $secret -or $secret.Length -eq 0) { return $null }
			return Protect-SqlConnectionString -ConnectionString $secret
		} catch {
			Write-Host $_.Exception.Message -ForegroundColor Red
		} finally {
			if ($null -ne $secret) { $secret.Dispose() }
		}
	}
}

# Shows a short fzf list. A choice with a Key is also chosen by that key. Returns the Id of the chosen item,
# or $null when the user presses Esc.
function Select-SqlBrowseChoice {
	param([string]$Header, [object[]]$Choices, [int]$Position = 1)
	$lines = for ($index = 0; $index -lt $Choices.Count; $index++) { "$(Format-SqlBrowseText $Choices[$index].Text)`t$index" }
	$keys = @($Choices | Where-Object { $_.Key } | ForEach-Object Key)
	$expect = @(if ($keys.Count) { "--expect=$($keys -join ',')" })
	# --sync loads the input before the start event; otherwise pos() can run on an empty list.
	$output = @($lines | fzf @fzfStyle --no-input --disabled --sync '--height=~15' "--delimiter=`t" '--with-nth=1' `
		"--header=$(Format-SqlBrowseHeader $Header)" '--header-first' "--bind=start:pos($Position)" @expect)
	if ($LASTEXITCODE -eq 2) { throw 'fzf cannot show the menu.' }
	if (-not $output.Count) { return $null }
	# With --expect, the first line is the key ('' for Enter), and the selection follows.
	if ($keys.Count) {
		if ($output[0]) { return @($Choices | Where-Object { $_.Key -eq $output[0] })[0].Id }
		$output = @($output | Select-Object -Skip 1)
	}
	if (-not $output.Count -or -not $output[0]) { return $null }
	return $Choices[[int]($output[0] -split "`t")[-1]].Id
}

function Select-SqlBrowseAccess {
	param([string]$Current = 'ReadOnly')
	$position = if ($Current -eq 'ReadWrite') { 2 } else { 1 }
	return Select-SqlBrowseChoice -Header "Access is a rule for agents and scripts.`nSQL Server does not enforce it. Esc cancels." -Position $position -Choices @(
		[pscustomobject]@{ Id = 'ReadOnly'; Text = 'ReadOnly   Agents do not change this database.' }
		[pscustomobject]@{ Id = 'ReadWrite'; Text = 'ReadWrite  Agents can change it when their task allows it.' }
	)
}

# Returns the saved name of another connection, or $null.
function Select-SqlBrowseConnection {
	param([string]$Store, [string]$Header, [string]$Exclude)
	$excludeKey = if ($Exclude) { Get-SqlBrowseKey $Exclude } else { $null }
	$connections = @(Get-SqlConnectionProfiles -StorePath $Store 3>$null | Where-Object { (Get-SqlBrowseKey $_.Name) -ne $excludeKey })
	if (-not $connections.Count) {
		Write-Host 'There is no other saved connection. Add one with n.' -ForegroundColor Yellow
		return $null
	}
	$choices = @(foreach ($connection in $connections) {
		[pscustomobject]@{ Id = $connection.Name; Text = "$($connection.Name)    $($connection.Description)" }
	})
	return Select-SqlBrowseChoice -Header "$Header`nEsc cancels." -Choices $choices
}

# Lists the databases on the server and returns the chosen or typed name, or '' when the user cancels.
# When the server cannot list them, the user types the name.
function Select-SqlBrowseDatabase {
	param([string]$Connection, [string]$Store)
	$validate = {
		param($value)
		Assert-SqlConnectionPublicText -Value $value -Subject 'The database name'
		Assert-SqlDatabaseName -Database $value
	}
	# A connection deleted in another window must stop the flow, not look like a server that cannot list databases.
	if (-not [IO.File]::Exists((Get-SqlConnectionProfilePath -Name $Connection -StorePath $Store))) {
		throw "The SQL connection '$Connection' does not exist any more."
	}
	Write-Host "Reading the databases on the server of '$Connection'..." -ForegroundColor DarkGray
	try {
		$databases = @(Get-SqlServerDatabases -Connection $Connection -StorePath $Store)
	} catch {
		Write-Host $_.Exception.Message -ForegroundColor Red
		return Read-SqlBrowseText 'Database name (Enter cancels)' $validate
	}
	$aliases = @(Get-SqlDatabaseAliases -Connection $Connection -StorePath $Store 3>$null)
	$width = [Math]::Min(48, [Math]::Max(8, ($databases | ForEach-Object { $_.Database.Length } | Measure-Object -Maximum).Maximum))
	# The last field is an index: a database name can contain any character.
	$lines = for ($index = 0; $index -lt $databases.Count; $index++) {
		$database = $databases[$index]
		$state = if ($database.State -ne 'ONLINE') { $database.State } elseif (-not $database.HasAccess) { 'no access' } else { '' }
		$names = @($aliases | Where-Object { $_.Database -ieq $database.Database } | ForEach-Object Alias) -join ', '
		$aliasText = if ($names) { "$($ansi.Green)alias: $(Format-SqlBrowseText $names)$($ansi.Reset)" } else { '' }
		"$((Format-SqlBrowseText $database.Database $width).PadRight($width))  $($ansi.Gray)$($state.PadRight(10))$($ansi.Reset)  $aliasText`t$index"
	}
	$header = Format-SqlBrowseHeader "Databases on '$Connection'.`nType to filter. Enter selects. Esc cancels.`nCtrl+T takes the typed text as the name."
	# fzf writes UTF-8. The typed query is text, so decode it as UTF-8 also with an OEM console code page.
	$outputEncoding = [Console]::OutputEncoding
	try {
		[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
		# Enter needs a match, so that a typing error in the filter does not become the name; Ctrl+T takes the text.
		$output = @($lines | fzf @fzfStyle '--height=70%' '--ansi' "--delimiter=`t" '--with-nth=1' '--print-query' '--expect=ctrl-t' `
			'--bind=enter:accept-non-empty' "--header=$header" '--header-first')
		$code = $LASTEXITCODE
	} finally {
		[Console]::OutputEncoding = $outputEncoding
	}
	if ($code -eq 2) { throw 'fzf cannot show the database list.' }
	# With --print-query and --expect, the output is the query, the key, and then the selection.
	if ($code -eq 130 -or -not $output.Count) { return '' }
	$query = ([string]$output[0]).Trim()
	$key = if ($output.Count -gt 1) { [string]$output[1] } else { '' }
	$selected = if ($output.Count -gt 2) { [string]$output[2] } else { '' }
	$name = if ($key -eq 'ctrl-t') { $query } elseif ($selected) { $databases[[int]($selected -split "`t")[-1]].Database } else { '' }
	if (-not $name) { return '' }
	try {
		$null = & $validate $name
	} catch {
		Write-Host $_.Exception.Message -ForegroundColor Red
		return Read-SqlBrowseText 'Database name (Enter cancels)' $validate
	}
	return $name
}

function Show-SqlBrowseTest {
	param([string]$Name, [string]$Store)
	Write-Host "Connecting through '$Name'..." -ForegroundColor DarkGray
	try {
		$info = Get-SqlServerSessionInfo -Name $Name -StorePath $Store
	} catch {
		Write-Host $_.Exception.Message -ForegroundColor Red
		return
	}
	Write-Host "Connected through '$Name' in $($info.OpenMilliseconds) ms." -ForegroundColor Green
	$rows = [ordered]@{
		Server = $info.Server
		Database = $info.Database
		Login = $info.Login
		Version = "$($info.Version) $($info.Edition)".Trim()
		Transport = $info.Transport
		Authentication = $info.Authentication
		Encrypted = $info.Encrypted
	}
	foreach ($label in $rows.Keys) {
		if ($rows[$label]) { Write-Host ('  {0,-16}{1}' -f $label, (Format-SqlBrowseText $rows[$label])) }
	}
}

# Prompts for an alias on a saved connection and saves it. Returns the tree key of the alias, or $null.
function Add-SqlBrowseAlias {
	param([string]$Connection, [string]$Store)
	$database = Select-SqlBrowseDatabase -Connection $Connection -Store $Store
	if (-not $database) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return $null }
	$validateFree = {
		param($value)
		Assert-SqlConnectionPublicText -Value $value -Subject 'The alias'
		Invoke-SqlBrowseQuietly { Assert-SqlConnectionNameFree -Name $value -StorePath $Store -Kind Alias }
	}
	# A damaged alias file takes its name but is not in the tree; accept its name and offer to replace the file below.
	$validate = {
		param($value)
		Assert-SqlConnectionPublicText -Value $value -Subject 'The alias'
		if (-not (Test-SqlBrowseDamagedAlias -Alias $value -Store $Store)) { & $validateFree $value }
	}
	# Offer the database name when it is free; aliases are unique on this computer.
	$suggestion = try { $null = & $validateFree $database; $database } catch { $null }
	$prompt = if ($suggestion) { "Alias (Enter uses '$(Format-SqlBrowseText $suggestion)')" } else { 'Alias (Enter cancels)' }
	$alias = Read-SqlBrowseText $prompt $validate
	if (-not $alias) { $alias = $suggestion }
	if (-not $alias) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return $null }
	if (Test-SqlBrowseDamagedAlias -Alias $alias -Store $Store) {
		if (-not (Confirm-Action "The alias file of '$alias' cannot be read. Delete it and add the alias again?" -Color Yellow)) { Write-Host 'Aborted.' -ForegroundColor DarkGray; return $null }
		# The prompt can stay open while another window repairs the file.
		if (-not (Test-SqlBrowseDamagedAlias -Alias $alias -Store $Store)) {
			Write-Host "The alias file of '$alias' changed in another window. The tree now shows the current store." -ForegroundColor Yellow
			return $null
		}
		Remove-SqlDatabaseAlias -Alias $alias -StorePath $Store
		Write-Host "Deleted the damaged alias file of '$alias'." -ForegroundColor Green
	}
	$description = Read-SqlBrowseText 'Description (optional)' {
		param($value)
		Assert-SqlConnectionPublicText -Value $value -Subject 'The description'
	}
	$access = Select-SqlBrowseAccess
	if (-not $access) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return $null }
	$entry = [pscustomobject]@{
		Version = 1
		Alias = $alias
		Connection = $Connection
		Database = $database
		Access = $access
		Description = $description
	}
	Invoke-SqlBrowseQuietly { Write-SqlDatabaseAlias -Entry $entry -StorePath $Store -Add }
	Write-Host "Saved database alias '$alias' for '$database' on '$Connection' ($access)." -ForegroundColor Green
	return "A:$(Get-SqlBrowseKey $alias)"
}

# Prompts for a new connection and saves it. $Name gives the name of a connection to add again.
# Returns the tree key of the connection or of its new alias, or $null.
function Add-SqlBrowseConnection {
	param([string]$Store, [string]$Name)
	if ($Name) {
		if (-not (Test-SqlBrowseDamagedProfile -Name $Name -Store $Store)) { Assert-SqlConnectionNameFree -Name $Name -StorePath $Store -Kind Connection }
		Write-Host "Add the SQL connection '$Name' again."
	} else {
		# A damaged profile takes its name; accept the name and offer to replace the file below.
		$Name = Read-SqlBrowseText 'New connection name (Enter cancels)' {
			param($value)
			Assert-SqlConnectionPublicText -Value $value -Subject 'The connection name'
			if (-not (Test-SqlBrowseDamagedProfile -Name $value -Store $Store)) { Assert-SqlConnectionNameFree -Name $value -StorePath $Store -Kind Connection }
		}
		if (-not $Name) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return $null }
	}
	if (Test-SqlBrowseDamagedProfile -Name $Name -Store $Store) {
		if (-not (Confirm-Action "The profile file of '$Name' cannot be read. Delete it and add the connection again? Its aliases stay." -Color Yellow)) { Write-Host 'Aborted.' -ForegroundColor DarkGray; return $null }
		# The prompt can stay open while another window repairs the profile.
		if (-not (Test-SqlBrowseDamagedProfile -Name $Name -Store $Store)) {
			Write-Host "The profile of '$Name' changed in another window. The tree now shows the current store." -ForegroundColor Yellow
			return $null
		}
		$null = Invoke-SqlBrowseQuietly { Remove-SqlConnectionProfile -Name $Name -StorePath $Store -KeepDatabases }
		Write-Host "Deleted the damaged profile of '$Name'." -ForegroundColor Green
	}
	$description = Read-SqlBrowseText 'Description (optional)' {
		param($value)
		Assert-SqlConnectionPublicText -Value $value -Subject 'The description'
	}
	$encrypted = Read-SqlBrowseConnectionString 'Connection string (hidden; Enter cancels)'
	if (-not $encrypted) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return $null }
	$connectionProfile = [pscustomobject]@{
		Version = 1
		Name = $Name
		Description = $description
		EncryptedConnectionString = $encrypted
	}
	Write-SqlConnectionProfile -ConnectionProfile $connectionProfile -StorePath $Store -Add
	Write-Host "Saved SQL connection '$Name'." -ForegroundColor Green
	# Aliases kept with sql-connection delete -KeepDatabases wait for this name.
	$waiting = @(Get-SqlDatabaseAliases -Connection $Name -StorePath $Store 3>$null | ForEach-Object Alias)
	if ($waiting.Count) {
		Write-Host "Database aliases $($waiting -join ', ') use this connection; they now open databases through this connection string." -ForegroundColor Yellow
	}
	if (Confirm-Action 'Test the connection now?') { Show-SqlBrowseTest -Name $Name -Store $Store }
	$focus = "C:$(Get-SqlBrowseKey $Name)"
	if (Confirm-Action "Add an alias for a database on '$Name'?") {
		$aliasKey = Add-SqlBrowseAlias -Connection $Name -Store $Store
		if ($aliasKey) { $focus = $aliasKey }
	}
	return $focus
}

function Edit-SqlBrowseConnection {
	param([object]$Node, [string]$Store)
	$path = Get-SqlConnectionProfilePath -Name $Node.Name -StorePath $Store
	if (-not [IO.File]::Exists($path)) { throw "The SQL connection '$($Node.Name)' does not exist any more." }
	# Write-SqlConnectionProfile refuses the save if another process changed the file meanwhile.
	$expectedContent = [IO.File]::ReadAllText($path)
	$connectionProfile = Read-SqlConnectionProfile -Path $path
	$current = if ($connectionProfile.Description) { $connectionProfile.Description } else { '(none)' }
	$field = Select-SqlBrowseChoice -Header "Edit the SQL connection '$($connectionProfile.Name)'.`nEsc cancels." -Choices @(
		[pscustomobject]@{ Id = 'description'; Text = "Description        $current" }
		[pscustomobject]@{ Id = 'connection-string'; Text = 'Connection string  Replace it; the input is hidden.' }
	)
	if (-not $field) { return }
	if ($field -eq 'description') {
		$value = Read-SqlBrowseDescription -Current $connectionProfile.Description
		if ($null -eq $value) { Write-Host 'No changes.'; return }
		$connectionProfile.Description = $value
	} else {
		$encrypted = Read-SqlBrowseConnectionString 'New connection string (hidden; Enter keeps it)'
		if (-not $encrypted) { Write-Host 'No changes.'; return }
		$connectionProfile.EncryptedConnectionString = $encrypted
	}
	Write-SqlConnectionProfile -ConnectionProfile $connectionProfile -StorePath $Store -ExpectedContent $expectedContent
	Write-Host "Saved SQL connection '$($connectionProfile.Name)'." -ForegroundColor Green
	if ($field -eq 'connection-string') {
		$aliasNames = @($Node.Aliases | ForEach-Object Alias)
		if ($aliasNames.Count) {
			Write-Host "Database aliases $($aliasNames -join ', ') use this connection; they now open databases through this connection string." -ForegroundColor Yellow
		}
		if (Confirm-Action 'Test the connection now?') { Show-SqlBrowseTest -Name $connectionProfile.Name -Store $Store }
	}
}

function Edit-SqlBrowseAlias {
	param([object]$Node, [string]$Store)
	$path = Get-SqlDatabaseAliasPath -Alias $Node.Alias -StorePath $Store
	if (-not [IO.File]::Exists($path)) { throw "The database alias '$($Node.Alias)' does not exist any more." }
	# Write-SqlDatabaseAlias refuses the save if another process changed the file meanwhile.
	$expectedContent = [IO.File]::ReadAllText($path)
	$entry = Read-SqlDatabaseAlias -Path $path
	$current = if ($entry.Description) { $entry.Description } else { '(none)' }
	$field = Select-SqlBrowseChoice -Header "Edit the database alias '$($entry.Alias)'.`nEsc cancels." -Choices @(
		[pscustomobject]@{ Id = 'description'; Text = "Description  $current" }
		[pscustomobject]@{ Id = 'access'; Text = "Access       $($entry.Access)" }
		[pscustomobject]@{ Id = 'database'; Text = "Database     $($entry.Database)" }
		[pscustomobject]@{ Id = 'connection'; Text = "Connection   $($entry.Connection)  Move the alias to another connection." }
	)
	switch ($field) {
		'description' {
			$value = Read-SqlBrowseDescription -Current $entry.Description
			if ($null -eq $value) { Write-Host 'No changes.'; return }
			$entry.Description = $value
		}
		'access' {
			$access = Select-SqlBrowseAccess -Current $entry.Access
			if (-not $access -or $access -ceq $entry.Access) { Write-Host 'No changes.'; return }
			$entry.Access = $access
		}
		'database' {
			# An alias kept with sql-connection delete -KeepDatabases, or with a damaged profile, has no server to list.
			$listable = [IO.File]::Exists((Get-SqlConnectionProfilePath -Name $entry.Connection -StorePath $Store)) -and
				-not (Test-SqlBrowseDamagedProfile -Name $entry.Connection -Store $Store)
			$database = if ($listable) {
				Select-SqlBrowseDatabase -Connection $entry.Connection -Store $Store
			} else {
				Read-SqlBrowseText 'New database name (Enter keeps it)' {
					param($value)
					Assert-SqlConnectionPublicText -Value $value -Subject 'The database name'
					Assert-SqlDatabaseName -Database $value
				}
			}
			if (-not $database -or $database -ceq $entry.Database) { Write-Host 'No changes.'; return }
			$entry.Database = $database
		}
		'connection' {
			$target = Select-SqlBrowseConnection -Store $Store -Exclude $entry.Connection -Header "Move the alias '$($entry.Alias)' to the connection:"
			if (-not $target) { Write-Host 'No changes.'; return }
			$entry.Connection = $target
		}
		default { return }
	}
	Write-SqlDatabaseAlias -Entry $entry -StorePath $Store -ExpectedContent $expectedContent
	Write-Host "Saved database alias '$($entry.Alias)' for '$($entry.Database)' on '$($entry.Connection)' ($($entry.Access))." -ForegroundColor Green
}

# Deletes a connection profile, also a damaged one. Aliases that use it stay or go as the user chooses.
# -Damaged stops the delete when another window repaired the profile while the prompt was open.
function Remove-SqlBrowseConnection {
	param([string]$Name, [string]$Store, [switch]$Damaged)
	$repaired = {
		if (-not $Damaged -or (Test-SqlBrowseDamagedProfile -Name $Name -Store $Store)) { return $false }
		Write-Host "The profile of '$Name' changed in another window. The tree now shows the current store." -ForegroundColor Yellow
		return $true
	}
	$aliases = @(Get-SqlDatabaseAliases -Connection $Name -StorePath $Store 3>$null)
	if (-not $aliases.Count) {
		if (-not (Confirm-Action "Delete the SQL connection '$Name'? No database changes." -Color Yellow)) { Write-Host 'Aborted.' -ForegroundColor DarkGray; return }
		if (& $repaired) { return }
		# The prompt can stay open while another window adds an alias; then the user must choose what happens to it.
		$added = @(Get-SqlDatabaseAliases -Connection $Name -StorePath $Store 3>$null)
		if ($added.Count) {
			Write-Host "Database aliases $(@($added.Alias) -join ', ') now use '$Name'. The tree now shows the current store." -ForegroundColor Yellow
			return
		}
		$null = Invoke-SqlBrowseQuietly { Remove-SqlConnectionProfile -Name $Name -StorePath $Store }
		Write-Host "Deleted SQL connection '$Name'." -ForegroundColor Green
		return
	}
	$aliasNames = @($aliases.Alias) -join ', '
	# The list can be longer than a header line, which fzf cuts; the console wraps it.
	Write-Host "Database aliases of '$Name': $aliasNames" -ForegroundColor Yellow
	$choice = Select-SqlBrowseChoice -Header "Delete the SQL connection '$Name'. No database changes.`nDatabase aliases use it: $($aliases.Count), shown above." -Choices @(
		[pscustomobject]@{ Id = 'cancel'; Text = 'Cancel' }
		[pscustomobject]@{ Id = 'keep'; Text = "Delete the connection, keep the aliases. They work again when you add '$Name' again." }
		[pscustomobject]@{ Id = 'with'; Text = 'Delete the connection and its aliases.' }
	)
	if ($choice -in @('keep', 'with') -and (& $repaired)) { return }
	# The menu can stay open while another window adds or moves aliases; the user decided only about the shown ones.
	if ($choice -in @('keep', 'with')) {
		$shownKeys = @($aliases | ForEach-Object { Get-SqlBrowseKey $_.Alias } | Sort-Object)
		$currentKeys = @(Get-SqlDatabaseAliases -Connection $Name -StorePath $Store 3>$null | ForEach-Object { Get-SqlBrowseKey $_.Alias } | Sort-Object)
		if (($shownKeys -join "`n") -cne ($currentKeys -join "`n")) {
			Write-Host "The database aliases of '$Name' changed in another window. The tree now shows the current store." -ForegroundColor Yellow
			return
		}
	}
	if ($choice -eq 'keep') {
		$null = Invoke-SqlBrowseQuietly { Remove-SqlConnectionProfile -Name $Name -StorePath $Store -KeepDatabases }
		Write-Host "Deleted SQL connection '$Name'. Kept database aliases $aliasNames." -ForegroundColor Green
	} elseif ($choice -eq 'with') {
		$deleted = @(Invoke-SqlBrowseQuietly { Remove-SqlConnectionProfile -Name $Name -StorePath $Store -WithDatabases })
		$deletedText = if ($deleted.Count) { " and database aliases $(@($deleted.Alias) -join ', ')" } else { '' }
		Write-Host "Deleted SQL connection '$Name'$deletedText." -ForegroundColor Green
	} else {
		Write-Host 'Aborted.' -ForegroundColor DarkGray
	}
}

function Remove-SqlBrowseItem {
	param([object]$Node, [string]$Store)
	if ($Node.Kind -eq 'Alias') {
		if (-not (Confirm-Action "Delete the database alias '$($Node.Alias)'? The database does not change." -Color Yellow)) { Write-Host 'Aborted.' -ForegroundColor DarkGray; return }
		Remove-SqlDatabaseAlias -Alias $Node.Alias -StorePath $Store
		Write-Host "Deleted database alias '$($Node.Alias)'." -ForegroundColor Green
	} elseif ($Node.Kind -eq 'Connection' -or ($Node.Kind -eq 'Missing' -and $Node.Damaged)) {
		Remove-SqlBrowseConnection -Name $Node.Name -Store $Store -Damaged:($Node.Kind -eq 'Missing')
	} elseif ($Node.Kind -eq 'Missing') {
		$aliasNames = @($Node.Aliases.Alias) -join ', '
		if (-not (Confirm-Action "Delete the database aliases $aliasNames of the connection '$($Node.Name)', which is not saved?" -Color Yellow)) { Write-Host 'Aborted.' -ForegroundColor DarkGray; return }
		# The prompt can stay open while another window adds the connection again.
		if ([IO.File]::Exists((Get-SqlConnectionProfilePath -Name $Node.Name -StorePath $Store))) {
			Write-Host "The SQL connection '$($Node.Name)' was added in another window. The tree now shows the current store." -ForegroundColor Yellow
			return
		}
		$nodeKey = Get-SqlBrowseKey $Node.Name
		foreach ($entry in $Node.Aliases) {
			# Another window can delete an alias, or move it to another connection, while the tree shows it.
			$path = Get-SqlDatabaseAliasPath -Alias $entry.Alias -StorePath $Store
			$current = if ([IO.File]::Exists($path)) { try { Read-SqlDatabaseAlias -Path $path } catch { $null } }
			if ($null -eq $current -or (Get-SqlBrowseKey $current.Connection) -ne $nodeKey) {
				Write-Host "Skipped database alias '$($entry.Alias)': it changed in another window." -ForegroundColor Yellow
				continue
			}
			Remove-SqlDatabaseAlias -Alias $entry.Alias -StorePath $Store
			Write-Host "Deleted database alias '$($entry.Alias)'." -ForegroundColor Green
		}
	} else {
		Write-Host 'Select a connection or an alias to delete.' -ForegroundColor Yellow
	}
}

# Returns the action that Enter shows for the node, or $null.
function Select-SqlBrowseAction {
	param([object]$Node)
	$choices = [System.Collections.Generic.List[object]]::new()
	# A key works in this menu as in the tree. Actions that the tree has no key for have none here.
	$add = { param($id, $key, $text) $choices.Add([pscustomobject]@{ Id = $id; Key = $key; Text = "$($key.PadRight(8))$text" }) }
	switch ($Node.Kind) {
		'Connection' {
			& $add 'test' 't' 'Test the connection.'
			& $add 'edit' 'e' 'Edit the description or the connection string.'
			& $add 'add-alias' 'a' 'Add an alias for a database on this connection.'
			& $add 'delete' 'd' 'Delete the connection.'
			$title = "SQL connection '$($Node.Name)'"
		}
		'Alias' {
			if ($Node.Saved) { & $add 'test' 't' 'Test: open the database.' }
			& $add 'edit' 'e' 'Edit the description, access, database, or connection.'
			if ($Node.Saved) { & $add 'add-alias' 'a' "Add an alias for another database on '$($Node.Connection)'." }
			& $add 'delete' 'd' 'Delete the alias.'
			$title = "Database alias '$($Node.Alias)'"
		}
		'Missing' {
			if ($Node.Damaged) {
				& $add 'replace-profile' '' 'Delete the damaged profile, keep its aliases, and add the connection again.'
				& $add 'delete' 'd' 'Delete the damaged profile.'
			} else {
				& $add 'restore-connection' '' "Add the connection '$($Node.Name)' again."
				& $add 'delete' 'd' 'Delete its aliases.'
			}
			$title = "SQL connection '$($Node.Name)'"
		}
		default { return $null }
	}
	return Select-SqlBrowseChoice -Header "$title.`nEsc goes back." -Choices $choices
}

# Returns a message when the file of the node is gone, or $null. -NeedsConnection also checks the profile of an alias.
function Get-SqlBrowseStaleMessage {
	param([object]$Node, [string]$Store, [switch]$NeedsConnection)
	switch ($Node.Kind) {
		'Connection' {
			if (-not [IO.File]::Exists((Get-SqlConnectionProfilePath -Name $Node.Name -StorePath $Store))) { return "The SQL connection '$($Node.Name)' does not exist any more." }
		}
		'Alias' {
			if (-not [IO.File]::Exists((Get-SqlDatabaseAliasPath -Alias $Node.Alias -StorePath $Store))) { return "The database alias '$($Node.Alias)' does not exist any more." }
			if ($NeedsConnection -and $Node.Saved -and -not [IO.File]::Exists((Get-SqlConnectionProfilePath -Name $Node.Connection -StorePath $Store))) {
				return "The SQL connection '$($Node.Connection)' does not exist any more."
			}
			if ($NeedsConnection -and -not $Node.Saved -and [IO.File]::Exists((Get-SqlConnectionProfilePath -Name $Node.Connection -StorePath $Store)) -and
				-not (Test-SqlBrowseDamagedProfile -Name $Node.Connection -Store $Store)) {
				return "The SQL connection '$($Node.Connection)' was added or repaired in another window."
			}
		}
		'Missing' {
			# The user can repair the profile or add the connection again in another window, as the messages suggest.
			if ($Node.Damaged -and -not (Test-SqlBrowseDamagedProfile -Name $Node.Name -Store $Store)) { return "The profile of '$($Node.Name)' changed in another window." }
			if (-not $Node.Damaged -and [IO.File]::Exists((Get-SqlConnectionProfilePath -Name $Node.Name -StorePath $Store))) { return "The SQL connection '$($Node.Name)' was added in another window." }
		}
	}
	return $null
}

# Runs the action of a key or of the Enter menu. Returns the tree key to select next, or $null.
function Invoke-SqlBrowseAction {
	param([string]$Key, [object]$Node, [string]$Store)
	$action = switch ($Key) {
		'' { if ($Node.Kind -eq 'New') { 'add-connection' } else { Select-SqlBrowseAction -Node $Node } }
		'n' { 'add-connection' }
		{ $_ -in @('a', 'insert') } { 'add-alias' }
		{ $_ -in @('e', 'f2') } { 'edit' }
		't' { 'test' }
		{ $_ -in @('d', 'del') } { 'delete' }
	}
	$notSaved = if ($Node.Kind -in @('Alias', 'Missing') -and -not ($Node.Kind -eq 'Alias' -and $Node.Saved)) {
		$connectionName = if ($Node.Kind -eq 'Alias') { $Node.Connection } else { $Node.Name }
		"The SQL connection '$connectionName' is not saved, or its profile cannot be read. Select it and press Enter."
	}
	# Another window can change the store while the tree shows it. The loop reads the store again after this.
	if ($action -and $action -ne 'add-connection') {
		$stale = Get-SqlBrowseStaleMessage -Node $Node -Store $Store -NeedsConnection:($action -in @('test', 'add-alias'))
		if ($stale) {
			Write-Host "$stale The tree now shows the current store." -ForegroundColor Yellow
			return $null
		}
	}
	switch ($action) {
		'add-connection' { return Add-SqlBrowseConnection -Store $Store }
		'restore-connection' { return Add-SqlBrowseConnection -Store $Store -Name $Node.Name }
		'replace-profile' {
			if (-not (Confirm-Action "Delete the damaged profile of '$($Node.Name)' and keep its aliases?" -Color Yellow)) { Write-Host 'Aborted.' -ForegroundColor DarkGray; return $null }
			# The prompt can stay open while another window repairs the profile.
			if (-not (Test-SqlBrowseDamagedProfile -Name $Node.Name -Store $Store)) {
				Write-Host "The profile of '$($Node.Name)' changed in another window. The tree now shows the current store." -ForegroundColor Yellow
				return $null
			}
			$null = Invoke-SqlBrowseQuietly { Remove-SqlConnectionProfile -Name $Node.Name -StorePath $Store -KeepDatabases }
			Write-Host "Deleted the damaged profile of '$($Node.Name)'. Kept its database aliases." -ForegroundColor Green
			return Add-SqlBrowseConnection -Store $Store -Name $Node.Name
		}
		'add-alias' {
			if ($Node.Kind -eq 'Connection') { return Add-SqlBrowseAlias -Connection $Node.Name -Store $Store }
			if ($Node.Kind -eq 'Alias' -and $Node.Saved) { return Add-SqlBrowseAlias -Connection $Node.Connection -Store $Store }
			Write-Host ($notSaved ?? 'Select a connection first, or add one with n.') -ForegroundColor Yellow
		}
		'edit' {
			if ($Node.Kind -eq 'Connection') { Edit-SqlBrowseConnection -Node $Node -Store $Store }
			elseif ($Node.Kind -eq 'Alias') { Edit-SqlBrowseAlias -Node $Node -Store $Store }
			else { Write-Host ($notSaved ?? 'Select a connection or an alias to edit.') -ForegroundColor Yellow }
		}
		'test' {
			if ($Node.Kind -eq 'Connection') { Show-SqlBrowseTest -Name $Node.Name -Store $Store }
			elseif ($Node.Kind -eq 'Alias' -and $Node.Saved) { Show-SqlBrowseTest -Name $Node.Alias -Store $Store }
			else { Write-Host ($notSaved ?? 'Select a connection or an alias to test.') -ForegroundColor Yellow }
		}
		'delete' { Remove-SqlBrowseItem -Node $Node -Store $Store }
	}
	return $null
}

function New-SqlBrowseAliasNode {
	param([object]$Entry, [string]$Connection, [bool]$Saved, [bool]$Last, [object]$Info, [string]$Problem)
	return [pscustomobject]@{
		Kind = 'Alias'
		Key = "A:$(Get-SqlBrowseKey $Entry.Alias)"
		Alias = $Entry.Alias
		Connection = $Connection
		Database = $Entry.Database
		Access = $Entry.Access
		Description = $Entry.Description
		Saved = $Saved
		Last = $Last
		Info = $Info
		Problem = $Problem
	}
}

# Reads the store into tree nodes in display order. Returns the warnings of the library instead of showing them.
function Get-SqlBrowseTree {
	param([string]$Store)
	$warnings = [System.Collections.Generic.List[string]]::new()
	$connections = [System.Collections.Generic.List[object]]::new()
	$aliases = [System.Collections.Generic.List[object]]::new()
	foreach ($item in @(Get-SqlConnectionProfiles -StorePath $Store 3>&1)) {
		if ($item -is [System.Management.Automation.WarningRecord]) { $warnings.Add($item.Message) } else { $connections.Add($item) }
	}
	foreach ($item in @(Get-SqlDatabaseAliases -StorePath $Store 3>&1)) {
		if ($item -is [System.Management.Automation.WarningRecord]) { $warnings.Add($item.Message) } else { $aliases.Add($item) }
	}
	$groups = @{}
	foreach ($entry in $aliases) {
		$key = Get-SqlBrowseKey $entry.Connection
		if (-not $groups.ContainsKey($key)) { $groups[$key] = [System.Collections.Generic.List[object]]::new() }
		$groups[$key].Add($entry)
	}
	$nodes = [System.Collections.Generic.List[object]]::new()
	foreach ($connection in $connections) {
		$key = Get-SqlBrowseKey $connection.Name
		# Wrap the whole if: an assignment unrolls an array result, so @() would become $null and one item a scalar.
		$own = @(if ($groups.ContainsKey($key)) { $groups[$key] })
		$groups.Remove($key)
		$info = $null
		$problem = $null
		try { $info = Get-SqlConnectionDisplayInfo -Name $connection.Name -StorePath $Store } catch { $problem = $_.Exception.Message }
		$nodes.Add([pscustomobject]@{
			Kind = 'Connection'
			Key = "C:$key"
			Name = $connection.Name
			Description = $connection.Description
			Info = $info
			Problem = $problem
			Aliases = $own
		})
		for ($index = 0; $index -lt $own.Count; $index++) {
			$aliasInfo = $null
			$aliasProblem = $problem
			if ($info) {
				try { $aliasInfo = Get-SqlConnectionDisplayInfo -Name $connection.Name -StorePath $Store -Database $own[$index].Database } catch { $aliasProblem = $_.Exception.Message }
			}
			$nodes.Add((New-SqlBrowseAliasNode -Entry $own[$index] -Connection $connection.Name -Saved $true -Last ($index -eq $own.Count - 1) -Info $aliasInfo -Problem $aliasProblem))
		}
	}
	# Aliases whose connection is not saved: kept with sql-connection delete -KeepDatabases, or with a damaged profile.
	foreach ($key in @($groups.Keys | Sort-Object)) {
		$group = @($groups[$key])
		$name = $group[0].Connection
		$damaged = [IO.File]::Exists((Get-SqlConnectionProfilePath -Name $name -StorePath $Store))
		$nodes.Add([pscustomobject]@{ Kind = 'Missing'; Key = "M:$key"; Name = $name; Damaged = $damaged; Aliases = $group })
		for ($index = 0; $index -lt $group.Count; $index++) {
			$nodes.Add((New-SqlBrowseAliasNode -Entry $group[$index] -Connection $name -Saved $false -Last ($index -eq $group.Count - 1) -Info $null -Problem $null))
		}
	}
	$nodes.Add([pscustomobject]@{ Kind = 'New'; Key = 'N' })
	return [pscustomobject]@{ Nodes = $nodes.ToArray(); Warnings = $warnings.ToArray() }
}

function Get-SqlBrowseAccessText {
	param([string]$Access, [int]$Width = 0)
	$color = if ($Access -eq 'ReadOnly') { $ansi.Green } else { $ansi.Yellow }
	return "$color$($Access.PadRight($Width))$($ansi.Reset)"
}

function Get-SqlBrowsePreview {
	param([object]$Node, [string]$Store)
	$lines = [System.Collections.Generic.List[string]]::new()
	$field = { param($label, $value) $lines.Add("$($ansi.Gray)$($label.PadRight(13))$($ansi.Reset)$value") }
	$title = { param($name, $kind) $lines.Add("$($ansi.Bold)$(Format-SqlBrowseText $name)$($ansi.Reset)  $kind"); $lines.Add('') }
	$connectionText = {
		param($info, $heading)
		& $field 'Server' (Format-SqlBrowseText $info.Server)
		& $field 'Database' $(if ($info.Database) { Format-SqlBrowseText $info.Database } else { "$($ansi.Gray)the default database of the login$($ansi.Reset)" })
		& $field 'Login' (Format-SqlBrowseText $info.Authentication)
		$lines.Add('')
		$lines.Add("$($ansi.Gray)$heading$($ansi.Reset)")
		$lines.Add((Format-SqlBrowseText $info.ConnectionString))
	}
	$description = if ($Node.Description) { Format-SqlBrowseText $Node.Description } else { "$($ansi.Gray)(none)$($ansi.Reset)" }
	switch ($Node.Kind) {
		'Connection' {
			& $title $Node.Name "$($ansi.Gray)SQL connection$($ansi.Reset)"
			& $field 'Description' $description
			if ($Node.Info) {
				& $connectionText $Node.Info 'Connection string (password hidden)'
			} else {
				$lines.Add("$($ansi.Red)$(Format-SqlBrowseText $Node.Problem)$($ansi.Reset)")
			}
			$lines.Add('')
			if ($Node.Aliases.Count) {
				$lines.Add("$($ansi.Gray)Database aliases$($ansi.Reset)")
				foreach ($entry in $Node.Aliases) {
					$lines.Add("  $(Format-SqlBrowseText $entry.Alias)  $($ansi.Gray)$(Format-SqlBrowseText $entry.Database)$($ansi.Reset)  $(Get-SqlBrowseAccessText $entry.Access)")
				}
			} else {
				$lines.Add("$($ansi.Gray)No database aliases. Press a to add one.$($ansi.Reset)")
			}
		}
		'Alias' {
			& $title $Node.Alias "$($ansi.Gray)database alias$($ansi.Reset)"
			& $field 'Description' $description
			& $field 'Connection' (Format-SqlBrowseText $Node.Connection)
			& $field 'Database' (Format-SqlBrowseText $Node.Database)
			$rule = if ($Node.Access -eq 'ReadOnly') { 'Agents do not change this database.' } else { 'Agents can change it when their task allows it.' }
			& $field 'Access' "$(Get-SqlBrowseAccessText $Node.Access)  $($ansi.Gray)$rule$($ansi.Reset)"
			if ($Node.Info) {
				& $connectionText $Node.Info 'Connection string with this database (password hidden)'
			} elseif (-not $Node.Saved) {
				$lines.Add('')
				$lines.Add("$($ansi.Red)The SQL connection '$(Format-SqlBrowseText $Node.Connection)' is not saved, or its profile cannot be read.$($ansi.Reset)")
				$lines.Add('Select that connection and press Enter to add it again; the alias then works.')
			} elseif ($Node.Problem) {
				$lines.Add('')
				$lines.Add("$($ansi.Red)$(Format-SqlBrowseText $Node.Problem)$($ansi.Reset)")
			}
		}
		'Missing' {
			if ($Node.Damaged) {
				& $title $Node.Name "$($ansi.Red)profile cannot be read$($ansi.Reset)"
				$lines.Add('The profile file of this connection is not valid, or it is not accessible.')
				$lines.Add('Press Enter to delete it, keep its database aliases, and add the connection again.')
			} else {
				& $title $Node.Name "$($ansi.Red)connection not saved$($ansi.Reset)"
				$lines.Add('These database aliases use this connection name, but no connection has it.')
				$lines.Add('They work again when you add a connection with this name: press Enter.')
				$lines.Add('You can also move each alias to another connection with e.')
			}
			$lines.Add('')
			foreach ($entry in $Node.Aliases) {
				$lines.Add("  $(Format-SqlBrowseText $entry.Alias)  $($ansi.Gray)$(Format-SqlBrowseText $entry.Database)$($ansi.Reset)  $(Get-SqlBrowseAccessText $entry.Access)")
			}
		}
		'New' {
			& $title 'Add a SQL connection' ''
			$lines.Add('Press Enter, then give a name, an optional description, and the')
			$lines.Add('connection string. The connection string prompt hides input.')
			$lines.Add('Then you can test the connection and add aliases for its databases.')
			$lines.Add('')
			& $field 'Store' (Format-SqlBrowseText $Store)
			$lines.Add('')
			$lines.Add("$($ansi.Gray)Keys$($ansi.Reset)")
			$lines.Add('  Enter       actions of the selected item')
			$lines.Add('  n           add a connection')
			$lines.Add('  a / Insert  add an alias for a database on the selected connection')
			$lines.Add('  e / F2      edit the selected item')
			$lines.Add('  t           test the selected connection or alias')
			$lines.Add('  d / Del     delete the selected item')
			$lines.Add('  r / F5      read the store again')
			$lines.Add('  q / Esc     quit')
		}
	}
	return $lines -join "`n"
}

function Format-SqlBrowseLine {
	param([object]$Node, [int]$NameWidth, [int]$DetailWidth)
	switch ($Node.Kind) {
		'Connection' {
			$server = if ($Node.Info) { "$($ansi.Cyan)$((Format-SqlBrowseText $Node.Info.Server $DetailWidth).PadRight($DetailWidth))" } else { "$($ansi.Red)$('(cannot read)'.PadRight($DetailWidth))" }
			return "$($ansi.Bold)$((Format-SqlBrowseText $Node.Name $NameWidth).PadRight($NameWidth))$($ansi.Reset)  $server$($ansi.Reset)  $($ansi.Gray)$(Format-SqlBrowseText $Node.Description)$($ansi.Reset)"
		}
		'Alias' {
			$branch = if ($Node.Last) { '└─ ' } else { '├─ ' }
			$name = (Format-SqlBrowseText $Node.Alias ($NameWidth - 3)).PadRight($NameWidth - 3)
			$database = (Format-SqlBrowseText $Node.Database $DetailWidth).PadRight($DetailWidth)
			return "$($ansi.Gray)$branch$($ansi.Reset)$name  $database  $(Get-SqlBrowseAccessText $Node.Access 9)  $($ansi.Gray)$(Format-SqlBrowseText $Node.Description)$($ansi.Reset)"
		}
		'Missing' {
			$state = if ($Node.Damaged) { '(profile cannot be read)' } else { '(connection not saved)' }
			return "$($ansi.Red)$((Format-SqlBrowseText $Node.Name $NameWidth).PadRight($NameWidth))$($ansi.Reset)  $($ansi.Gray)$state$($ansi.Reset)"
		}
		default { return "$($ansi.Green)+ Add connection$($ansi.Reset)" }
	}
}

# Shows the tree. Returns the pressed key and the selected node, or $null when the user quits.
function Show-SqlBrowseTree {
	param([object[]]$Nodes, [string]$Directory, [int]$Position, [string]$Notice)
	# Inside switch, $_ is the switch value, so keep the node in its own variable.
	$nameWidth = [Math]::Min(40, [Math]::Max(16, ($Nodes | ForEach-Object {
		$node = $_
		switch ($node.Kind) { 'Alias' { $node.Alias.Length + 3 } 'New' { 0 } default { $node.Name.Length } }
	} | Measure-Object -Maximum).Maximum))
	$detailWidth = [Math]::Min(32, [Math]::Max(8, ($Nodes | ForEach-Object {
		$node = $_
		switch ($node.Kind) { 'Alias' { $node.Database.Length } 'Connection' { if ($node.Info) { $node.Info.Server.Length } else { 13 } } default { 0 } }
	} | Measure-Object -Maximum).Maximum))
	# Field 2 is the preview file, which fzf quotes for cmd; field 3 is the node index.
	$lines = for ($index = 0; $index -lt $Nodes.Count; $index++) {
		"$(Format-SqlBrowseLine -Node $Nodes[$index] -NameWidth $nameWidth -DetailWidth $detailWidth)`t$(Join-Path $Directory "$index.txt")`t$index"
	}
	# The header shares the width of the list, which is half the window: keep its lines short.
	$header = "Enter actions  n new connection  a add alias`ne edit  t test  d delete  r refresh  q quit"
	if ($Notice) { $header += "`n$($ansi.Yellow)$Notice$($ansi.Reset)" }
	# fzf runs the preview through $env:SHELL when it is set, for example by Git Bash; type needs cmd, the default.
	# The process environment is also the caller's when PowerShell runs this script directly, so restore it.
	$shell = $env:SHELL
	try {
		if ($null -ne $shell) { Remove-Item Env:SHELL }
		# --sync loads the input before the start event; otherwise pos() runs on an empty list and the focus is lost.
		$output = @($lines | fzf @fzfStyle --no-input --disabled --sync '--height=70%' '--ansi' "--delimiter=`t" '--with-nth=1' `
			'--preview=type {2}' '--preview-window=right,50%,wrap' "--header=$header" '--header-first' `
			'--expect=a,d,e,n,q,r,t,del,insert,f2,f5' "--bind=start:pos($Position)")
		$code = $LASTEXITCODE
	} finally {
		if ($null -ne $shell) { $env:SHELL = $shell }
	}
	if ($code -eq 2) { throw 'fzf cannot show the tree.' }
	# Esc and Ctrl+C give no output. With --expect, the output is the key and then the selection.
	if ($output.Count -lt 2 -or -not $output[1] -or $output[0] -eq 'q') { return $null }
	$index = [int]($output[1] -split "`t")[-1]
	return [pscustomobject]@{ Key = [string]$output[0]; Node = $Nodes[$index]; Index = $index }
}

# The preview files show connection strings without passwords. A run deletes its directory when it ends. Its lock
# marks a directory in use, so that a later run deletes only the directories of runs that ended without cleanup.
function New-SqlBrowsePreviewDirectory {
	$base = [IO.Path]::GetTempPath()
	foreach ($old in [IO.Directory]::GetDirectories($base, 'sql-browse-*')) {
		if ([IO.Path]::GetFileName($old) -notmatch '^sql-browse-[0-9a-f]{32}$') { continue }
		# A run that has just started can still be about to lock its directory.
		if ([IO.Directory]::GetCreationTimeUtc($old) -gt [DateTime]::UtcNow.AddMinutes(-1)) { continue }
		try {
			$probe = [IO.File]::Open((Join-Path $old '.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
			$probe.Dispose()
			[IO.Directory]::Delete($old, $true)
		} catch {
			# A running instance holds the lock.
		}
	}
	$directory = Join-Path $base "sql-browse-$([guid]::NewGuid().ToString('N'))"
	$null = [IO.Directory]::CreateDirectory($directory)
	return [pscustomobject]@{ Path = $directory; Lock = [IO.File]::Open((Join-Path $directory '.lock'), 'CreateNew', 'ReadWrite', 'None') }
}

function Write-SqlBrowsePreviews {
	param([object[]]$Nodes, [string]$Directory, [string]$Store)
	foreach ($file in [IO.Directory]::GetFiles($Directory, '*.txt')) { [IO.File]::Delete($file) }
	$encoding = [Text.UTF8Encoding]::new($false)
	for ($index = 0; $index -lt $Nodes.Count; $index++) {
		[IO.File]::WriteAllText((Join-Path $Directory "$index.txt"), (Get-SqlBrowsePreview -Node $Nodes[$index] -Store $Store), $encoding)
	}
}

$helpTokens = @('help', '/?', '--help')
# A stray help word means help only when nothing else was given: with -StorePath, it can be part of an unquoted path.
$onlyHelpStray = $null -ne $UnexpectedArguments -and $UnexpectedArguments.Count -gt 0 -and
	@($UnexpectedArguments | Where-Object { $_ -notin $helpTokens }).Count -eq 0
if ($Help -or ($onlyHelpStray -and -not $PSBoundParameters.ContainsKey('StorePath'))) {
	Show-SqlBrowseHelp
	return
}
if (Test-SqlCliFileTarget -ScriptPath $PSCommandPath) {
	$joined = Get-SqlCliJoinedArgumentError -BoundParameters $PSBoundParameters -ValueNames @('StorePath') -QuoteFreeNames @('StorePath') -QuoteEndNames @()
	if ($joined) {
		Show-SqlBrowseHelp
		throw $joined
	}
}
# Test the count: a one-item array is falsy when its item is '' or 0, and @($null) has one item.
if ($null -ne $UnexpectedArguments -and $UnexpectedArguments.Count -gt 0) {
	Show-SqlBrowseHelp
	throw (Get-SqlCliUnexpectedArgumentError -Arguments $UnexpectedArguments -Invocation $MyInvocation -Example '-StorePath')
}
$storePathError = Get-SqlCliStorePathError -BoundParameters $PSBoundParameters
if ($storePathError) {
	Show-SqlBrowseHelp
	throw $storePathError
}
if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
	throw "$consoleMissing In scripts, use sql-connection and sql-database."
}
if (-not (Ensure-Fzf)) { exit 1 }

$store = Get-SqlConnectionStorePath -StorePath $StorePath
$preview = New-SqlBrowsePreviewDirectory
try {
	$focusKey = $null
	$focusIndex = 0
	$shownWarnings = ''
	while ($true) {
		$tree = Get-SqlBrowseTree -Store $store
		$nodes = $tree.Nodes
		# Show the warnings above the menu once; the header names them while they last.
		$warningText = $tree.Warnings -join "`n"
		if ($warningText -and $warningText -ne $shownWarnings) {
			foreach ($message in $tree.Warnings) { Write-Warning $message }
		}
		$shownWarnings = $warningText
		$notice = if ($tree.Warnings.Count) { "Unreadable store files: $($tree.Warnings.Count). See the warnings above." } else { '' }
		Write-SqlBrowsePreviews -Nodes $nodes -Directory $preview.Path -Store $store
		$index = [Array]::FindIndex($nodes, [Predicate[object]] { param($node) $node.Key -eq $focusKey })
		if ($index -lt 0) { $index = [Math]::Min($focusIndex, $nodes.Count - 1) }
		$choice = Show-SqlBrowseTree -Nodes $nodes -Directory $preview.Path -Position ($index + 1) -Notice $notice
		if (-not $choice) { break }
		$focusKey = $choice.Node.Key
		$focusIndex = $choice.Index
		try {
			$next = Invoke-SqlBrowseAction -Key $choice.Key -Node $choice.Node -Store $store
			if ($next) { $focusKey = $next }
		} catch {
			Write-Host $_.Exception.Message -ForegroundColor Red
		}
	}
} finally {
	$preview.Lock.Dispose()
	try {
		[IO.Directory]::Delete($preview.Path, $true)
	} catch {
		Write-Warning "Cannot delete the preview files in '$($preview.Path)'. The next run of sql-browse deletes them."
	}
}
# Quitting with Esc leaves the exit code 130 of fzf; a quit is a success.
exit 0
