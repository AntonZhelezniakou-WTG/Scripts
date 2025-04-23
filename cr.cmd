@echo off
setlocal EnableDelayedExpansion

set "GIT_BASE=C:\git\wtg"
set "BACKUP_BASE=C:\Backups\DevBuilds"
set "DEV_BIN=%GIT_BASE%\CargoWise\Dev\Bin"

REM Prompt for branch name if not provided as an argument
if "%~1"=="" (
    set /p BRANCH="Enter new branch name: "
) else (
    set "BRANCH=%~1"
)

REM Check if branch name is empty
if "%BRANCH%"=="" (
    echo Branch name not provided.
    exit /b 1
)

REM Prepend 'AEM/' if branch name does not already contain '/'
if "%BRANCH:/=%"=="%BRANCH%" set "BRANCH=AEM/%BRANCH%"

REM Check for local changes in the repository
git diff-index --quiet HEAD --
if errorlevel 1 (
    REM Display current status if there are local changes
    git status --short
    set /p choice="Discard local changes? (y/N): "
    if /i not "!choice!"=="y" (
        echo Operation aborted.
        exit /b 1
    ) else (
        REM Discard local changes
        git reset --hard
        git clean -df
    )
)

REM Retrieve the current branch name
for /f "delims=" %%b in ('git rev-parse --abbrev-ref HEAD') do set CURRENT_BRANCH=%%b

REM Switch to master branch if not already on it
if /i not "%CURRENT_BRANCH%"=="master" (
    git checkout master
    if errorlevel 1 (
        echo Failed to switch to master.
        exit /b 1
    )
)

REM Create a new branch from master without tracking
git checkout --no-track -b %BRANCH% refs/heads/master
if errorlevel 1 (
    echo Failed to create branch.
    exit /b 1
)

REM Push the new branch to the remote repository and set upstream
git push origin refs/heads/%BRANCH% --set-upstream
if errorlevel 1 (
    echo Failed to push branch.
    exit /b 1
)
echo Branch %BRANCH% created and pushed successfully.

REM Prompt for branch suffix (required)
set /p SUFFIX="Enter branch suffix (optional): "
if "%SUFFIX%"=="" (
    echo %BRANCH% creation complete.
    goto restore_build
)

REM Initialize variables for suffix transformation
set "rawSuffix=%SUFFIX%"
set "transSuffix="
set "lastUnderscore=0"

REM Loop through each character in the raw suffix to transform it
for /l %%i in (0,1,1000) do (
    set "ch=!rawSuffix:~%%i,1!"
    if "!ch!"=="" goto done_loop

    REM Replace spaces with underscores
    if "!ch!"==" " (
        set "ch=_"
    ) else (
        REM Replace invalid characters with underscore
        echo(!ch!| findstr /r "^[A-Za-z0-9_/\.-]$" >nul
        if errorlevel 1 (
            set "ch=_"
        )
    )

    REM Prevent multiple consecutive underscores
    if "!ch!"=="_" (
        if !lastUnderscore! equ 1 (
            REM Skip adding another underscore
        ) else (
            set "transSuffix=!transSuffix!_"
            set "lastUnderscore=1"
        )
    ) else (
        set "transSuffix=!transSuffix!!ch!"
        set "lastUnderscore=0"
    )
)

:done_loop
set "transSuffix=%transSuffix%"

REM Split the original branch name into prefix and remainder using '_' as delimiter
for /f "tokens=1* delims=_" %%A in ("%BRANCH%") do (
    set "prefix=%%A"
    set "rest=%%B"
)

REM Construct the new branch name by inserting the transformed suffix
if defined rest (
    set "NEWBRANCH=%prefix%_%transSuffix%_%rest%"
) else (
    set "NEWBRANCH=%BRANCH%_%transSuffix%"
)

REM Rename the branch locally to the new branch name
git branch -m "%NEWBRANCH%"
if errorlevel 1 (
    echo Failed to rename branch.
    exit /b 1
)
echo Branch renamed locally to %NEWBRANCH%.

:restore_build
REM Copying latest successful build to Dev\Bin...
echo Copying latest successful build to Dev\Bin...
for /f "delims=" %%D in ('dir /b /ad /o-d "%BACKUP_BASE%\"') do (
		set "latestBuild=%%D"
		goto copy_build
)
echo Latest successful nnot found!
exit /b 1

:copy_build
robocopy "%BACKUP_BASE%\!latestBuild!" "%DEV_BIN%" /MIR /XO
if errorlevel 8 (
		echo Error copying files from latest build.
		exit /b 1
)

endlocal
