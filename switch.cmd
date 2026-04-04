@echo off
setlocal EnableExtensions

git rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 (
    echo Error: not a git repository.
    pause
    exit /b 1
)

:: Resolve the .ps1 file next to this .cmd
set "PS1=%~dp0switch.ps1"

if not exist "%PS1%" (
    echo Error: git-checkout.ps1 not found next to %~f0
    pause
    exit /b 1
)

pwsh -NoProfile -ExecutionPolicy Bypass -File "%PS1%" "%CD%" "%~1"

exit /b %ERRORLEVEL%