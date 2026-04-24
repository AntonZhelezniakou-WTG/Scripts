@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0reauth.ps1" %*
exit /b %ERRORLEVEL%
