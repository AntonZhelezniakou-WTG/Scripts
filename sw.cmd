@echo off & setlocal EnableExtensions

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0sw.ps1" %*
exit /b %ERRORLEVEL%