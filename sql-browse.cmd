@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0sql-browse.ps1" %*
exit /b %ERRORLEVEL%
