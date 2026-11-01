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
  -Description       Optional purpose. On modify, an empty string clears it.
  -ClearDescription  Modify only: clear the purpose without an empty argument.
  -ConnectionString  SQL Server string or SecureString; add/modify only.
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

# Fail instead of prompting when the caller asked for it or when no console can answer.
function Assert-SqlConnectionPrompt {
	param([string]$Message)
	if ($NonInteractive) { throw $Message }
	# Hidden prompts read console keys and wait forever when input is redirected,
	# so redirected input counts as non-interactive for every prompt.
	if ([Console]::IsInputRedirected) { throw "$Message Prompts require an interactive console." }
}

# A -NonInteractive host can have a console but rejects Read-Host; name the missing value instead.
function Read-SqlConnectionSecret {
	param([string]$Prompt, [string]$Missing)
	try {
		return Read-Host $Prompt -AsSecureString
	} catch [System.Management.Automation.PSInvalidOperationException] {
		throw "$Missing Prompts require an interactive console."
	}
}

# Read-Host can return $null when input ends; treat that like an empty answer.
function Read-SqlConnectionText {
	param([string]$Prompt, [string]$Missing)
	try {
		return ([string](Read-Host $Prompt)).Trim()
	} catch [System.Management.Automation.PSInvalidOperationException] {
		throw "$Missing Prompts require an interactive console."
	}
}

# Repeat a command typed at the prompt only when it looks like a word; it is already visible there.
function Format-SqlConnectionUnknownCommand {
	param([string]$Value)
	if ($Value -match '^[A-Za-z?/-]{1,20}$') { return "Unknown command '$Value'." }
	return 'Unknown command.'
}

# True when this script is the pwsh -File target, as through the .cmd shim. Only then does the Windows
# command-line parser split the arguments, and a missing closing quote or a quoted value that ends with
# a backslash can join several arguments into one value. In-process PowerShell calls bind values as given.
function Test-SqlConnectionFileTarget {
	foreach ($argument in [Environment]::GetCommandLineArgs()) {
		if ($argument -notlike '*.ps1') { continue }
		$fullPath = try { [IO.Path]::GetFullPath($argument) } catch { $null }
		if ($fullPath -eq $PSCommandPath) { return $true }
	}
	return $false
}

$Command = ([string]$Command).Trim()
$helpTokens = @('help', '/?', '--help')
# A stray help word means help only when nothing else was given: in "-Description Get help", it is an unquoted value.
$valueBound = @('Name', 'Description', 'ConnectionString', 'ClearDescription' | Where-Object { $PSBoundParameters.ContainsKey($_) }).Count -gt 0
$onlyHelpStray = $null -ne $UnexpectedArguments -and $UnexpectedArguments.Count -gt 0 -and
	@($UnexpectedArguments | Where-Object { $_ -notin $helpTokens }).Count -eq 0
if ($Help -or $Command -in $helpTokens -or ($onlyHelpStray -and -not $valueBound)) {
	Show-SqlConnectionHelp
	return
}
# Check joined arguments before stray arguments, and do not echo the value: it can contain a connection string.
if (Test-SqlConnectionFileTarget) {
	foreach ($parameterName in @('Command', 'Name', 'Description', 'ConnectionString', 'StorePath')) {
		$boundValue = $PSBoundParameters[$parameterName]
		if ($boundValue -isnot [string]) { continue }
		# A parameter token inside a value shows that the parser joined it with the next arguments.
		if ($boundValue -match '(?:^|\s)-{1,2}[A-Za-z]') {
			Show-SqlConnectionHelp
			throw "Through the .cmd shim or pwsh -File, the -$parameterName value cannot contain a word that starts with -: other arguments were probably joined into it. In cmd, close every quote and do not end a quoted value with a backslash; in PowerShell, run the .ps1 by name instead."
		}
		# A backslash before a closing quote leaves the quote in the value. From cmd, a name, command, or path
		# cannot contain a quote, and a description cannot end with one, because cmd cannot tell these apart.
		$strayQuote = ($parameterName -in @('Command', 'Name', 'StorePath') -and $boundValue.Contains('"')) -or
			($parameterName -eq 'Description' -and $boundValue -match '"\s*$')
		if ($strayQuote) {
			Show-SqlConnectionHelp
			$rule = if ($parameterName -eq 'Description') { 'cannot end with a quote' } else { 'cannot contain a quote' }
			throw "Through the .cmd shim or pwsh -File, the -$parameterName value $rule. In cmd, a quoted value that ends with a backslash leaves such a quote; remove the backslash or the quote."
		}
	}
}
# Test the count: a one-item array is falsy when its item is '' or 0, and @($null) has one item.
if ($null -ne $UnexpectedArguments -and $UnexpectedArguments.Count -gt 0) {
	Show-SqlConnectionHelp
	# Name only switch-like tokens; any other stray value can be a connection string.
	$switchTokens = @($UnexpectedArguments | Where-Object { $_ -is [string] -and $_ -match '^-[A-Za-z]+:?$' })
	# A known name arrives as a value from array splatting or a quoted name, not from a typo.
	$knownNames = @($MyInvocation.MyCommand.Parameters.Values | ForEach-Object { $_.Name; $_.Aliases })
	$valueNames = @($switchTokens | Where-Object {
		$text = $_.Trim('-', ':')
		@($knownNames | Where-Object { $_.StartsWith($text, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
	})
	$unknownNames = @($switchTokens | Where-Object { $_ -notin $valueNames })
	$hint = ''
	if ($valueNames) { $hint += " Parameter names that arrived as values: $($valueNames -join ', '). In PowerShell, splat a hashtable, not an array, and do not quote parameter names." }
	if ($unknownNames) { $hint += " Unknown parameters: $($unknownNames -join ', ')." }
	throw "Unexpected arguments: $($UnexpectedArguments.Count).$hint Pass each value with its parameter name, for example -Name or -ConnectionString."
}
if ($PSBoundParameters.ContainsKey('ConnectionString') -and $ConnectionString -isnot [Security.SecureString] -and [string]::IsNullOrWhiteSpace([string]$ConnectionString)) {
	Show-SqlConnectionHelp
	throw 'The -ConnectionString value is empty.'
}
if ($PSBoundParameters.ContainsKey('StorePath')) {
	# The library maps an empty path to the default store; an explicit empty override must not change the real store.
	if ([string]::IsNullOrWhiteSpace($StorePath)) {
		Show-SqlConnectionHelp
		throw 'The -StorePath value is empty. Omit -StorePath to use the default store.'
	}
	# .NET's GetInvalidPathChars() omits the quote, so test the Windows path characters directly.
	if ($StorePath -match '["<>|*\x00-\x1f]') {
		Show-SqlConnectionHelp
		throw 'The -StorePath value contains characters that are not valid in a path. In cmd, do not end a quoted path with a backslash.'
	}
}

$validCommands = @('add', 'modify', 'delete', 'list')
$helpShown = $false
if (-not $Command -or $Command -notin $validCommands) {
	Show-SqlConnectionHelp
	$helpShown = $true
	# Do not repeat a command given as an argument: a stray positional value can be a connection string.
	$unknown = if ($Command) { 'Unknown command.' } else { '' }
	$missing = 'Specify -Command add, modify, delete, or list.'
	Assert-SqlConnectionPrompt ("$unknown $missing").Trim()
	if ($unknown) { Write-Host $unknown -ForegroundColor Yellow }
	do {
		$Command = Read-SqlConnectionText 'Command (add, modify, delete, list, help; Enter cancels)' -Missing $missing
		if (-not $Command) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
		if ($Command -in $helpTokens) {
			Show-SqlConnectionHelp
		} elseif ($Command -notin $validCommands) {
			Write-Host (Format-SqlConnectionUnknownCommand $Command) -ForegroundColor Yellow
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
	Assert-SqlConnectionPrompt 'Specify -Name.'
	$Name = Read-SqlConnectionText 'Connection name (Enter cancels)' -Missing 'Specify -Name.'
	if (-not $Name) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
	$namePrompted = $true
}
$Name = $Name.Trim()
$path = Get-SqlConnectionProfilePath -Name $Name -StorePath $store

if ($Command -ieq 'delete') {
	if (-not [IO.File]::Exists($path)) { throw $notFoundMessage }
	# Show the saved name, not the typed casing; a damaged profile stays deletable under the typed name.
	$savedName = try { (Read-SqlConnectionProfile -Path $path).Name } catch { $Name }
	# A name picked at the prompt gets a confirmation, as in the other delete commands; -Name stays unattended.
	if ($namePrompted -and -not (Confirm-Action "Delete SQL connection '$savedName'?" -Color Yellow)) {
		Write-Host 'Aborted.' -ForegroundColor DarkGray
		return
	}
	Remove-SqlConnectionProfile -Name $Name -StorePath $store
	Write-Host "Deleted SQL connection '$savedName'." -ForegroundColor Green
	return
}

$expectedContent = $null
$connectionProfile = $null
if ($Command -ieq 'add') {
	if ([IO.File]::Exists($path)) { throw 'This connection name already exists. Use modify to change it.' }
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
		Assert-SqlConnectionPrompt $missing
		Write-Host "Current description: $($connectionProfile.Description)"
		$enteredDescription = Read-SqlConnectionText 'New description (Enter keeps it; use -ClearDescription to clear it)' -Missing $missing
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
		Assert-SqlConnectionPrompt 'Specify -ConnectionString for add.'
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
} finally {
	if ($null -ne $promptedSecret) { $promptedSecret.Dispose() }
	$ConnectionString = $null
}
