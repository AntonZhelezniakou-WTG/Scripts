@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0CWPump.ps1" %*
exit /b %ERRORLEVEL%
