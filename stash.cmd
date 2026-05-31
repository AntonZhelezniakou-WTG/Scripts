@echo off
setlocal

git rev-parse --is-inside-work-tree >nul 2>&1 || jj root >nul 2>&1
if errorlevel 1 (
    echo Error: not a repository. >&2
    exit /b 1
)

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0stash.ps1" "%CD%" "%~1"
exit /b %ERRORLEVEL%
