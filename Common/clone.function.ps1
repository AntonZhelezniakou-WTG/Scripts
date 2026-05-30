# PowerShell wrapper for the `clone` command that performs the post-clone `cd`
# inside the caller's PS session. A child cmd/pwsh process cannot change its
# parent shell's cwd, so this function shadows `clone.cmd` whenever the user is
# in PowerShell and applies the Set-Location in the caller's own session.
#
# Add to your PowerShell profile (~\Documents\PowerShell\Microsoft.PowerShell_profile.ps1):
#   . "D:\GitHub\WiseTechGlobal\Personal\Scripts\Common\clone.function.ps1"

$global:__cloneScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) "clone.ps1"

function global:clone {
	$cdFile = Join-Path $env:TEMP "clone-cd-$([System.Guid]::NewGuid().ToString('N')).tmp"
	try {
		pwsh -NoProfile -ExecutionPolicy Bypass -File $global:__cloneScriptPath -CdFile $cdFile @args
		$code = $LASTEXITCODE
		if (Test-Path -LiteralPath $cdFile) {
			$dir = (Get-Content -LiteralPath $cdFile -Raw).Trim()
			if ($dir -and (Test-Path -LiteralPath $dir)) {
				Set-Location -LiteralPath $dir
			}
		}
		$global:LASTEXITCODE = $code
	} finally {
		if (Test-Path -LiteralPath $cdFile) {
			Remove-Item -LiteralPath $cdFile -Force -ErrorAction SilentlyContinue
		}
	}
}
