@echo off
set "CDFILE=%TEMP%\clone-cd-%RANDOM%.tmp"
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0clone.ps1" -CdFile "%CDFILE%" %*
if exist "%CDFILE%" (
	for /f "usebackq delims=" %%i in ("%CDFILE%") do set "CDDIR=%%i"
	del "%CDFILE%" >nul 2>&1
	if defined CDDIR cd /d "%CDDIR%"
)