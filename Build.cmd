@echo off
SETLOCAL

SET "msbuildPath=c:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe"

REM Check if at least one solution path is provided
IF "%~1"=="" (
	echo No solution paths (*.sln) provided.
	exit /b 1
)

:BuildNext
REM If no more arguments, all builds succeeded
IF "%~1"=="" goto Success

echo.
echo Rebuilding solution: %~1
"%msbuildPath%" "%~1" /restore /p:RestorePackagesConfig=true /p:Configuration=Debug /p:Platform="Any CPU"
IF ERRORLEVEL 1 goto ErrorHandler

echo.
echo Successfully built solution: %~1
SHIFT
goto BuildNext

:Success
echo.
echo All solutions were built successfully.
exit /b 0

:ErrorHandler
SET "ErrorCode=%ERRORLEVEL%"
echo.
echo Build failed for solution: %~1
exit /b %ErrorCode%

ENDLOCAL
