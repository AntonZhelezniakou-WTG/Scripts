@echo off
SETLOCAL

SET "devenvPath=c:\Program Files\Microsoft Visual Studio\18\Professional\Common7\IDE\devenv.exe"
SET "msbuildPath=c:\Program Files\Microsoft Visual Studio\18\Professional\MSBuild\Current\Bin\MSBuild.exe"

if "%~1"=="" (
	echo.
	echo No solutions specified.
	echo Usage: %~nx0 Solution1.sln [Solution2.sln ...]
	ENDLOCAL
	exit /b 1
)

echo.
echo Starting batch build of all provided solutions...

:NextSolution
if "%~1"=="" goto AllDone

set "SolutionPath=%~1"
set "ProjectName=%~n1"

call :BuildOne "%SolutionPath%"
set "rc=%ERRORLEVEL%"
if not "%rc%"=="0" (
	ENDLOCAL
	exit /b %rc%
)

shift
goto NextSolution

:AllDone
echo.
echo All solutions built successfully.
ENDLOCAL
exit /b 0


:BuildOne
set "SolutionPath=%~1"
set "ProjectName=%~n1"

:RetryBuild
echo.
echo Rebuilding solution: %ProjectName%
echo Path: %SolutionPath%

"%msbuildPath%" "%SolutionPath%" /restore /p:RestorePackagesConfig=true /p:Configuration=Debug /p:Platform="Any CPU"

set "msb_rc=%ERRORLEVEL%"
echo MSBuild exit code: %msb_rc%

if "%msb_rc%"=="0" (
	echo.
	echo Successfully built: %ProjectName%
	exit /b 0
)

echo.
echo Solution %ProjectName% rebuild failed.

choice /C YN /M "Open in Visual Studio? (Y/N)"
if not ERRORLEVEL 2 (
	"%devenvPath%" "%SolutionPath%"
)

echo.
choice /C YN /M "Retry build? (Y/N)"
if ERRORLEVEL 2 (
	exit /b %msb_rc%
)
goto RetryBuild