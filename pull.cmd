@echo off
setlocal

git rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 (
	echo Error: not a git repository. >&2
	exit /b 1
)

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0pull.ps1" -WorkDir "%CD%" -Target "%~1"
exit /b %ERRORLEVEL%