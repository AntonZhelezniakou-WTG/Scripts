# SQL Server profiles. Load through common.ps1.
# Only the connection string is encrypted; names and descriptions are searchable.

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

function Get-SqlConnectionProfilePath {
	param([string]$Name, [string]$StorePath)
	# Validate the same trimmed text that the key uses.
	$Name = $Name.Trim()
	if ($Name.Length -eq 0 -or $Name.Length -gt 128 -or $Name -match '[\x00-\x1f\x7f]') {
		throw 'Use a connection name of 1 to 128 characters without control characters.'
	}
	# Hash the label so names cannot become paths, wildcards, or Windows device names.
	$key = $Name.Normalize().ToUpperInvariant()
	$hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key)))
	return Join-Path (Get-SqlConnectionStorePath -StorePath $StorePath) "$hash.json"
}

function Read-SqlConnectionProfile {
	param([string]$Path)
	$document = $null
	try {
		# System.Text.Json keeps each value as written; ConvertFrom-Json turns ISO date-time text into DateTime.
		$document = [System.Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($Path))
		$root = $document.RootElement
		if ($root.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw 'Invalid profile.' }
		$version = $root.GetProperty('Version')
		if ($version.ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or $version.GetInt32() -ne 1) { throw 'Invalid profile.' }
		$text = @{}
		foreach ($propertyName in @('Name', 'Description', 'EncryptedConnectionString')) {
			$element = $root.GetProperty($propertyName)
			if ($element.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { throw 'Invalid profile.' }
			$text[$propertyName] = $element.GetString()
		}
		if ([string]::IsNullOrWhiteSpace($text.EncryptedConnectionString)) { throw 'Invalid profile.' }
		$connectionProfile = [pscustomobject]@{
			Version = 1
			Name = $text.Name
			Description = $text.Description
			EncryptedConnectionString = $text.EncryptedConnectionString
		}
		$expectedPath = Get-SqlConnectionProfilePath -Name $connectionProfile.Name -StorePath (Split-Path $Path -Parent)
		if ([IO.Path]::GetFileName($Path) -ine [IO.Path]::GetFileName($expectedPath)) { throw 'Invalid profile name.' }
		return $connectionProfile
	} catch {
		throw "Cannot read SQL connection profile '$([IO.Path]::GetFileName($Path))': its format is not valid, or the file is not accessible. If you know its name, remove it with the profile manager's delete -Name and add it again."
	} finally {
		if ($null -ne $document) { $document.Dispose() }
	}
}

function Get-SqlConnectionProfiles {
	param([string]$Name, [string]$StorePath)
	$directory = Get-SqlConnectionStorePath -StorePath $StorePath
	if (-not [string]::IsNullOrWhiteSpace($Name)) {
		$path = Get-SqlConnectionProfilePath -Name $Name -StorePath $directory
		if (-not [IO.File]::Exists($path)) { throw 'The named SQL connection does not exist. Use list to see saved connections.' }
		$profiles = @(Read-SqlConnectionProfile -Path $path)
	} elseif ([IO.Directory]::Exists($directory)) {
		$profiles = @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File | ForEach-Object {
			$file = $_
			# One damaged or foreign file must not hide the other profiles.
			try {
				Read-SqlConnectionProfile -Path $file.FullName
			} catch {
				Write-Warning "Skipped '$($file.Name)' in '$directory': it is not a readable SQL connection profile. If you know its name, remove it with delete -Name."
			}
		})
	} else {
		$profiles = @()
	}
	# Do not decrypt secrets or return ciphertext when listing profiles.
	$profiles | Sort-Object Name | Select-Object Name, Description
}

# A description is public metadata. Refuse text that looks like a password, however it arrived (for example
# a cmd quoting mistake that joined the connection string into it), and do not echo it.
# $Subject names the value in the message, for example "The -Description value".
function Assert-SqlConnectionPublicText {
	param([string]$Value, [string]$Subject)
	if ($Value -match '(?i)\b(password|pwd)\s*=') {
		throw "$Subject looks like it contains a password. Descriptions are public metadata; give the connection string only where a connection string is requested."
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
	$lock = $null
	$tempPath = $null
	try {
		try {
			$lock = [IO.File]::Open((Join-Path $directory '.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
		} catch {
			throw 'Cannot lock the connection store. Another update may be running, or the directory may be inaccessible.'
		}
		if ($Add) {
			if ([IO.File]::Exists($path)) { throw 'This connection name already exists. Use modify to change it.' }
		} elseif (-not [IO.File]::Exists($path) -or [IO.File]::ReadAllText($path) -cne $ExpectedContent) {
			throw 'The connection changed or was deleted during editing. Run modify again.'
		}
		Clear-SqlConnectionInterruptedWrite -Directory $directory
		$tempPath = Join-Path $directory ".write-$([guid]::NewGuid().ToString('N')).tmp"
		$json = $ConnectionProfile | ConvertTo-Json -Depth 3
		[IO.File]::WriteAllText($tempPath, $json, [Text.UTF8Encoding]::new($false))
		# Same-directory rename publishes the complete encrypted file in one operation.
		try {
			[IO.File]::Move($tempPath, $path, -not $Add)
		} catch [IO.IOException], [UnauthorizedAccessException] {
			throw 'Cannot save the profile file. Another process may be reading it, or the store may be read-only. Try again.'
		}
	} finally {
		# A failed cleanup must not keep the store locked; the next update removes the temporary file.
		try {
			if ($null -ne $tempPath -and [IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
		} catch {
			Write-Warning "Cannot delete the temporary file '$([IO.Path]::GetFileName($tempPath))'. The next update removes it."
		} finally {
			if ($null -ne $lock) { $lock.Dispose() }
		}
	}
}

function Remove-SqlConnectionProfile {
	param([string]$Name, [string]$StorePath)
	$directory = Get-SqlConnectionStorePath -StorePath $StorePath
	$path = Get-SqlConnectionProfilePath -Name $Name -StorePath $directory
	if (-not [IO.File]::Exists($path)) { throw 'The named SQL connection does not exist. Use list to see saved connections.' }
	$lock = $null
	try {
		try {
			$lock = [IO.File]::Open((Join-Path $directory '.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
		} catch {
			throw 'Cannot lock the connection store. Another update may be running, or the directory may be inaccessible.'
		}
		if (-not [IO.File]::Exists($path)) { throw 'The connection was already deleted.' }
		Clear-SqlConnectionInterruptedWrite -Directory $directory
		try {
			[IO.File]::Delete($path)
		} catch [IO.IOException], [UnauthorizedAccessException] {
			throw 'Cannot delete the profile file. Another process may be reading it, or the store may be read-only. Try again.'
		}
	} finally {
		if ($null -ne $lock) { $lock.Dispose() }
	}
}

function New-SavedSqlConnection {
	# CmdletBinding makes a misspelled parameter, such as -Path, an error instead of a silent default store.
	[CmdletBinding()]
	[OutputType([System.Data.SqlClient.SqlConnection])]
	param([string]$Name, [string]$StorePath)
	# With -ErrorAction SilentlyContinue or a session preference of SilentlyContinue, throw does not stop a function.
	# Each check below must stop it, so that a failed check never continues to a profile in another store.
	$ErrorActionPreference = 'Stop'
	# An agent shell can lose a variable between calls; an empty explicit store must not load the real profile.
	if ($PSBoundParameters.ContainsKey('StorePath') -and [string]::IsNullOrWhiteSpace($StorePath)) {
		throw 'The -StorePath value is empty. Omit -StorePath to use the default store.'
	}
	$path = Get-SqlConnectionProfilePath -Name $Name -StorePath $StorePath
	if (-not [IO.File]::Exists($path)) { throw 'The named SQL connection does not exist. Use list to see saved connections.' }
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
