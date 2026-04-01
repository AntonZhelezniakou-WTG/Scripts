param(
    [string]$Panel = "R",
    [string]$Dir   = [System.IO.Directory]::GetCurrentDirectory()
)

# ─────────────────────────────────────────────
#  Locate NirCmd
# ─────────────────────────────────────────────
function Find-Nircmd {
    $searchRoots = @(
        $PSScriptRoot,
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links",
        "$env:ProgramFiles\NirSoft",
        "$env:ProgramFiles\NirCmd",
        "C:\tools",
        "C:\Windows\System32"
    )
    $fromPath = Get-Command "nircmd.exe" -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
    if ($fromPath) { return $fromPath }

    foreach ($root in $searchRoots) {
        if (-not (Test-Path $root)) { continue }
        $hit = Get-ChildItem -Path $root -Filter "nircmd.exe" -Recurse -ErrorAction SilentlyContinue |
                   Select-Object -First 1 -ExpandProperty FullName
        if ($hit) { return $hit }
    }
    return $null
}

$nircmd = Find-Nircmd

if (-not $nircmd) {
    Write-Host ""
    Write-Host "  NirCmd not found." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Installation options:" -ForegroundColor Cyan
    Write-Host "    [1]  Download automatically from nirsoft.net  ->  script folder"
    Write-Host "    [2]  winget install NirSoft.NirCmd"
    Write-Host "    [3]  choco install nircmd"
    Write-Host "    [Q]  Cancel"
    Write-Host ""
    $choice = (Read-Host "  Choice").Trim().ToUpper()

    switch ($choice) {
        "1" {
            $zipUrl  = "https://www.nirsoft.net/utils/nircmd.zip"
            $zipPath = "$env:TEMP\nircmd_dl.zip"
            Write-Host "  Downloading $zipUrl ..." -ForegroundColor Cyan
            try {
                Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
                Expand-Archive -Path $zipPath -DestinationPath $PSScriptRoot -Force
                Remove-Item $zipPath -ErrorAction SilentlyContinue
                $nircmd = "$PSScriptRoot\nircmd.exe"
                if (Test-Path $nircmd) {
                    Write-Host "  Done: $nircmd" -ForegroundColor Green
                } else {
                    Write-Host "  Error: nircmd.exe not found after extraction." -ForegroundColor Red
                    exit 1
                }
            } catch {
                Write-Host "  Download failed: $_" -ForegroundColor Red
                exit 1
            }
        }
        "2" {
            Write-Host "  Running winget..." -ForegroundColor Cyan
            winget install --id NirSoft.NirCmd -e
            $nircmd = Find-Nircmd
            if (-not $nircmd) {
                Write-Host "  nircmd.exe not found after installation. Try option [1] instead." -ForegroundColor Yellow
                exit 1
            }
        }
        "3" {
            Write-Host "  Running choco..." -ForegroundColor Cyan
            choco install nircmd -y
            $nircmd = Find-Nircmd
            if (-not $nircmd) {
                Write-Host "  Please restart cmd after installation and try again." -ForegroundColor Yellow
                exit 1
            }
        }
        default {
            Write-Host "  Cancelled." -ForegroundColor Red
            exit 0
        }
    }
}

# ─────────────────────────────────────────────
#  Total Commander path (hardcoded)
# ─────────────────────────────────────────────
$tc = "C:\Program Files\totalcmd\TOTALCMD64.EXE"

if (-not (Test-Path $tc)) {
    Write-Host "  Total Commander not found at: $tc" -ForegroundColor Red
    exit 1
}

# ─────────────────────────────────────────────
#  Launch TC and navigate to the target folder
#  /O  — reuse existing TC window
#  /L= — navigate left panel
#  /R= — navigate right panel
# ─────────────────────────────────────────────
$flag = $Panel.ToUpper()   # "L" or "R"

Write-Host "  Panel : $flag"       -ForegroundColor Cyan
Write-Host "  Dir   : $Dir"        -ForegroundColor Cyan
Write-Host "  PSRoot: $PSScriptRoot" -ForegroundColor Cyan

$tcArg = "/$flag=`"$Dir`""
Write-Host "  TCArg : $tcArg" -ForegroundColor Cyan

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName         = $tc
$psi.Arguments        = "/O /$flag=`"$Dir`""
$psi.UseShellExecute  = $true
$psi.WorkingDirectory = $Dir
Write-Host "  Launch: $($psi.FileName) $($psi.Arguments)" -ForegroundColor Cyan
[System.Diagnostics.Process]::Start($psi) | Out-Null

# Wait for the TC window to appear (up to 3 seconds)
$deadline = (Get-Date).AddSeconds(3)
$hwnd = $null
while ((Get-Date) -lt $deadline) {
    $proc = Get-Process | Where-Object { $_.MainWindowTitle -like "*Total Commander*" } |
                Select-Object -First 1
    if ($proc -and $proc.MainWindowHandle -ne 0) { $hwnd = $proc.MainWindowHandle; break }
    Start-Sleep -Milliseconds 100
}

if (-not $hwnd) {
    Write-Host "  Total Commander window not found." -ForegroundColor Yellow
    exit 1
}

# ─────────────────────────────────────────────
#  Bring TC window to foreground via NirCmd
# ─────────────────────────────────────────────
& $nircmd win activate title "Total Commander"
Start-Sleep -Milliseconds 200

# ─────────────────────────────────────────────
#  Focus the correct panel
#  Ctrl+Left  -> activate left panel
#  Ctrl+Right -> activate right panel
# ─────────────────────────────────────────────
$shell = New-Object -ComObject WScript.Shell
if ($flag -eq "R") {
    $shell.SendKeys("^{RIGHT}")
} else {
    $shell.SendKeys("^{LEFT}")
}