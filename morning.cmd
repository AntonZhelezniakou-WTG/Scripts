@echo off
setlocal enabledelayedexpansion

:: ------------------------------------------------------------------
:: Script: UpdateDevAndBuild.cmd
:: Description:
::   - Clean up backup folders in C:\Backups\DevBuilds that are older than 7 days.
::     If all folders are older than 7 days, the newest folder is preserved.
::   - Save the current commit of the Dev repository.
::   - Update a set of Git repositories.
::   - Run the QGL build.
::   - On build failure, revert to the previous commit and restore the latest backup.
::   - On build success, create a new backup and launch the DB upgrade.
:: ------------------------------------------------------------------

:: Define repository paths
set "repos[0]=C:\git\wtg\CargoWise\Dev"
set "repos[1]=C:\git\wtg\CargoWise\Customs"
set "repos[2]=C:\git\wtg\CargoWise\Shared"
set "repos[3]=C:\git\GitHub\WiseTechGlobal\CargoWise.Shared"
set "repos[4]=c:\git\wtg\RefDataRepo\RefDataRepo"
set "repos[5]=c:\git\wtg\RefDataRepo\Shared"
set "total=6"
set "counter=0"

:: ------------------------------------------------------------------
:: Delete backup folders older than 7 days in C:\Backups\DevBuilds
:: If all folders are older than 7 days, preserve the newest one.
:: ------------------------------------------------------------------
set "buildsBackupDir=C:\Backups\DevBuilds"
set "totalFolders=0"
for /D %%F in ("%buildsBackupDir%\*") do (
    set /a totalFolders+=1
)

:: Count subdirectories older than 7 days using forfiles.
:: The usebackq option with backticks ensures that inner quotes are processed correctly.
set "oldCount=0"
for /F "usebackq delims=" %%F in (`forfiles /P "%buildsBackupDir%" /D -7 /C "cmd /c if @isdir==TRUE echo @relpath" 2^>nul`) do (
    set /a oldCount+=1
)

:: If at least one folder exists and all are older than 7 days,
:: then determine the newest folder (to be preserved) by capturing the first result.
if %totalFolders% GTR 0 if %oldCount% EQU %totalFolders% (
    for /F "usebackq delims=" %%G in (`dir /AD /B /O-D "%buildsBackupDir%"`) do (
        if not defined newestFolder (
            set "newestFolder=%%G"
        )
    )
)

:: Delete backup folders older than 7 days, skipping the newest folder if defined.
for /F "usebackq delims=" %%F in (`forfiles /P "%buildsBackupDir%" /D -7 /C "cmd /c if @isdir==TRUE echo @relpath" 2^>nul`) do (
    if defined newestFolder (
        if /I "%%F"=="!newestFolder!" (
            echo Skipping newest backup folder: %%F
        ) else (
            echo Deleting folder: %%F
            rd /s /q "%buildsBackupDir%\%%F"
        )
    ) else (
        echo Deleting folder: %%F
        rd /s /q "%buildsBackupDir%\%%F"
    )
)

:: ------------------------------------------------------------------
:: Save current commit hash of the Dev repository (for potential rollback)
:: ------------------------------------------------------------------
if exist "C:\git\wtg\CargoWise\Dev" (
    pushd "C:\git\wtg\CargoWise\Dev"
    for /F "delims=" %%C in ('git rev-parse HEAD') do (
        set "devPrePull=%%C"
    )
    popd
    echo Saved current commit for CargoWise Dev: !devPrePull!
) else (
    echo ERROR: Repository C:\git\wtg\CargoWise\Dev does not exist.
)

:: ------------------------------------------------------------------
:: Check for the -noupdate flag; if present, skip repository updates.
:: ------------------------------------------------------------------
set "SKIP_UPDATE=0"
for %%A in (%*) do (
    if /I "%%A"=="-noupdate" set "SKIP_UPDATE=1"
)
if %SKIP_UPDATE%==1 goto :AFTER_UPDATES

:: ------------------------------------------------------------------
:: Update all repositories in sequence.
:: ------------------------------------------------------------------
:LOOP
if !counter! GEQ !total! goto :AFTER_UPDATES
set "repo=!repos[%counter%]!"
set /a counter+=1

echo.
echo ========================================
echo Updating repository: "!repo!"
echo ========================================
echo.

if not exist "!repo!" (
    echo ERROR: Repository path "!repo!" does not exist.
    goto :LOOP
)

cd /d "!repo!" || (
    echo ERROR: Could not access "!repo!"
    goto :LOOP
)

:: Check for local changes
git status --porcelain | findstr /R /C:"." >nul 2>&1
if not errorlevel 1 (
    echo Local changes detected in "!repo!"
    set /p choice="Discard changes? (y/N): " || set "choice=n"
    if /I "!choice!"=="n" (
        echo Operation aborted for "!repo!".
        goto :LOOP
    )
    set "gitBackupDir=%TEMP%\git_backup_%RANDOM%"
    mkdir "!gitBackupDir!"
    echo Backing up local changes to "!gitBackupDir!"
    git diff > "!gitBackupDir!\changes.patch"
    git ls-files --modified --others --exclude-standard > "!gitBackupDir!\changed_files.txt"
    for /F "delims=" %%f in (!gitBackupDir!\changed_files.txt) do (
        copy "%%f" "!gitBackupDir!\" >nul 2>&1
    )
    git reset --hard
    git clean -df
)

echo Switching to master in "!repo!"
git checkout master
git pull origin master
echo Repository update completed for "!repo!".
goto :LOOP

:: ------------------------------------------------------------------
:: After repository updates, run the QGL build.
:: ------------------------------------------------------------------
:AFTER_UPDATES
echo.
echo ========================================
echo All repositories updated. Running QGL build...
echo ========================================
echo.

::"c:\Cmd\qgl\qgl.exe" build -m FULL --error-mode ShowError -v -i -r -p "C:\git\wtg\CargoWise\Dev"
"c:\WTG\QGL\qgl.exe" build -m FULL --error-mode ShowError -v -i -r -p "C:\git\wtg\CargoWise\Dev"

if errorlevel 1 (
    echo Build error occurred. Opening latest log file...
    set "LATEST_LOG="
    for /F "usebackq delims=" %%i in (`dir /B /O-D "%LOCALAPPDATA%\WiseTech Global\QuickGetLatest\Logs\*.log"`) do (
        if not defined LATEST_LOG set "LATEST_LOG=%%i"
    )
    if defined LATEST_LOG (
        "C:\Program Files\Notepad++\notepad++.exe" "%LOCALAPPDATA%\WiseTech Global\QuickGetLatest\Logs\%LATEST_LOG%"
    ) else (
        echo No log file found.
    )
    :: On build failure: revert Dev repository and restore latest backup.
    if defined devPrePull (
        echo Reverting C:\git\wtg\CargoWise\Dev to commit !devPrePull!...
        pushd "C:\git\wtg\CargoWise\Dev"
        git reset --hard !devPrePull!
        popd
    ) else (
        echo No previous commit recorded.
    )
    echo Clearing C:\git\wtg\CargoWise\Dev\Bin...
    rd /s /q "C:\git\wtg\CargoWise\Dev\Bin"
    mkdir "C:\git\wtg\CargoWise\Dev\Bin"
    set "latestBackup="
    for /F "usebackq delims=" %%F in (`dir /AD /B /O-D "C:\Backups\DevBuilds"`) do (
        if not defined latestBackup (
            set "latestBackup=%%F"
        )
    )
    if defined latestBackup (
        echo Restoring backup from "C:\Backups\DevBuilds\!latestBackup!"...
        xcopy "C:\Backups\DevBuilds\!latestBackup!\*" "C:\git\wtg\CargoWise\Dev\Bin\" /S /E /H /Y
    ) else (
        echo No backup folder found.
    )
    echo Build failed. Please review the log.
    pause
    exit /B 1
) else (
    :: On build success: create a new backup and launch the DB upgrade.
    for /F "tokens=2 delims==." %%I in ('wmic os get localdatetime /value') do set "ldt=%%I"
    set "timestamp=!ldt:~0,4!-!ldt:~4,2!-!ldt:~6,2!-!ldt:~8,2!-!ldt:~10,2!"
    set "newBackupDir=C:\Backups\DevBuilds\!timestamp!"
    mkdir "!newBackupDir!"
    echo Created backup directory: !newBackupDir!
    echo Copying C:\git\wtg\CargoWise\Dev\Bin to !newBackupDir!...
    xcopy "C:\git\wtg\CargoWise\Dev\Bin\*" "!newBackupDir!\" /S /E /H /Y 1>nul
    echo QGL build succeeded. Launching DB upgrade...
    "C:\WTG\Cmd\Devs hacks\Upgrade DBs.cmd"
)

echo.
echo ========================================
echo Process completed. Press any key to exit.
pause
exit /B
