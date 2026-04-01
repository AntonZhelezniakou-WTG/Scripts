@echo off
setlocal

set "NOCACHE="
set "ASKEY="

:parse_args
shift /2
if "%~2"=="--no-cache" ( set "NOCACHE=-NoCache" & goto parse_args )
if "%~2"=="--as-key"   ( set "ASKEY=-AsKey"     & goto parse_args )
if "%~2" neq ""        ( goto parse_args )

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0get.ps1" -WorkDir "%CD%" -Command "%~1" %NOCACHE% %ASKEY%
exit /b %ERRORLEVEL%