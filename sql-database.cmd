@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0sql-database.ps1" %*
exit /b %ERRORLEVEL%
