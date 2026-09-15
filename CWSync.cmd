@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0CWSync.ps1" %*
exit /b %ERRORLEVEL%
