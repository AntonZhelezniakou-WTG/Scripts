@echo off
setlocal enabledelayedexpansion

REM Count arguments and assign to numbered variables
set "argCount=0"
for %%A in (%*) do (
	set /a argCount+=1
	set "arg!argCount!=%%~A"
)

if %argCount% LSS 1 (
	echo Usage: debug <Environment> [services^|CW]
	exit /b 1
)

REM Determine target (services or CW), rest is environment name
set "target=services"
if %argCount% GEQ 2 (
	for %%I in (services CW) do (
		if /i "!arg%argCount%!"=="%%I" (
			set "target=%%I"
			set /a envArgCount=argCount-1
			goto :envParsed
		)
	)
)
set /a envArgCount=argCount

:envParsed
set "env="
for /L %%I in (1,1,%envArgCount%) do (
	if defined env (
		set "env=!env! !arg%%I!"
	) else (
		set "env=!arg%%I!"
	)
)

REM Executable base path
set "basePath=c:\git\wtg\CargoWise\Dev\Bin"

REM ── EU Message Testing ─────────────────────────────
if /i "%env%"=="EU Message Testing" (
	if /i "%target%"=="services" (
		"%basePath%\ServiceManager.Runner.CW.exe" WTLDPL.db.sand.wtg.zone UATEUCustomsMessagingTestingALP -debug
		exit /b
	)
	if /i "%target%"=="CW" (
		"%basePath%\CargoWiseOneAnyCpu.exe" WTLDPL.db.sand.wtg.zone UATEUCustomsMessagingTestingALP
		exit /b
	)
)

REM ── Local ──────────────────────────────────────────
if /i "%env%"=="local" (
	if /i "%target%"=="services" (
		"%basePath%\ServiceManager.Runner.CW.exe" . OdysseyTrainingModel -debug
		exit /b
	)
	if /i "%target%"=="CW" (
		"%basePath%\CargoWiseOneAnyCpu.exe" . OdysseyTrainingModel
		exit /b
	)
)

echo Unknown or unsupported environment/target: [%env%] / [%target%]
exit /b 2
