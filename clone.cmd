@echo off
set "CDFILE=%TEMP%\clone-cd-%RANDOM%.tmp"
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0clone.ps1" -CdFile "%CDFILE%" %*
if exist "%CDFILE%" (
	set /p CDDIR=<"%CDFILE%"
	del "%CDFILE%" >nul 2>&1
	cd /d "%CDDIR%"
)