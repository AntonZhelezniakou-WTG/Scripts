@echo off & setlocal EnableExtensions

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0fetch.ps1" "%CD%"
exit /b %ERRORLEVEL%