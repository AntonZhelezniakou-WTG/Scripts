<#
.SYNOPSIS
Manages named SQL Server connection profiles. Run "sql-connection help" for commands and arguments.
#>

# The profile library needs .NET 5 APIs, so PowerShell 7.0 and Windows PowerShell 5.1 cannot run it.
#Requires -Version 7.1
param(
	[Parameter(Position = 0)]
	[ArgumentCompletions('add', 'modify', 'delete', 'list', 'help')]
	[string]$Command,
	[string]$Name,
	[AllowEmptyString()]
	[string]$Description,
	[switch]$ClearDescription,
	[object]$ConnectionString,
	[switch]$WithDatabases,
	[switch]$KeepDatabases,
	[string]$StorePath,
	[switch]$NonInteractive,
	[Alias('h')]
	[switch]$Help,
	# Collects stray values so that PowerShell's binding error cannot echo a forgotten -ConnectionString value.
	[Parameter(ValueFromRemainingArguments = $true, DontShow = $true)]
	[object[]]$UnexpectedArguments
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common\common.ps1')

function Show-SqlConnectionHelp {
	Write-Host @'
SQL Server connection profiles (Windows / PowerShell 7)

Commands:
  add     Create a named connection; duplicate names are rejected.
  modify  Change its description or replace its connection string.
  delete  Delete the named local profile; does not change the database.
  list    List names and descriptions, or find one with -Name.
  help    Show this help.

Arguments:
  -Command           Command name (also accepted as the first argument).
  -Name              Connection name; case-insensitive, up to 128 characters.
                     It cannot be the name of a database alias.
  -Description       Optional purpose. On modify, an empty string clears it.
  -ClearDescription  Modify only: clear the purpose without an empty argument.
  -ConnectionString  SQL Server string or SecureString; add/modify only.
  -WithDatabases     Delete only: also delete the database aliases that use
                     the connection.
  -KeepDatabases     Delete only: keep those aliases. They work again when
                     you add a connection with the same name.
  -StorePath         Override %LOCALAPPDATA%\SqlConnections.
  -NonInteractive    Fail instead of prompting for missing input.
  -Help / -h         Show this help without making changes (/? or --help
                     alone also work).

Omitted required values are prompted. Description is optional on add.
Prompts need a console: with redirected input, missing values fail as
with -NonInteractive.
Modify preserves omitted fields when at least one change is supplied.
Without changes, modify prompts; Enter preserves each existing value.
Omitting -Name on modify/delete displays the available connections.
Delete asks for confirmation only when the name comes from the prompt.
Delete refuses a connection that database aliases use, unless -WithDatabases
or -KeepDatabases is given. To replace a damaged profile and keep its
aliases, use delete -KeepDatabases and then add with the same name. Add, and
modify with a new connection string, name the aliases that then use it. To
name databases on a connection, run sql-database help. For an interactive
tree of connections and aliases, run sql-browse.

Quoting: in PowerShell, use single quotes for literal values: double quotes
expand $ and the backtick, and an unquoted ; ends the command. In cmd,
double-quote values that contain spaces or & | < > ^, do not use ^ escapes,
close every quote, do not end a quoted value with a backslash, and write a
quote inside a value as "" (never \"); cmd expands %NAME% even in quotes,
and with delayed expansion also changes ! and ^, so give such a connection
string at the hidden prompt. Through the .cmd shim or pwsh -File, a value
cannot contain a word that starts with -, a name cannot contain a quote, and
a description cannot end with one: these forms look like arguments that a
quoting mistake joined.
The .cmd shim passes the arguments through cmd again, so do not run
sql-connection.cmd from PowerShell; there, the bare name runs the .ps1.

Examples:
  sql-connection add -Name dev -Description "Local development"
  sql-connection modify -Name dev -Description "Integration tests"
  sql-connection modify -Name dev -ClearDescription
  sql-connection modify -Name dev
  sql-connection delete -Name dev
  sql-connection list

Saved connection strings are encrypted with DPAPI; the prompt also hides input.
Prefer the prompt or a SecureString variable: literal secrets passed as command
arguments can remain in shell history or process arguments.
Only the same Windows user on the same computer can normally decrypt them.
Names and descriptions are public metadata; do not put passwords in them.
Saving a profile validates its syntax but does not contact SQL Server.
Only keywords and values that System.Data.SqlClient reads are accepted; for
example, Encrypt=Strict, Encrypt=Mandatory, and Authentication= are not.
'@
}

$Command = ([string]$Command).Trim()
$helpTokens = @('help', '/?', '--help')
# A stray help word means help only when nothing else was given: in "-Description Get help", it is an unquoted value.
$valueBound = @('Name', 'Description', 'ConnectionString', 'ClearDescription', 'WithDatabases', 'KeepDatabases' | Where-Object { $PSBoundParameters.ContainsKey($_) }).Count -gt 0
$onlyHelpStray = $null -ne $UnexpectedArguments -and $UnexpectedArguments.Count -gt 0 -and
	@($UnexpectedArguments | Where-Object { $_ -notin $helpTokens }).Count -eq 0
if ($Help -or $Command -in $helpTokens -or ($onlyHelpStray -and -not $valueBound)) {
	Show-SqlConnectionHelp
	return
}
# Check joined arguments before stray arguments, and do not echo the value: it can contain a connection string.
if (Test-SqlCliFileTarget -ScriptPath $PSCommandPath) {
	$joined = Get-SqlCliJoinedArgumentError -BoundParameters $PSBoundParameters `
		-ValueNames @('Command', 'Name', 'Description', 'ConnectionString', 'StorePath') `
		-QuoteFreeNames @('Command', 'Name', 'StorePath') -QuoteEndNames @('Description')
	if ($joined) {
		Show-SqlConnectionHelp
		throw $joined
	}
}
# Test the count: a one-item array is falsy when its item is '' or 0, and @($null) has one item.
if ($null -ne $UnexpectedArguments -and $UnexpectedArguments.Count -gt 0) {
	Show-SqlConnectionHelp
	throw (Get-SqlCliUnexpectedArgumentError -Arguments $UnexpectedArguments -Invocation $MyInvocation -Example '-Name or -ConnectionString')
}
if ($PSBoundParameters.ContainsKey('ConnectionString') -and $ConnectionString -isnot [Security.SecureString] -and [string]::IsNullOrWhiteSpace([string]$ConnectionString)) {
	Show-SqlConnectionHelp
	throw 'The -ConnectionString value is empty.'
}
$storePathError = Get-SqlCliStorePathError -BoundParameters $PSBoundParameters
if ($storePathError) {
	Show-SqlConnectionHelp
	throw $storePathError
}

$validCommands = @('add', 'modify', 'delete', 'list')
$helpShown = $false
if (-not $Command -or $Command -notin $validCommands) {
	Show-SqlConnectionHelp
	$helpShown = $true
	# Do not repeat a command given as an argument: a stray positional value can be a connection string.
	$unknown = if ($Command) { 'Unknown command.' } else { '' }
	$missing = 'Specify -Command add, modify, delete, or list.'
	Assert-SqlCliPrompt ("$unknown $missing").Trim() -NonInteractive:$NonInteractive
	if ($unknown) { Write-Host $unknown -ForegroundColor Yellow }
	do {
		$Command = Read-SqlCliText 'Command (add, modify, delete, list, help; Enter cancels)' -Missing $missing
		if (-not $Command) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
		if ($Command -in $helpTokens) {
			Show-SqlConnectionHelp
		} elseif ($Command -notin $validCommands) {
			Write-Host (Format-SqlCliUnknownCommand $Command) -ForegroundColor Yellow
		}
	} while ($Command -notin $validCommands)
}

$hasDescription = $PSBoundParameters.ContainsKey('Description')
$hasConnectionString = $PSBoundParameters.ContainsKey('ConnectionString')
if ($ClearDescription) {
	if ($Command -ine 'modify' -or $hasDescription) {
		if (-not $helpShown) { Show-SqlConnectionHelp }
		throw 'Use -ClearDescription with modify, without -Description.'
	}
	$Description = ''
	$hasDescription = $true
}
foreach ($switchName in @('WithDatabases', 'KeepDatabases')) {
	if ($PSBoundParameters.ContainsKey($switchName) -and $Command -ine 'delete') {
		if (-not $helpShown) { Show-SqlConnectionHelp }
		throw "Use -$switchName only with delete."
	}
}
if ($WithDatabases -and $KeepDatabases) {
	if (-not $helpShown) { Show-SqlConnectionHelp }
	throw 'Use -WithDatabases or -KeepDatabases, not both.'
}
if ($Command -in @('delete', 'list') -and ($hasDescription -or $hasConnectionString)) {
	if (-not $helpShown) { Show-SqlConnectionHelp }
	throw 'Description and ConnectionString are accepted only for add and modify.'
}
# Refuse a password in the public description before any value prompt; a prompted description is checked as it arrives.
if ($PSBoundParameters['Description'] -is [string]) {
	try {
		Assert-SqlConnectionPublicText -Value $PSBoundParameters['Description'] -Subject 'The -Description value'
	} catch {
		if (-not $helpShown) { Show-SqlConnectionHelp }
		throw
	}
}

$store = Get-SqlConnectionStorePath -StorePath $StorePath
# Name the store, so that a mistyped -StorePath does not look like an empty store or a missing profile.
# Files that the library skipped with a warning are not "no saved connections".
$hasProfileFiles = [IO.Directory]::Exists($store) -and @([IO.Directory]::GetFiles($store, '*.json')).Count -gt 0
$noConnectionsMessage = if ($hasProfileFiles) {
	"There are no readable SQL connection profiles in '$store'."
} else {
	"There are no saved SQL connections in '$store'. Use add first."
}
$notFoundMessage = "The named SQL connection does not exist in '$store'. Use list to see saved connections."
if ($Command -ieq 'list') {
	if (-not [string]::IsNullOrWhiteSpace($Name) -and -not [IO.File]::Exists((Get-SqlConnectionProfilePath -Name $Name -StorePath $store))) {
		throw "The named SQL connection does not exist in '$store'. Run list without -Name to see saved connections."
	}
	$found = @(Get-SqlConnectionProfiles -Name $Name -StorePath $store)
	if (-not $found.Count) { Write-Host $noConnectionsMessage }
	$found
	return
}

$namePrompted = $false
if ([string]::IsNullOrWhiteSpace($Name)) {
	if (-not $helpShown) { Show-SqlConnectionHelp; $helpShown = $true }
	if ($Command -in @('modify', 'delete')) {
		$available = @(Get-SqlConnectionProfiles -StorePath $store)
		if (-not $available.Count) { throw $noConnectionsMessage }
		$available | Format-Table -AutoSize | Out-Host
	}
	Assert-SqlCliPrompt 'Specify -Name.' -NonInteractive:$NonInteractive
	$Name = Read-SqlCliText 'Connection name (Enter cancels)' -Missing 'Specify -Name.'
	if (-not $Name) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
	$namePrompted = $true
}
$Name = $Name.Trim()
$path = Get-SqlConnectionProfilePath -Name $Name -StorePath $store

if ($Command -ieq 'delete') {
	if (-not [IO.File]::Exists($path)) { throw $notFoundMessage }
	# Show the saved name, not the typed casing; a damaged profile stays deletable under the typed name.
	$savedName = try { (Read-SqlConnectionProfile -Path $path).Name } catch { $Name }
	# Refuse before the confirmation; the library checks again under the store lock.
	$aliases = @(Assert-SqlConnectionDeletable -Name $Name -StorePath $store -WithDatabases:$WithDatabases -KeepDatabases:$KeepDatabases)
	$aliasNames = @($aliases.Alias) -join ', '
	$aliasText = if (-not $aliases.Count) { '' } elseif ($WithDatabases) { " and its database aliases $aliasNames" } else { " and keep its database aliases $aliasNames" }
	# A name picked at the prompt gets a confirmation, as in the other delete commands; -Name stays unattended.
	if ($namePrompted -and -not (Confirm-Action "Delete SQL connection '$savedName'$($aliasText)?" -Color Yellow)) {
		Write-Host 'Aborted.' -ForegroundColor DarkGray
		return
	}
	$deleted = @(Remove-SqlConnectionProfile -Name $Name -StorePath $store -WithDatabases:$WithDatabases -KeepDatabases:$KeepDatabases)
	$deletedText = if ($deleted.Count) { " and database aliases $(@($deleted.Alias) -join ', ')" } else { '' }
	Write-Host "Deleted SQL connection '$savedName'$deletedText." -ForegroundColor Green
	if ($KeepDatabases -and $aliases.Count) {
		Write-Host "Kept database aliases $aliasNames. They work again when you add a connection named '$savedName'." -ForegroundColor Yellow
	}
	return
}

$expectedContent = $null
$connectionProfile = $null
if ($Command -ieq 'add') {
	Assert-SqlConnectionNameFree -Name $Name -StorePath $store -Kind Connection
} else {
	if (-not [IO.File]::Exists($path)) { throw $notFoundMessage }
	$expectedContent = [IO.File]::ReadAllText($path)
	$connectionProfile = Read-SqlConnectionProfile -Path $path
}

$promptedSecret = $null
try {
	if ($Command -ieq 'modify' -and -not $hasDescription -and -not $hasConnectionString) {
		if (-not $helpShown) { Show-SqlConnectionHelp; $helpShown = $true }
		$missing = 'Specify -Description, -ClearDescription, or -ConnectionString for modify.'
		Assert-SqlCliPrompt $missing -NonInteractive:$NonInteractive
		Write-Host "Current description: $($connectionProfile.Description)"
		$enteredDescription = Read-SqlCliText 'New description (Enter keeps it; use -ClearDescription to clear it)' -Missing $missing
		Assert-SqlConnectionPublicText -Value $enteredDescription -Subject 'The entered description'
		if ($enteredDescription) { $Description = $enteredDescription; $hasDescription = $true }
		$promptedSecret = Read-SqlConnectionSecret 'New connection string (hidden; Enter keeps it)' -Missing $missing
		if ($null -ne $promptedSecret -and $promptedSecret.Length -gt 0) { $ConnectionString = $promptedSecret; $hasConnectionString = $true }
		if (-not $hasDescription -and -not $hasConnectionString) {
			Write-Host 'No changes.'
			return
		}
	}
	if ($Command -ieq 'add' -and -not $hasConnectionString) {
		if (-not $helpShown) { Show-SqlConnectionHelp; $helpShown = $true }
		Assert-SqlCliPrompt 'Specify -ConnectionString for add.' -NonInteractive:$NonInteractive
		$promptedSecret = Read-SqlConnectionSecret 'Connection string (hidden; Enter cancels)' -Missing 'Specify -ConnectionString for add.'
		if ($null -eq $promptedSecret -or $promptedSecret.Length -eq 0) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
		$ConnectionString = $promptedSecret
		$hasConnectionString = $true
	}
	if ($Command -ieq 'add') {
		$connectionProfile = [pscustomobject]@{
			Version = 1
			Name = $Name
			Description = $Description
			EncryptedConnectionString = ''
		}
	} elseif ($hasDescription) {
		$connectionProfile.Description = $Description
	}
	if ($hasConnectionString) {
		$connectionProfile.EncryptedConnectionString = Protect-SqlConnectionString -ConnectionString $ConnectionString
	}
	Write-SqlConnectionProfile -ConnectionProfile $connectionProfile -StorePath $store -ExpectedContent $expectedContent -Add:($Command -ieq 'add')
	Write-Host "Saved SQL connection '$($connectionProfile.Name)'." -ForegroundColor Green
	# Aliases name their connection, so a new or replaced connection string moves them to its server.
	if ($hasConnectionString) {
		$aliasNames = @(Get-SqlDatabaseAliases -Connection $connectionProfile.Name -StorePath $store | ForEach-Object Alias)
		if ($aliasNames.Count) {
			Write-Host "Database aliases $($aliasNames -join ', ') use this connection; they now open databases through this connection string." -ForegroundColor Yellow
		}
	}
} finally {
	if ($null -ne $promptedSecret) { $promptedSecret.Dispose() }
	$ConnectionString = $null
}
