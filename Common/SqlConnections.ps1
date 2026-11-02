# SQL Server profiles and database aliases. Load through common.ps1.
# Only the connection string is encrypted; names, aliases, and descriptions are searchable.
# A database alias names one database on a saved connection. Connection names and aliases share one
# name space, so New-SavedSqlConnection -Name selects one of them without doubt.

function Get-SqlConnectionStorePath {
	param([string]$StorePath)
	if (-not $IsWindows) { throw 'SQL connection profiles require Windows DPAPI and PowerShell 7.' }
	if ([string]::IsNullOrWhiteSpace($StorePath)) {
		$StorePath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SqlConnections'
	}
	$directory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StorePath)
	# The store is a directory of profile files; report a file path before any prompt or write.
	if ([IO.File]::Exists($directory)) { throw "The SQL connection store '$directory' is a file. Give a directory." }
	return $directory
}

# $Subject names the value in the message, for example "a connection name".
function Get-SqlConnectionNameHash {
	param([string]$Name, [string]$Subject)
	# Validate the same trimmed text that the key uses.
	$Name = $Name.Trim()
	if ($Name.Length -eq 0 -or $Name.Length -gt 128 -or $Name -match '[\x00-\x1f\x7f]') {
		throw "Use $Subject of 1 to 128 characters without control characters."
	}
	# Hash the label so names cannot become paths, wildcards, or Windows device names.
	$key = $Name.Normalize().ToUpperInvariant()
	return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key)))
}

function Get-SqlConnectionProfilePath {
	param([string]$Name, [string]$StorePath)
	$hash = Get-SqlConnectionNameHash -Name $Name -Subject 'a connection name'
	return Join-Path (Get-SqlConnectionStorePath -StorePath $StorePath) "$hash.json"
}

# A subdirectory, because list reads every *.json file in the store root as a connection profile.
function Get-SqlDatabaseCatalogPath {
	param([string]$StorePath)
	$directory = Join-Path (Get-SqlConnectionStorePath -StorePath $StorePath) 'Databases'
	if ([IO.File]::Exists($directory)) { throw "The database alias catalog '$directory' is a file. Give a directory." }
	return $directory
}

function Get-SqlDatabaseAliasPath {
	param([string]$Alias, [string]$StorePath)
	$hash = Get-SqlConnectionNameHash -Name $Alias -Subject 'a database alias'
	return Join-Path (Get-SqlDatabaseCatalogPath -StorePath $StorePath) "$hash.json"
}

function Assert-SqlDatabaseName {
	param([string]$Database)
	if ($Database.Length -eq 0 -or $Database.Length -gt 128 -or $Database -match '[\x00-\x1f\x7f]') {
		throw 'Use a database name of 1 to 128 characters without control characters.'
	}
}

# Returns the canonical spelling of an access value. Keep the values local: $script: names the scope
# of the calling script, which need not be the scope that loaded this library.
function ConvertTo-SqlDatabaseAccess {
	param([string]$Access)
	foreach ($value in @('ReadOnly', 'ReadWrite')) {
		if ($value -ieq $Access.Trim()) { return $value }
	}
	throw 'Use -Access ReadOnly or ReadWrite.'
}

# Reads the string properties of a version 1 store file. Any other content throws.
function Read-SqlConnectionStoreDocument {
	param([string]$Path, [string[]]$PropertyNames)
	$document = $null
	try {
		# System.Text.Json keeps each value as written; ConvertFrom-Json turns ISO date-time text into DateTime.
		$document = [System.Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($Path))
		$root = $document.RootElement
		if ($root.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw 'Invalid file.' }
		$version = $root.GetProperty('Version')
		if ($version.ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or $version.GetInt32() -ne 1) { throw 'Invalid file.' }
		$text = @{}
		foreach ($propertyName in $PropertyNames) {
			$element = $root.GetProperty($propertyName)
			if ($element.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { throw 'Invalid file.' }
			$text[$propertyName] = $element.GetString()
		}
		return $text
	} finally {
		if ($null -ne $document) { $document.Dispose() }
	}
}

function Read-SqlConnectionProfile {
	param([string]$Path)
	try {
		$text = Read-SqlConnectionStoreDocument -Path $Path -PropertyNames @('Name', 'Description', 'EncryptedConnectionString')
		if ([string]::IsNullOrWhiteSpace($text.EncryptedConnectionString)) { throw 'Invalid profile.' }
		$connectionProfile = [pscustomobject]@{
			Version = 1
			Name = $text.Name
			Description = $text.Description
			EncryptedConnectionString = $text.EncryptedConnectionString
		}
		$hash = Get-SqlConnectionNameHash -Name $connectionProfile.Name -Subject 'a connection name'
		if ([IO.Path]::GetFileName($Path) -ine "$hash.json") { throw 'Invalid profile name.' }
		return $connectionProfile
	} catch {
		throw "Cannot read SQL connection profile '$([IO.Path]::GetFileName($Path))': its format is not valid, or the file is not accessible. If you know its name, delete it with sql-connection delete -Name -KeepDatabases and add it again with the same name; its database aliases then work again."
	}
}

function Read-SqlDatabaseAlias {
	param([string]$Path)
	try {
		$text = Read-SqlConnectionStoreDocument -Path $Path -PropertyNames @('Alias', 'Connection', 'Database', 'Access', 'Description')
		$entry = [pscustomobject]@{
			Version = 1
			Alias = $text.Alias
			Connection = $text.Connection
			Database = $text.Database
			Access = ConvertTo-SqlDatabaseAccess -Access $text.Access
			Description = $text.Description
		}
		$null = Get-SqlConnectionNameHash -Name $entry.Connection -Subject 'a connection name'
		Assert-SqlDatabaseName -Database $entry.Database
		$hash = Get-SqlConnectionNameHash -Name $entry.Alias -Subject 'a database alias'
		if ([IO.Path]::GetFileName($Path) -ine "$hash.json") { throw 'Invalid alias name.' }
		return $entry
	} catch {
		throw "Cannot read database alias file '$([IO.Path]::GetFileName($Path))': its format is not valid, or the file is not accessible. If you know the alias, remove it with sql-database delete -Alias and add it again."
	}
}

# Reads every *.json file in a directory. One damaged or foreign file must not hide the others.
function Read-SqlConnectionStoreDirectory {
	param([string]$Directory, [scriptblock]$Reader, [string]$Kind, [string]$Remedy)
	if (-not [IO.Directory]::Exists($Directory)) { return }
	foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File) {
		try {
			& $Reader $file.FullName
		} catch {
			Write-Warning "Skipped '$($file.Name)' in '$Directory': it is not a readable $Kind. $Remedy"
		}
	}
}

function Get-SqlConnectionProfiles {
	param([string]$Name, [string]$StorePath)
	$directory = Get-SqlConnectionStorePath -StorePath $StorePath
	if (-not [string]::IsNullOrWhiteSpace($Name)) {
		$path = Get-SqlConnectionProfilePath -Name $Name -StorePath $directory
		if (-not [IO.File]::Exists($path)) { throw 'The named SQL connection does not exist. Use list to see saved connections.' }
		$profiles = @(Read-SqlConnectionProfile -Path $path)
	} else {
		$profiles = @(Read-SqlConnectionStoreDirectory -Directory $directory -Reader { param($p) Read-SqlConnectionProfile -Path $p } `
			-Kind 'SQL connection profile' -Remedy 'If you know its name, delete it with sql-connection delete -Name -KeepDatabases and add it again with the same name.')
	}
	# Do not decrypt secrets or return ciphertext when listing profiles.
	$profiles | Sort-Object Name | Select-Object Name, Description
}

# -Connection keeps the aliases of one connection; the name is compared as a key, without regard to letter case.
function Get-SqlDatabaseAliases {
	param([string]$Alias, [string]$Connection, [string]$StorePath)
	$directory = Get-SqlConnectionStorePath -StorePath $StorePath
	if (-not [string]::IsNullOrWhiteSpace($Alias)) {
		$path = Get-SqlDatabaseAliasPath -Alias $Alias -StorePath $directory
		if (-not [IO.File]::Exists($path)) { throw 'The database alias does not exist. Use sql-database list to see saved aliases.' }
		$entries = @(Read-SqlDatabaseAlias -Path $path)
	} else {
		$entries = @(Read-SqlConnectionStoreDirectory -Directory (Get-SqlDatabaseCatalogPath -StorePath $directory) -Reader { param($p) Read-SqlDatabaseAlias -Path $p } `
			-Kind 'database alias' -Remedy 'If you know the alias, remove it with sql-database delete -Alias.')
	}
	if (-not [string]::IsNullOrWhiteSpace($Connection)) {
		$key = Get-SqlConnectionNameHash -Name $Connection -Subject 'a connection name'
		$entries = @($entries | Where-Object { (Get-SqlConnectionNameHash -Name $_.Connection -Subject 'a connection name') -eq $key })
	}
	$entries | Sort-Object Alias | Select-Object Alias, Connection, Database, Access, Description
}

# A description is public metadata. Refuse text that looks like a password, however it arrived (for example
# a cmd quoting mistake that joined the connection string into it), and do not echo it.
# $Subject names the value in the message, for example "The -Description value".
function Assert-SqlConnectionPublicText {
	param([string]$Value, [string]$Subject)
	if ($Value -match '(?i)\b(password|pwd)\s*=') {
		throw "$Subject looks like it contains a password. Names, aliases, and descriptions are public metadata; give the connection string only where a connection string is requested."
	}
}

# Parser messages can quote fragments of the connection string. A caught error stays in $Error,
# so remove it before reporting a generic message.
function Clear-SqlConnectionErrorRecord {
	param([System.Management.Automation.ErrorRecord]$Record)
	for ($i = $global:Error.Count - 1; $i -ge 0; $i--) {
		$entry = $global:Error[$i]
		$entryException = if ($entry -is [System.Management.Automation.ErrorRecord]) { $entry.Exception } else { $entry }
		if ([object]::ReferenceEquals($entryException, $Record.Exception)) { $global:Error.RemoveAt($i) }
	}
}

# One lock serializes every update of the store, so that the checks between aliases and connections
# see a store that does not change.
function Open-SqlConnectionStoreLock {
	param([string]$Directory)
	try {
		return [IO.File]::Open((Join-Path $Directory '.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
	} catch {
		throw 'Cannot lock the connection store. Another update may be running, or the directory may be inaccessible.'
	}
}

# Writers hold the store lock for the whole write, so a temporary file found under the lock is from an
# interrupted write. It can contain ciphertext; delete it. A file that cannot be deleted now does not stop the update.
function Clear-SqlConnectionInterruptedWrite {
	param([string]$Directory)
	foreach ($file in [IO.Directory]::GetFiles($Directory, '.write-*.tmp')) {
		try {
			[IO.File]::Delete($file)
		} catch {
			Write-Warning "Cannot delete '$([IO.Path]::GetFileName($file))' from an interrupted write in '$Directory'. Delete it when it is no longer in use."
		}
	}
}

# Call under the store lock. A same-directory rename publishes the complete file in one operation.
# $Kind names the file in the message, for example "profile".
function Publish-SqlConnectionStoreFile {
	param([string]$Path, [object]$Content, [switch]$Replace, [string]$Kind)
	$directory = Split-Path $Path -Parent
	$tempPath = $null
	try {
		Clear-SqlConnectionInterruptedWrite -Directory $directory
		$tempPath = Join-Path $directory ".write-$([guid]::NewGuid().ToString('N')).tmp"
		$json = $Content | ConvertTo-Json -Depth 3
		[IO.File]::WriteAllText($tempPath, $json, [Text.UTF8Encoding]::new($false))
		try {
			[IO.File]::Move($tempPath, $Path, [bool]$Replace)
		} catch [IO.IOException], [UnauthorizedAccessException] {
			throw "Cannot save the $Kind file. Another process may be reading it, or the store may be read-only. Try again."
		}
	} finally {
		# The next update removes a temporary file that cannot be deleted now.
		try {
			if ($null -ne $tempPath -and [IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
		} catch {
			Write-Warning "Cannot delete the temporary file '$([IO.Path]::GetFileName($tempPath))'. The next update removes it."
		}
	}
}

# Builds the connection string that New-SavedSqlConnection gives SqlConnection: without the SQL login, which
# goes into SqlCredential, and with Persist Security Info off.
function Get-SqlConnectionSettingsText {
	param([System.Data.SqlClient.SqlConnectionStringBuilder]$Builder)
	$settings = [System.Data.SqlClient.SqlConnectionStringBuilder]::new($Builder.ConnectionString)
	try {
		$null = $settings.Remove('User ID')
		$null = $settings.Remove('Password')
		$settings['Persist Security Info'] = $false
		return $settings.ConnectionString
	} finally {
		$settings.Clear()
	}
}

function Assert-SqlConnectionStringAccepted {
	param([System.Data.SqlClient.SqlConnectionStringBuilder]$Builder)
	$probe = [System.Data.SqlClient.SqlConnection]::new()
	try {
		$probe.ConnectionString = Get-SqlConnectionSettingsText -Builder $Builder
	} finally {
		$probe.Dispose()
	}
}

function Protect-SqlConnectionString {
	param([object]$ConnectionString)
	if (-not $IsWindows) { throw 'SQL connection profiles require Windows DPAPI and PowerShell 7.' }
	$secret = $null
	$builder = $null
	$plainText = $null
	$specificMessage = $null
	try {
		if ($ConnectionString -is [Security.SecureString]) {
			$secret = $ConnectionString.Copy()
		} elseif ($ConnectionString -is [string] -and -not [string]::IsNullOrWhiteSpace($ConnectionString)) {
			$secret = ConvertTo-SecureString -String $ConnectionString -AsPlainText -Force
		} else {
			throw 'Missing connection string.'
		}
		# NetworkCredential would keep its own SecureString copy that nothing disposes.
		$plainText = ConvertFrom-SecureString -SecureString $secret -AsPlainText
		# Name the failed stage, but never the keyword: a parser message can quote fragments of the secret.
		# Check the general syntax first, so that a quoting mistake is not reported as an unsupported keyword.
		$specificMessage = 'Cannot protect the connection string. Its syntax is invalid, for example an unclosed quote, or a value with ; or a quote that is not enclosed in double quotes. Enclose such a value in double quotes and double each quote inside it; in cmd, do not end a quoted value with a backslash.'
		$syntax = [System.Data.Common.DbConnectionStringBuilder]::new()
		try {
			# Call the setter method: in PowerShell, assigning the ConnectionString property only adds a dictionary key.
			$syntax.set_ConnectionString($plainText)
		} finally {
			$syntax.Clear()
		}
		$specificMessage = 'Cannot protect the connection string. System.Data.SqlClient does not accept one of its keywords or values; use classic forms such as TrustServerCertificate, ApplicationIntent, MultiSubnetFailover, and Encrypt=True or False, with Windows or SQL Server authentication.'
		$builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new($plainText)
		if ([string]::IsNullOrWhiteSpace($builder.DataSource)) {
			$specificMessage = 'Cannot protect the connection string. It has no Server or Data Source.'
			throw $specificMessage
		}
		# New-SavedSqlConnection moves SQL logins into SqlCredential, which accepts at most 128 characters each.
		if (-not $builder.IntegratedSecurity -and ($builder.UserID.Length -gt 128 -or $builder.Password.Length -gt 128)) {
			$specificMessage = 'Cannot protect the connection string. A SQL login user ID and password can each have at most 128 characters.'
			throw $specificMessage
		}
		# The builder accepts some combinations that SqlConnection rejects, such as Min Pool Size above Max Pool Size.
		# Set the string that New-SavedSqlConnection would set; the setter only parses and does not contact a server.
		$specificMessage = 'Cannot protect the connection string. SqlConnection rejects its settings; check values such as pool sizes, failover options, and file names.'
		Assert-SqlConnectionStringAccepted -Builder $builder
		$specificMessage = 'Cannot protect the connection string. Windows DPAPI cannot encrypt it; check that the Windows user profile is available.'
		return ConvertFrom-SecureString -SecureString $secret -ErrorAction Stop
	} catch {
		# Parser exceptions can include fragments of the supplied secret.
		Clear-SqlConnectionErrorRecord -Record $_
		throw ($specificMessage ?? 'Cannot protect the connection string. Give a SQL Server connection string.')
	} finally {
		if ($null -ne $builder) { $builder.Clear() }
		if ($null -ne $secret) { $secret.Dispose() }
		$plainText = $null
	}
}

# Connection names and database aliases share one name space. Writers call this under the store lock.
# The scripts also call it before their prompts, so that nobody types a secret for a name that cannot be saved.
function Assert-SqlConnectionNameFree {
	param([string]$Name, [string]$StorePath, [ValidateSet('Connection', 'Alias')][string]$Kind)
	# Each path function validates the name; call the one of $Kind first, so that a message names the right value.
	if ($Kind -eq 'Alias') {
		$aliasExists = [IO.File]::Exists((Get-SqlDatabaseAliasPath -Alias $Name -StorePath $StorePath))
		$connectionExists = [IO.File]::Exists((Get-SqlConnectionProfilePath -Name $Name -StorePath $StorePath))
	} else {
		$connectionExists = [IO.File]::Exists((Get-SqlConnectionProfilePath -Name $Name -StorePath $StorePath))
		$aliasExists = [IO.File]::Exists((Get-SqlDatabaseAliasPath -Alias $Name -StorePath $StorePath))
	}
	if ($Kind -eq 'Connection') {
		if ($connectionExists) { throw 'This connection name already exists. Give another name, or edit the existing connection.' }
		if ($aliasExists) { throw 'This name is already a database alias. Connection names and database aliases share one name space; give another name.' }
	} else {
		if ($aliasExists) { throw 'This database alias already exists. Give another alias, or edit the existing one.' }
		if ($connectionExists) { throw 'This name is already a SQL connection. Connection names and database aliases share one name space; give another alias.' }
		# Aliases kept with sql-connection delete -KeepDatabases wait for a connection with this name.
		$waiting = @(Get-SqlDatabaseAliases -Connection $Name -StorePath $StorePath)
		if ($waiting.Count) {
			throw "Database aliases $(@($waiting.Alias) -join ', ') use this name as their connection. Connection names and database aliases share one name space; give another alias."
		}
	}
}

# Names the missing connection before New-SavedSqlConnection, which would also look for an alias with that name.
function Assert-SqlConnectionSaved {
	param([string]$Name, [string]$StorePath)
	if (-not [IO.File]::Exists((Get-SqlConnectionProfilePath -Name $Name -StorePath $StorePath))) {
		throw "The SQL connection '$($Name.Trim())' does not exist. Add it with sql-connection add, or move its aliases with sql-database modify -Connection."
	}
}

function Write-SqlConnectionProfile {
	param(
		[object]$ConnectionProfile,
		[string]$StorePath,
		[string]$ExpectedContent,
		[switch]$Add
	)
	Assert-SqlConnectionPublicText -Value $ConnectionProfile.Description -Subject 'The description'
	$directory = Get-SqlConnectionStorePath -StorePath $StorePath
	$path = Get-SqlConnectionProfilePath -Name $ConnectionProfile.Name -StorePath $directory
	$null = [IO.Directory]::CreateDirectory($directory)
	$lock = Open-SqlConnectionStoreLock -Directory $directory
	try {
		if ($Add) {
			Assert-SqlConnectionNameFree -Name $ConnectionProfile.Name -StorePath $directory -Kind Connection
		} elseif (-not [IO.File]::Exists($path) -or [IO.File]::ReadAllText($path) -cne $ExpectedContent) {
			throw 'The connection changed or was deleted during editing. Start the edit again.'
		}
		Publish-SqlConnectionStoreFile -Path $path -Content $ConnectionProfile -Replace:(-not $Add) -Kind 'profile'
	} finally {
		$lock.Dispose()
	}
}

# Returns the aliases that use the connection. Aliases stop the delete unless the caller decides about them:
# -WithDatabases deletes them, and -KeepDatabases keeps them for a connection added again with the same name.
function Assert-SqlConnectionDeletable {
	param([string]$Name, [string]$StorePath, [switch]$WithDatabases, [switch]$KeepDatabases)
	if ($WithDatabases -and $KeepDatabases) { throw 'Use -WithDatabases or -KeepDatabases, not both.' }
	$aliases = @(Get-SqlDatabaseAliases -Connection $Name -StorePath $StorePath)
	if ($aliases.Count -and -not $WithDatabases -and -not $KeepDatabases) {
		throw "Database aliases use this connection: $(@($aliases.Alias) -join ', '). Add -KeepDatabases to keep them for a connection that you add again with the same name, or -WithDatabases to delete them too. You can also move them first with sql-database modify -Connection."
	}
	return $aliases
}

# Returns the deleted aliases.
function Remove-SqlConnectionProfile {
	param([string]$Name, [string]$StorePath, [switch]$WithDatabases, [switch]$KeepDatabases)
	$directory = Get-SqlConnectionStorePath -StorePath $StorePath
	$path = Get-SqlConnectionProfilePath -Name $Name -StorePath $directory
	# sql-connection delete reports a missing profile itself; this message also fits sql-browse.
	if (-not [IO.File]::Exists($path)) { throw "The SQL connection '$($Name.Trim())' does not exist any more." }
	$lock = Open-SqlConnectionStoreLock -Directory $directory
	try {
		if (-not [IO.File]::Exists($path)) { throw 'The connection was already deleted.' }
		$aliases = @(Assert-SqlConnectionDeletable -Name $Name -StorePath $directory -WithDatabases:$WithDatabases -KeepDatabases:$KeepDatabases)
		if (-not $WithDatabases) { $aliases = @() }
		Clear-SqlConnectionInterruptedWrite -Directory $directory
		try {
			[IO.File]::Delete($path)
		} catch [IO.IOException], [UnauthorizedAccessException] {
			throw 'Cannot delete the profile file. Another process may be reading it, or the store may be read-only. Try again.'
		}
		# Delete the aliases after the connection: an alias left by a failure here only names a missing connection.
		foreach ($entry in $aliases) {
			try {
				[IO.File]::Delete((Get-SqlDatabaseAliasPath -Alias $entry.Alias -StorePath $directory))
				$entry
			} catch [IO.IOException], [UnauthorizedAccessException] {
				Write-Warning "Cannot delete the database alias '$($entry.Alias)'. Delete it with sql-database delete -Alias."
			}
		}
	} finally {
		$lock.Dispose()
	}
}

function Write-SqlDatabaseAlias {
	param(
		[object]$Entry,
		[string]$StorePath,
		[string]$ExpectedContent,
		[switch]$Add
	)
	foreach ($propertyName in @('Alias', 'Connection', 'Database', 'Description')) {
		Assert-SqlConnectionPublicText -Value $Entry.$propertyName -Subject "The $($propertyName.ToLowerInvariant())"
	}
	Assert-SqlDatabaseName -Database $Entry.Database
	$Entry.Access = ConvertTo-SqlDatabaseAccess -Access $Entry.Access
	$directory = Get-SqlConnectionStorePath -StorePath $StorePath
	$path = Get-SqlDatabaseAliasPath -Alias $Entry.Alias -StorePath $directory
	$connectionPath = Get-SqlConnectionProfilePath -Name $Entry.Connection -StorePath $directory
	$null = [IO.Directory]::CreateDirectory((Split-Path $path -Parent))
	$lock = Open-SqlConnectionStoreLock -Directory $directory
	try {
		if ($Add) {
			Assert-SqlConnectionNameFree -Name $Entry.Alias -StorePath $directory -Kind Alias
		} elseif (-not [IO.File]::Exists($path) -or [IO.File]::ReadAllText($path) -cne $ExpectedContent) {
			throw 'The database alias changed or was deleted during editing. Start the edit again.'
		}
		# A new alias or a changed connection must name a saved connection. Check under the lock: a delete of
		# the connection can run after the caller's check. An alias kept with sql-connection delete -KeepDatabases
		# stays editable without its connection, so that the user can change its access before adding it again.
		$connectionChanged = $Add -or (Get-SqlConnectionNameHash -Name (Read-SqlDatabaseAlias -Path $path).Connection -Subject 'a connection name') -ne
			(Get-SqlConnectionNameHash -Name $Entry.Connection -Subject 'a connection name')
		if ($connectionChanged -and -not [IO.File]::Exists($connectionPath)) {
			# The scripts check the connection before their prompts; this message also fits sql-browse.
			throw "The SQL connection '$($Entry.Connection)' does not exist any more."
		}
		Publish-SqlConnectionStoreFile -Path $path -Content $Entry -Replace:(-not $Add) -Kind 'database alias'
	} finally {
		$lock.Dispose()
	}
}

function Remove-SqlDatabaseAlias {
	param([string]$Alias, [string]$StorePath)
	$directory = Get-SqlConnectionStorePath -StorePath $StorePath
	$path = Get-SqlDatabaseAliasPath -Alias $Alias -StorePath $directory
	# sql-database delete reports a missing alias itself; this message also fits sql-browse.
	if (-not [IO.File]::Exists($path)) { throw "The database alias '$($Alias.Trim())' does not exist any more." }
	$lock = Open-SqlConnectionStoreLock -Directory $directory
	try {
		if (-not [IO.File]::Exists($path)) { throw 'The database alias was already deleted.' }
		Clear-SqlConnectionInterruptedWrite -Directory (Split-Path $path -Parent)
		try {
			[IO.File]::Delete($path)
		} catch [IO.IOException], [UnauthorizedAccessException] {
			throw 'Cannot delete the database alias file. Another process may be reading it, or the store may be read-only. Try again.'
		}
	} finally {
		$lock.Dispose()
	}
}

function New-SavedSqlConnection {
	# CmdletBinding makes a misspelled parameter, such as -Path, an error instead of a silent default store.
	# Only -Name is positional: a second value could mean the store or the database.
	[CmdletBinding(PositionalBinding = $false)]
	[OutputType([System.Data.SqlClient.SqlConnection])]
	param([Parameter(Position = 0)][string]$Name, [string]$StorePath, [string]$Database)
	# With -ErrorAction SilentlyContinue or a session preference of SilentlyContinue, throw does not stop a function.
	# Each check below must stop it, so that a failed check never continues to a profile in another store.
	$ErrorActionPreference = 'Stop'
	# An agent shell can lose a variable between calls; an empty explicit store must not load the real profile.
	if ($PSBoundParameters.ContainsKey('StorePath') -and [string]::IsNullOrWhiteSpace($StorePath)) {
		throw 'The -StorePath value is empty. Omit -StorePath to use the default store.'
	}
	# For the same reason, an empty explicit database must not connect to the default database.
	if ($PSBoundParameters.ContainsKey('Database')) {
		$Database = $Database.Trim()
		Assert-SqlDatabaseName -Database $Database
	}
	$null = Get-SqlConnectionNameHash -Name $Name -Subject 'a connection name or database alias'
	$path = Get-SqlConnectionProfilePath -Name $Name -StorePath $StorePath
	if (-not [IO.File]::Exists($path)) {
		$aliasPath = Get-SqlDatabaseAliasPath -Alias $Name -StorePath $StorePath
		if (-not [IO.File]::Exists($aliasPath)) {
			throw 'The named SQL connection or database alias does not exist. Use sql-connection list and sql-database list to see saved names.'
		}
		if ($PSBoundParameters.ContainsKey('Database')) {
			throw 'A database alias already names its database. Omit -Database, or give a connection name.'
		}
		$entry = Read-SqlDatabaseAlias -Path $aliasPath
		$Database = $entry.Database
		$path = Get-SqlConnectionProfilePath -Name $entry.Connection -StorePath $StorePath
		if (-not [IO.File]::Exists($path)) {
			throw "The database alias '$($entry.Alias)' uses the SQL connection '$($entry.Connection)', which does not exist. Add that connection with sql-connection add, or change the alias with sql-database modify -Connection."
		}
	}
	$connectionProfile = Read-SqlConnectionProfile -Path $path
	$secret = $null
	$builder = $null
	$connection = $null
	$password = $null
	$plainText = $null
	$decrypted = $false
	try {
		$secret = ConvertTo-SecureString -String $connectionProfile.EncryptedConnectionString -ErrorAction Stop
		# NetworkCredential would keep its own SecureString copy that nothing disposes.
		$plainText = ConvertFrom-SecureString -SecureString $secret -AsPlainText
		$decrypted = $true
		$builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new($plainText)
		# Use the indexer: PowerShell can treat a property assignment on a builder as a new dictionary key.
		if ($Database) { $builder['Initial Catalog'] = $Database }
		$connection = [System.Data.SqlClient.SqlConnection]::new()
		if (-not $builder.IntegratedSecurity -and ($builder.ShouldSerialize('User ID') -or $builder.ShouldSerialize('Password'))) {
			# Build the SecureString directly: ConvertTo-SecureString rejects an empty password, which a SQL login can have.
			$password = [Security.SecureString]::new()
			foreach ($character in $builder.Password.ToCharArray()) { $password.AppendChar($character) }
			$password.MakeReadOnly()
			$connection.Credential = [System.Data.SqlClient.SqlCredential]::new($builder.UserID, $password)
		}
		$connection.ConnectionString = Get-SqlConnectionSettingsText -Builder $builder
		# Return a closed connection. Only the caller decides when to contact the server.
		return $connection
	} catch {
		if ($null -ne $connection) { $connection.Dispose() }
		if ($null -ne $password) { $password.Dispose() }
		Clear-SqlConnectionErrorRecord -Record $_
		if ($decrypted) {
			throw 'Cannot load this SQL connection. Its stored connection string has settings that SqlConnection rejects; replace it with modify.'
		}
		throw 'Cannot load this SQL connection. Use the Windows account and computer that saved it; check DPAPI access.'
	} finally {
		if ($null -ne $builder) { $builder.Clear() }
		if ($null -ne $secret) { $secret.Dispose() }
		$plainText = $null
	}
}

# Returns a saved connection for display: its connection string with a fixed mask for the password, and its server,
# database, and authentication. -Database shows the string that an alias of that database opens.
function Get-SqlConnectionDisplayInfo {
	param([string]$Name, [string]$StorePath, [string]$Database)
	$path = Get-SqlConnectionProfilePath -Name $Name -StorePath $StorePath
	if (-not [IO.File]::Exists($path)) { throw 'The named SQL connection does not exist.' }
	$connectionProfile = Read-SqlConnectionProfile -Path $path
	$secret = $null
	$builder = $null
	$plainText = $null
	$decrypted = $false
	try {
		$secret = ConvertTo-SecureString -String $connectionProfile.EncryptedConnectionString -ErrorAction Stop
		$plainText = ConvertFrom-SecureString -SecureString $secret -AsPlainText
		$decrypted = $true
		$builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new($plainText)
		# Use the indexer: PowerShell can treat a property assignment on a builder as a new dictionary key.
		if ($Database) { $builder['Initial Catalog'] = $Database }
		$authentication = if ($builder.IntegratedSecurity) { 'Windows' } else { "SQL Server login $($builder.UserID)".Trim() }
		# The mask does not show the length of the password.
		if ($builder.ShouldSerialize('Password')) { $builder['Password'] = '********' }
		return [pscustomobject]@{
			ConnectionString = $builder.ConnectionString
			Server = $builder.DataSource
			Database = $builder.InitialCatalog
			Authentication = $authentication
		}
	} catch {
		Clear-SqlConnectionErrorRecord -Record $_
		if ($decrypted) {
			throw 'Cannot read this SQL connection. Its stored connection string has settings that SqlConnectionStringBuilder rejects; replace the connection string.'
		}
		throw 'Cannot decrypt this SQL connection. Use the Windows account and computer that saved it; check DPAPI access.'
	} finally {
		if ($null -ne $builder) { $builder.Clear() }
		if ($null -ne $secret) { $secret.Dispose() }
		$plainText = $null
	}
}

# Disposes a connection from New-SavedSqlConnection in the order that sql-access.md describes.
# Read $Credential before Open(): Open() hides it, and Dispose() clears it.
function Close-SavedSqlConnection {
	param([System.Data.SqlClient.SqlConnection]$Connection, [System.Data.SqlClient.SqlCredential]$Credential)
	# Each SqlCredential object has its own connection pool. Clear it so that no idle server connection stays.
	if ($null -ne $Credential) { [System.Data.SqlClient.SqlConnection]::ClearPool($Connection) }
	$Connection.Dispose()
	if ($null -ne $Credential) { $Credential.Password.Dispose() }
}

# A MethodInvocationException wraps the SqlException of Open() and Execute*(); report the server's message.
function Get-SqlServerErrorText {
	param([System.Management.Automation.ErrorRecord]$Record)
	$exception = $Record.Exception
	if ($exception -is [System.Management.Automation.MethodInvocationException] -and $null -ne $exception.InnerException) {
		$exception = $exception.InnerException
	}
	return $exception.Message
}

# Opens the database through the saved connection and closes it again. This contacts SQL Server.
function Test-SqlDatabaseAccess {
	param([string]$Connection, [string]$Database, [string]$StorePath)
	Assert-SqlConnectionSaved -Name $Connection -StorePath $StorePath
	$parameters = @{ Name = $Connection; Database = $Database }
	if (-not [string]::IsNullOrWhiteSpace($StorePath)) { $parameters.StorePath = $StorePath }
	$sql = New-SavedSqlConnection @parameters
	$credential = $sql.Credential
	try {
		$sql.Open()
	} catch {
		throw "Cannot open the database '$Database' through the SQL connection '$Connection': $(Get-SqlServerErrorText -Record $_)"
	} finally {
		Close-SavedSqlConnection -Connection $sql -Credential $credential
	}
}

# Lists the databases on the server of a saved connection, with a read-only query. This contacts SQL Server.
# It opens master: sys.databases shows the whole server there, and the database of the connection string
# can be missing or inaccessible, which is when a list of databases helps most.
function Get-SqlServerDatabases {
	param([string]$Connection, [string]$StorePath)
	Assert-SqlConnectionSaved -Name $Connection -StorePath $StorePath
	$parameters = @{ Name = $Connection; Database = 'master' }
	if (-not [string]::IsNullOrWhiteSpace($StorePath)) { $parameters.StorePath = $StorePath }
	$sql = New-SavedSqlConnection @parameters
	$credential = $sql.Credential
	$command = $null
	$reader = $null
	try {
		try {
			$sql.Open()
		} catch {
			throw "Cannot connect through the SQL connection '$Connection': $(Get-SqlServerErrorText -Record $_)"
		}
		$command = $sql.CreateCommand()
		$command.CommandTimeout = 30
		$command.CommandText = 'SELECT name, state_desc, CAST(HAS_DBACCESS(name) AS bit) FROM sys.databases ORDER BY name;'
		try {
			$reader = $command.ExecuteReader()
			$databases = [System.Collections.Generic.List[object]]::new()
			while ($reader.Read()) {
				$databases.Add([pscustomobject]@{
					Database = $reader.GetString(0)
					State = $reader.GetString(1)
					HasAccess = (-not $reader.IsDBNull(2) -and $reader.GetBoolean(2))
				})
			}
		} catch {
			throw "Cannot list the databases through the SQL connection '$Connection': $(Get-SqlServerErrorText -Record $_)"
		}
		return $databases.ToArray()
	} finally {
		if ($null -ne $reader) { $reader.Dispose() }
		if ($null -ne $command) { $command.Dispose() }
		Close-SavedSqlConnection -Connection $sql -Credential $credential
	}
}

# Opens a saved connection or database alias and reads where the session arrived, with read-only queries.
# This contacts SQL Server.
function Get-SqlServerSessionInfo {
	param([string]$Name, [string]$StorePath)
	$parameters = @{ Name = $Name }
	if (-not [string]::IsNullOrWhiteSpace($StorePath)) { $parameters.StorePath = $StorePath }
	$sql = New-SavedSqlConnection @parameters
	$credential = $sql.Credential
	$command = $null
	$reader = $null
	try {
		# An idle pooled connection would hide a server that cannot be reached now, and the open time.
		[System.Data.SqlClient.SqlConnection]::ClearPool($sql)
		$timer = [Diagnostics.Stopwatch]::StartNew()
		try {
			$sql.Open()
		} catch {
			throw "Cannot connect through '$($Name.Trim())': $(Get-SqlServerErrorText -Record $_)"
		}
		$openMilliseconds = $timer.ElapsedMilliseconds
		$command = $sql.CreateCommand()
		$command.CommandTimeout = 30
		$command.CommandText = "SELECT @@SERVERNAME, DB_NAME(), SUSER_SNAME(), CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)), CAST(SERVERPROPERTY('Edition') AS nvarchar(128)), CAST(CONNECTIONPROPERTY('net_transport') AS nvarchar(40)), CAST(CONNECTIONPROPERTY('auth_scheme') AS nvarchar(40));"
		try {
			$reader = $command.ExecuteReader()
			$null = $reader.Read()
			# A NULL value becomes an empty string.
			$values = @(foreach ($index in 0..6) { [string]$reader.GetValue($index) })
		} catch {
			throw "Connected through '$($Name.Trim())', but cannot read the server properties: $(Get-SqlServerErrorText -Record $_)"
		}
		$reader.Dispose()
		$reader = $null
		# sys.dm_exec_connections needs a server permission that many logins do not have; then the value stays unknown.
		$command.CommandText = 'SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID;'
		$encrypted = try { [string]$command.ExecuteScalar() } catch { '' }
		return [pscustomobject]@{
			OpenMilliseconds = $openMilliseconds
			Server = $values[0]
			Database = $values[1]
			Login = $values[2]
			Version = $values[3]
			Edition = $values[4]
			Transport = $values[5]
			Authentication = $values[6]
			Encrypted = $encrypted
		}
	} finally {
		if ($null -ne $reader) { $reader.Dispose() }
		if ($null -ne $command) { $command.Dispose() }
		Close-SavedSqlConnection -Connection $sql -Credential $credential
	}
}

# Command-line helpers for sql-connection.ps1, sql-database.ps1, and sql-browse.ps1.

# Fail instead of prompting when the caller asked for it or when no console can answer.
function Assert-SqlCliPrompt {
	param([string]$Message, [switch]$NonInteractive)
	if ($NonInteractive) { throw $Message }
	# Hidden prompts read console keys and wait forever when input is redirected,
	# so redirected input counts as non-interactive for every prompt.
	if ([Console]::IsInputRedirected) { throw "$Message Prompts require an interactive console." }
}

# Read-Host can return $null when input ends; treat that like an empty answer.
# A -NonInteractive host can have a console but rejects Read-Host; name the missing value instead.
function Read-SqlCliText {
	param([string]$Prompt, [string]$Missing)
	try {
		return ([string](Read-Host $Prompt)).Trim()
	} catch [System.Management.Automation.PSInvalidOperationException] {
		throw "$Missing Prompts require an interactive console."
	}
}

# Hidden input for a connection string. A -NonInteractive host can have a console but rejects Read-Host;
# name the missing value instead.
function Read-SqlConnectionSecret {
	param([string]$Prompt, [string]$Missing)
	try {
		return Read-Host $Prompt -AsSecureString
	} catch [System.Management.Automation.PSInvalidOperationException] {
		throw "$Missing Prompts require an interactive console."
	}
}

# Repeat a command typed at the prompt only when it looks like a word; it is already visible there.
function Format-SqlCliUnknownCommand {
	param([string]$Value)
	if ($Value -match '^[A-Za-z?/-]{1,20}$') { return "Unknown command '$Value'." }
	return 'Unknown command.'
}

# True when the script is the pwsh -File target, as through the .cmd shim. Only then does the Windows
# command-line parser split the arguments, and a missing closing quote or a quoted value that ends with
# a backslash can join several arguments into one value. In-process PowerShell calls bind values as given.
function Test-SqlCliFileTarget {
	param([string]$ScriptPath)
	foreach ($argument in [Environment]::GetCommandLineArgs()) {
		if ($argument -notlike '*.ps1') { continue }
		$fullPath = try { [IO.Path]::GetFullPath($argument) } catch { $null }
		if ($fullPath -eq $ScriptPath) { return $true }
	}
	return $false
}

# Returns a message when a value shows that the parser joined arguments, or $null. The message does not
# echo the value: it can contain a connection string. $QuoteFreeNames cannot contain a quote, and
# $QuoteEndNames cannot end with one, because cmd cannot tell these apart from a joined argument.
function Get-SqlCliJoinedArgumentError {
	param([Collections.Generic.IDictionary[string, object]]$BoundParameters, [string[]]$ValueNames, [string[]]$QuoteFreeNames, [string[]]$QuoteEndNames)
	foreach ($parameterName in $ValueNames) {
		$boundValue = $BoundParameters[$parameterName]
		if ($boundValue -isnot [string]) { continue }
		# A parameter token inside a value shows that the parser joined it with the next arguments.
		if ($boundValue -match '(?:^|\s)-{1,2}[A-Za-z]') {
			return "Through the .cmd shim or pwsh -File, the -$parameterName value cannot contain a word that starts with -: other arguments were probably joined into it. In cmd, close every quote and do not end a quoted value with a backslash; in PowerShell, run the .ps1 by name instead."
		}
		# A backslash before a closing quote leaves the quote in the value.
		$strayQuote = ($parameterName -in $QuoteFreeNames -and $boundValue.Contains('"')) -or
			($parameterName -in $QuoteEndNames -and $boundValue -match '"\s*$')
		if ($strayQuote) {
			$rule = if ($parameterName -in $QuoteEndNames) { 'cannot end with a quote' } else { 'cannot contain a quote' }
			return "Through the .cmd shim or pwsh -File, the -$parameterName value $rule. In cmd, a quoted value that ends with a backslash leaves such a quote; remove the backslash or the quote."
		}
	}
	return $null
}

# Builds the message for stray arguments. Name only switch-like tokens; any other stray value can be a connection string.
# $Invocation is the script's $MyInvocation; $Example lists parameters for the message, for example "-Name or -Alias".
function Get-SqlCliUnexpectedArgumentError {
	param([object[]]$Arguments, [System.Management.Automation.InvocationInfo]$Invocation, [string]$Example)
	$switchTokens = @($Arguments | Where-Object { $_ -is [string] -and $_ -match '^-[A-Za-z]+:?$' })
	# A known name arrives as a value from array splatting or a quoted name, not from a typo.
	$knownNames = @($Invocation.MyCommand.Parameters.Values | ForEach-Object { $_.Name; $_.Aliases })
	$valueNames = @($switchTokens | Where-Object {
		$text = $_.Trim('-', ':')
		@($knownNames | Where-Object { $_.StartsWith($text, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
	})
	$unknownNames = @($switchTokens | Where-Object { $_ -notin $valueNames })
	$hint = ''
	if ($valueNames) { $hint += " Parameter names that arrived as values: $($valueNames -join ', '). In PowerShell, splat a hashtable, not an array, and do not quote parameter names." }
	if ($unknownNames) { $hint += " Unknown parameters: $($unknownNames -join ', ')." }
	return "Unexpected arguments: $($Arguments.Count).$hint Pass each value with its parameter name, for example $Example."
}

# Returns a message for an explicit -StorePath that must not select or reach a store, or $null.
function Get-SqlCliStorePathError {
	param([Collections.Generic.IDictionary[string, object]]$BoundParameters)
	if (-not $BoundParameters.ContainsKey('StorePath')) { return $null }
	$value = [string]$BoundParameters['StorePath']
	# The library maps an empty path to the default store; an explicit empty override must not change the real store.
	if ([string]::IsNullOrWhiteSpace($value)) { return 'The -StorePath value is empty. Omit -StorePath to use the default store.' }
	# .NET's GetInvalidPathChars() omits the quote, so test the Windows path characters directly.
	if ($value -match '["<>|*\x00-\x1f]') {
		return 'The -StorePath value contains characters that are not valid in a path. In cmd, do not end a quoted path with a backslash.'
	}
	return $null
}
