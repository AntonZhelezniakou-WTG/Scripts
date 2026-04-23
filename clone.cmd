@echo off
set "CDFILE=%TEMP%\clone-cd-%RANDOM%.tmp"
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0clone.ps1" -CdFile "%CDFILE%" %*
if not exist "%CDFILE%" exit /b 0
set "CDDIR="
set /p CDDIR=<"%CDFILE%"
del "%CDFILE%" >nul 2>&1
if defined CDDIR cd /d "%CDDIR%"
