@echo off
setlocal

if "%~1"=="" (
    echo Usage: create ^<branch-name^>
    exit /b 1
)

git rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 (
    echo Error: not a git repository. >&2
    exit /b 1
)

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0create.ps1" "%CD%" "%~1"
exit /b %ERRORLEVEL%