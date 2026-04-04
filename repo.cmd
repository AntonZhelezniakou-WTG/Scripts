@echo off & setlocal EnableExtensions

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0repo.ps1" %*
exit /b %ERRORLEVEL%