@echo off
setlocal
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" -WorkDir "%CD%" %*
exit /b %ERRORLEVEL%
