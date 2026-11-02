<#
.SYNOPSIS
Manages aliases for databases on saved SQL Server connections. Run "sql-database help" for commands and arguments.
#>

# The profile library needs .NET 5 APIs, so PowerShell 7.0 and Windows PowerShell 5.1 cannot run it.
#Requires -Version 7.1
param(
	[Parameter(Position = 0)]
	[ArgumentCompletions('add', 'modify', 'delete', 'list', 'discover', 'help')]
	[string]$Command,
	[string]$Alias,
	[string]$Connection,
	[string]$Database,
	[AllowEmptyString()]
	[string]$Description,
	[switch]$ClearDescription,
	[ArgumentCompletions('ReadOnly', 'ReadWrite')]
	[string]$Access,
	[switch]$Verify,
	[string]$StorePath,
	[switch]$NonInteractive,
	[Alias('h')]
	[switch]$Help,
	# Collects stray values, so that a misplaced value gets a message instead of a binding error that echoes it.
	[Parameter(ValueFromRemainingArguments = $true, DontShow = $true)]
	[object[]]$UnexpectedArguments
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common\common.ps1')

function Show-SqlDatabaseHelp {
	Write-Host @'
Database aliases for saved SQL Server connections (Windows / PowerShell 7)

An alias names one database on a connection that sql-connection saved.
Connection names and aliases share one name space, so a name is either a
connection or an alias. New-SavedSqlConnection -Name accepts both.

Commands:
  add       Create an alias; duplicate names are rejected.
  modify    Change its connection, database, access, or description.
  delete    Delete the alias; does not change the database or connection.
  list      List aliases, or find them with -Alias or -Connection.
  discover  Connect and list the databases on the server of -Connection.
  help      Show this help.

Arguments:
  -Command           Command name (also accepted as the first argument).
  -Alias             Alias; case-insensitive, up to 128 characters.
  -Connection        Saved connection name; see sql-connection list.
  -Database          Database name on that server, up to 128 characters.
  -Description       Optional purpose. On modify, an empty string clears it.
  -ClearDescription  Modify only: clear the purpose without an empty argument.
  -Access            ReadOnly (the default on add) or ReadWrite. A rule for
                     agents and scripts; SQL Server does not enforce it.
  -Verify            Add/modify only: open the database before saving.
                     Modify with -Verify and no changes only opens it.
  -StorePath         Override %LOCALAPPDATA%\SqlConnections.
  -NonInteractive    Fail instead of prompting for missing input.
  -Help / -h         Show this help without making changes (/? or --help
                     alone also work).

Omitted required values are prompted. Description is optional on add.
An empty -Alias, -Connection, or -Database value is an error.
Prompts need a console: with redirected input, missing values fail as
with -NonInteractive.
Modify preserves omitted fields when at least one change is supplied.
Without changes, modify prompts; Enter preserves each existing value.
Omitting -Alias on modify/delete displays the saved aliases.
Delete asks for confirmation only when the alias comes from the prompt.
Only discover and -Verify connect to SQL Server. Discover opens master,
reads sys.databases, and changes nothing. It also shows the database of each
alias that the server does not show, with the state NOT FOUND and no
HasAccess value: the name can be wrong, or the server can hide the database
from this login. If modify -Alias with -Verify opens it, it exists; if not,
the name is wrong or this login cannot open the database.
For an interactive tree of connections and aliases, run sql-browse.

Quoting: in PowerShell, use single quotes for literal values. In cmd,
double-quote values that contain spaces or & | < > ^, close every quote,
and do not end a quoted value with a backslash. Through the .cmd shim or
pwsh -File, a value cannot contain a word that starts with -; an alias,
connection, or access value cannot contain a quote; and a database name
or description cannot end with one.
The .cmd shim passes the arguments through cmd again, so do not run
sql-database.cmd from PowerShell; there, the bare name runs the .ps1.

Examples:
  sql-database add -Alias dat-data -Connection DAT -Database DatData
  sql-database modify -Alias dat-data -Description "DAT jobs and queues"
  sql-database modify -Alias dat-data -Access ReadWrite
  sql-database modify -Alias dat-data -Verify
  sql-database list -Connection DAT
  sql-database discover -Connection DAT
  sql-database delete -Alias dat-data
'@
}

# Returns the saved spelling of a connection name, so that an alias keeps it whatever letter case was typed.
# A damaged profile gives the typed name: an alias names its connection by name, and the user can add
# that profile again with the same name.
function Resolve-SqlDatabaseConnectionName {
	param([string]$Name, [string]$StorePath)
	$path = Get-SqlConnectionProfilePath -Name $Name -StorePath $StorePath
	if (-not [IO.File]::Exists($path)) {
		if ([IO.File]::Exists((Get-SqlDatabaseAliasPath -Alias $Name -StorePath $StorePath))) {
			throw 'The -Connection value names a database alias, not a SQL connection. Use sql-connection list to see saved connections.'
		}
		throw "The SQL connection '$($Name.Trim())' does not exist in '$StorePath'. Use sql-connection list to see saved connections."
	}
	try {
		return (Read-SqlConnectionProfile -Path $path).Name
	} catch {
		return $Name.Trim()
	}
}

# Shows the saved connections and prompts for one. Returns '' when the user cancels.
function Read-SqlDatabaseConnectionName {
	param([string]$StorePath, [string]$Missing, [switch]$NonInteractive)
	$available = @(Get-SqlConnectionProfiles -StorePath $StorePath)
	if (-not $available.Count) {
		# Files that the library skipped with a warning are not "no saved connections".
		if ([IO.Directory]::Exists($StorePath) -and @([IO.Directory]::GetFiles($StorePath, '*.json')).Count -gt 0) {
			throw "There are no readable SQL connection profiles in '$StorePath'. Give -Connection, or repair the profiles as the warnings describe."
		}
		throw "There are no saved SQL connections in '$StorePath'. Use sql-connection add first."
	}
	$available | Format-Table -AutoSize | Out-Host
	Assert-SqlCliPrompt $Missing -NonInteractive:$NonInteractive
	$entered = Read-SqlCliText 'Connection name (Enter cancels)' -Missing $Missing
	Assert-SqlConnectionPublicText -Value $entered -Subject 'The entered connection name'
	return $entered
}

$Command = ([string]$Command).Trim()
$helpTokens = @('help', '/?', '--help')
# A stray help word means help only when nothing else was given: in "-Description Get help", it is an unquoted value.
$valueBound = @('Alias', 'Connection', 'Database', 'Description', 'ClearDescription', 'Access', 'Verify' | Where-Object { $PSBoundParameters.ContainsKey($_) }).Count -gt 0
$onlyHelpStray = $null -ne $UnexpectedArguments -and $UnexpectedArguments.Count -gt 0 -and
	@($UnexpectedArguments | Where-Object { $_ -notin $helpTokens }).Count -eq 0
if ($Help -or $Command -in $helpTokens -or ($onlyHelpStray -and -not $valueBound)) {
	Show-SqlDatabaseHelp
	return
}
# Check joined arguments before stray arguments.
if (Test-SqlCliFileTarget -ScriptPath $PSCommandPath) {
	$joined = Get-SqlCliJoinedArgumentError -BoundParameters $PSBoundParameters `
		-ValueNames @('Command', 'Alias', 'Connection', 'Database', 'Description', 'Access', 'StorePath') `
		-QuoteFreeNames @('Command', 'Alias', 'Connection', 'Access', 'StorePath') -QuoteEndNames @('Database', 'Description')
	if ($joined) {
		Show-SqlDatabaseHelp
		throw $joined
	}
}
# Test the count: a one-item array is falsy when its item is '' or 0, and @($null) has one item.
if ($null -ne $UnexpectedArguments -and $UnexpectedArguments.Count -gt 0) {
	Show-SqlDatabaseHelp
	throw (Get-SqlCliUnexpectedArgumentError -Arguments $UnexpectedArguments -Invocation $MyInvocation -Example '-Alias or -Database')
}
$storePathError = Get-SqlCliStorePathError -BoundParameters $PSBoundParameters
if ($storePathError) {
	Show-SqlDatabaseHelp
	throw $storePathError
}

$validCommands = @('add', 'modify', 'delete', 'list', 'discover')
$helpShown = $false
if (-not $Command -or $Command -notin $validCommands) {
	Show-SqlDatabaseHelp
	$helpShown = $true
	# Do not repeat a command given as an argument: a misplaced positional value can be a connection string.
	$unknown = if ($Command) { 'Unknown command.' } else { '' }
	$missing = 'Specify -Command add, modify, delete, list, or discover.'
	Assert-SqlCliPrompt ("$unknown $missing").Trim() -NonInteractive:$NonInteractive
	if ($unknown) { Write-Host $unknown -ForegroundColor Yellow }
	do {
		$Command = Read-SqlCliText 'Command (add, modify, delete, list, discover, help; Enter cancels)' -Missing $missing
		if (-not $Command) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
		if ($Command -in $helpTokens) {
			Show-SqlDatabaseHelp
		} elseif ($Command -notin $validCommands) {
			Write-Host (Format-SqlCliUnknownCommand $Command) -ForegroundColor Yellow
		}
	} while ($Command -notin $validCommands)
}

# Refuse arguments that the command does not use, so that a mistake does not pass without notice.
$commandsOf = [ordered]@{
	Alias = @('add', 'modify', 'delete', 'list')
	Connection = @('add', 'modify', 'list', 'discover')
	Database = @('add', 'modify')
	Description = @('add', 'modify')
	ClearDescription = @('modify')
	Access = @('add', 'modify')
	Verify = @('add', 'modify')
}
foreach ($parameterName in $commandsOf.Keys) {
	if ($PSBoundParameters.ContainsKey($parameterName) -and $Command -notin $commandsOf[$parameterName]) {
		if (-not $helpShown) { Show-SqlDatabaseHelp }
		throw "-$parameterName is accepted only for $($commandsOf[$parameterName] -join ', ')."
	}
}
$hasDescription = $PSBoundParameters.ContainsKey('Description')
if ($ClearDescription) {
	if ($hasDescription) {
		if (-not $helpShown) { Show-SqlDatabaseHelp }
		throw 'Use -ClearDescription with modify, without -Description.'
	}
	$Description = ''
	$hasDescription = $true
}
# Names and descriptions are public metadata. Refuse a password before any prompt, and do not echo it.
try {
	# An agent shell can lose a variable between calls. An empty explicit name must not select all aliases,
	# a prompt, or the saved value, as an omitted name does.
	foreach ($parameterName in @('Alias', 'Connection')) {
		if ($PSBoundParameters.ContainsKey($parameterName) -and [string]::IsNullOrWhiteSpace($PSBoundParameters[$parameterName])) {
			throw "The -$parameterName value is empty. Give a name, or omit -$parameterName."
		}
	}
	foreach ($parameterName in @('Alias', 'Connection', 'Database', 'Description')) {
		if ($PSBoundParameters[$parameterName] -is [string]) {
			Assert-SqlConnectionPublicText -Value $PSBoundParameters[$parameterName] -Subject "The -$parameterName value"
		}
	}
	if ($PSBoundParameters.ContainsKey('Access')) { $Access = ConvertTo-SqlDatabaseAccess -Access $Access }
	if ($PSBoundParameters.ContainsKey('Database')) {
		$Database = $Database.Trim()
		Assert-SqlDatabaseName -Database $Database
	}
} catch {
	if (-not $helpShown) { Show-SqlDatabaseHelp }
	throw
}

$store = Get-SqlConnectionStorePath -StorePath $StorePath
$catalog = Get-SqlDatabaseCatalogPath -StorePath $store
$aliasNotFoundMessage = "The database alias does not exist in '$catalog'. Use list to see saved aliases."

if ($Command -ieq 'list') {
	if (-not [string]::IsNullOrWhiteSpace($Alias) -and -not [IO.File]::Exists((Get-SqlDatabaseAliasPath -Alias $Alias -StorePath $store))) {
		throw "The database alias does not exist in '$catalog'. Run list without -Alias to see saved aliases."
	}
	# A mistyped connection must not look like a connection without aliases. A deleted connection whose
	# aliases were kept still lists them, so that the user can see what waits for that name.
	if (-not [string]::IsNullOrWhiteSpace($Connection) -and -not [IO.File]::Exists((Get-SqlConnectionProfilePath -Name $Connection -StorePath $store))) {
		if (@(Get-SqlDatabaseAliases -Connection $Connection -StorePath $store).Count) {
			Write-Host "The SQL connection '$($Connection.Trim())' is not saved. These aliases work again when you add a connection with that name." -ForegroundColor Yellow
		} else {
			$null = Resolve-SqlDatabaseConnectionName -Name $Connection -StorePath $store
		}
	}
	$found = @(Get-SqlDatabaseAliases -Alias $Alias -Connection $Connection -StorePath $store)
	if (-not $found.Count) {
		# Name the catalog, so that a mistyped -StorePath does not look like an empty catalog.
		$hasAliasFiles = [IO.Directory]::Exists($catalog) -and @([IO.Directory]::GetFiles($catalog, '*.json')).Count -gt 0
		$message = if (-not [string]::IsNullOrWhiteSpace($Connection)) {
			"There are no database aliases for this connection in '$catalog'."
		} elseif ($hasAliasFiles) {
			"There are no readable database aliases in '$catalog'."
		} else {
			"There are no database aliases in '$catalog'. Use add first."
		}
		Write-Host $message
	}
	$found
	return
}

if ($Command -ieq 'discover') {
	if ([string]::IsNullOrWhiteSpace($Connection)) {
		if (-not $helpShown) { Show-SqlDatabaseHelp; $helpShown = $true }
		$Connection = Read-SqlDatabaseConnectionName -StorePath $store -Missing 'Specify -Connection for discover.' -NonInteractive:$NonInteractive
		if (-not $Connection) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
	}
	$savedConnection = Resolve-SqlDatabaseConnectionName -Name $Connection -StorePath $store
	$aliases = @(Get-SqlDatabaseAliases -Connection $savedConnection -StorePath $store)
	$databases = @(Get-SqlServerDatabases -Connection $savedConnection -StorePath $store)
	if (-not $databases.Count) { Write-Host "The server of '$savedConnection' shows no databases to this login." }
	foreach ($item in $databases) {
		[pscustomobject]@{
			Database = $item.Database
			State = $item.State
			HasAccess = $item.HasAccess
			Aliases = @($aliases | Where-Object { $_.Database -ieq $item.Database } | ForEach-Object Alias) -join ', '
		}
	}
	# An alias whose database the server does not show is mistyped, renamed, dropped, or hidden from this login.
	# sys.databases can hide a database that the login can open, so its access is unknown; -Verify tells.
	$shown = @($databases | ForEach-Object Database)
	$aliases | Where-Object { $_.Database -notin $shown } | Group-Object { $_.Database.ToUpperInvariant() } | ForEach-Object {
		[pscustomobject]@{
			Database = $_.Group[0].Database
			State = 'NOT FOUND'
			HasAccess = $null
			Aliases = @($_.Group | ForEach-Object Alias) -join ', '
		}
	}
	return
}

$aliasPrompted = $false
if ([string]::IsNullOrWhiteSpace($Alias)) {
	if (-not $helpShown) { Show-SqlDatabaseHelp; $helpShown = $true }
	if ($Command -in @('modify', 'delete')) {
		$available = @(Get-SqlDatabaseAliases -StorePath $store)
		if (-not $available.Count) {
			# Files that the library skipped with a warning are not "no aliases".
			if ([IO.Directory]::Exists($catalog) -and @([IO.Directory]::GetFiles($catalog, '*.json')).Count -gt 0) {
				throw "There are no readable database aliases in '$catalog'. Give -Alias; delete -Alias also deletes a damaged alias file."
			}
			throw "There are no database aliases in '$catalog'. Use add first."
		}
		$available | Format-Table -AutoSize | Out-Host
	}
	Assert-SqlCliPrompt 'Specify -Alias.' -NonInteractive:$NonInteractive
	$Alias = Read-SqlCliText 'Database alias (Enter cancels)' -Missing 'Specify -Alias.'
	if (-not $Alias) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
	Assert-SqlConnectionPublicText -Value $Alias -Subject 'The entered alias'
	$aliasPrompted = $true
}
$Alias = $Alias.Trim()
$aliasPath = Get-SqlDatabaseAliasPath -Alias $Alias -StorePath $store

if ($Command -ieq 'delete') {
	if (-not [IO.File]::Exists($aliasPath)) { throw $aliasNotFoundMessage }
	# Show the saved alias, not the typed casing; a damaged file stays deletable under the typed alias.
	$savedAlias = try { (Read-SqlDatabaseAlias -Path $aliasPath).Alias } catch { $Alias }
	# An alias picked at the prompt gets a confirmation, as in the other delete commands; -Alias stays unattended.
	if ($aliasPrompted -and -not (Confirm-Action "Delete database alias '$savedAlias'?" -Color Yellow)) {
		Write-Host 'Aborted.' -ForegroundColor DarkGray
		return
	}
	Remove-SqlDatabaseAlias -Alias $Alias -StorePath $store
	Write-Host "Deleted database alias '$savedAlias'." -ForegroundColor Green
	return
}

$expectedContent = $null
$hasConnection = -not [string]::IsNullOrWhiteSpace($Connection)
$hasDatabase = $PSBoundParameters.ContainsKey('Database')
$hasAccess = $PSBoundParameters.ContainsKey('Access')
if ($Command -ieq 'add') {
	Assert-SqlConnectionNameFree -Name $Alias -StorePath $store -Kind Alias
	if (-not $hasConnection) {
		if (-not $helpShown) { Show-SqlDatabaseHelp; $helpShown = $true }
		$Connection = Read-SqlDatabaseConnectionName -StorePath $store -Missing 'Specify -Connection for add.' -NonInteractive:$NonInteractive
		if (-not $Connection) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
	}
	$savedConnection = Resolve-SqlDatabaseConnectionName -Name $Connection -StorePath $store
	if (-not $hasDatabase) {
		if (-not $helpShown) { Show-SqlDatabaseHelp; $helpShown = $true }
		Assert-SqlCliPrompt 'Specify -Database for add.' -NonInteractive:$NonInteractive
		$Database = Read-SqlCliText 'Database name (Enter cancels)' -Missing 'Specify -Database for add.'
		if (-not $Database) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
		Assert-SqlConnectionPublicText -Value $Database -Subject 'The entered database name'
		Assert-SqlDatabaseName -Database $Database
	}
	$accessValue = if ($hasAccess) { $Access } else { 'ReadOnly' }
	$entry = [pscustomobject]@{
		Version = 1
		Alias = $Alias
		Connection = $savedConnection
		Database = $Database
		Access = $accessValue
		Description = $Description
	}
} else {
	if (-not [IO.File]::Exists($aliasPath)) { throw $aliasNotFoundMessage }
	$expectedContent = [IO.File]::ReadAllText($aliasPath)
	$entry = Read-SqlDatabaseAlias -Path $aliasPath
	$hasChanges = $hasConnection -or $hasDatabase -or $hasDescription -or $hasAccess
	if (-not $hasChanges -and $Verify) {
		Test-SqlDatabaseAccess -Connection $entry.Connection -Database $entry.Database -StorePath $store
		Write-Host "Opened database '$($entry.Database)' through SQL connection '$($entry.Connection)'. No changes." -ForegroundColor Green
		return
	}
	if (-not $hasChanges) {
		if (-not $helpShown) { Show-SqlDatabaseHelp; $helpShown = $true }
		$missing = 'Specify -Connection, -Database, -Description, -ClearDescription, or -Access for modify.'
		Assert-SqlCliPrompt $missing -NonInteractive:$NonInteractive
		Write-Host "Current connection: $($entry.Connection)"
		Write-Host "Current database: $($entry.Database)"
		Write-Host "Current access: $($entry.Access)"
		Write-Host "Current description: $($entry.Description)"
		$entered = Read-SqlCliText 'New connection (Enter keeps it)' -Missing $missing
		Assert-SqlConnectionPublicText -Value $entered -Subject 'The entered connection name'
		if ($entered) { $Connection = $entered; $hasConnection = $true }
		$entered = Read-SqlCliText 'New database (Enter keeps it)' -Missing $missing
		Assert-SqlConnectionPublicText -Value $entered -Subject 'The entered database name'
		if ($entered) { Assert-SqlDatabaseName -Database $entered; $Database = $entered; $hasDatabase = $true }
		$entered = Read-SqlCliText 'New description (Enter keeps it; use -ClearDescription to clear it)' -Missing $missing
		Assert-SqlConnectionPublicText -Value $entered -Subject 'The entered description'
		if ($entered) { $Description = $entered; $hasDescription = $true }
		$entered = Read-SqlCliText 'New access, ReadOnly or ReadWrite (Enter keeps it)' -Missing $missing
		if ($entered) { $Access = ConvertTo-SqlDatabaseAccess -Access $entered; $hasAccess = $true }
		if (-not ($hasConnection -or $hasDatabase -or $hasDescription -or $hasAccess)) {
			Write-Host 'No changes.'
			return
		}
	}
	# The current connection is no change, also for an alias kept after sql-connection delete -KeepDatabases.
	if ($hasConnection -and (Get-SqlConnectionNameHash -Name $Connection -Subject 'a connection name') -ne
		(Get-SqlConnectionNameHash -Name $entry.Connection -Subject 'a connection name')) {
		$entry.Connection = Resolve-SqlDatabaseConnectionName -Name $Connection -StorePath $store
	}
	if ($hasDatabase) { $entry.Database = $Database }
	if ($hasDescription) { $entry.Description = $Description }
	if ($hasAccess) { $entry.Access = $Access }
}

if ($Verify) {
	Test-SqlDatabaseAccess -Connection $entry.Connection -Database $entry.Database -StorePath $store
	Write-Host "Opened database '$($entry.Database)' through SQL connection '$($entry.Connection)'." -ForegroundColor DarkGray
}
Write-SqlDatabaseAlias -Entry $entry -StorePath $store -ExpectedContent $expectedContent -Add:($Command -ieq 'add')
Write-Host "Saved database alias '$($entry.Alias)' for '$($entry.Database)' on '$($entry.Connection)' ($($entry.Access))." -ForegroundColor Green
