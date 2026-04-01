@echo off
setlocal

set "NOCACHE="
if /i "%~1"=="--no-cache" set "NOCACHE=-NoCache"

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0q.ps1" -WorkDir "%CD%" %NOCACHE%
exit /b %ERRORLEVEL%