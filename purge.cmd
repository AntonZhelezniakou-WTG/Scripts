@echo off
setlocal EnableExtensions

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0purge.ps1" "%CD%"
exit /b %ERRORLEVEL%