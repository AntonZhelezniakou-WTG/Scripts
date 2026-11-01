@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0sql-connection.ps1" %*
exit /b %ERRORLEVEL%
