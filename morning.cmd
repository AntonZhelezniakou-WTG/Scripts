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

:: Define all paths at the start of the file
set "DEV_REPO_PATH=C:\git\wtg\CargoWise\Dev"
set "CUSTOMS_REPO_PATH=C:\git\wtg\CargoWise\Customs"
set "SHARED_REPO_PATH=C:\git\wtg\CargoWise\Shared"
set "GITHUB_SHARED_REPO_PATH=C:\git\GitHub\WiseTechGlobal\CargoWise.Shared"
set "REFDATAREPO_PATH=c:\git\wtg\RefDataRepo\RefDataRepo"
set "REFDATAREPO_SHARED_PATH=c:\git\wtg\RefDataRepo\Shared"
set "BUILDS_BACKUP_DIR=C:\Backups\DevBuilds"
set "DEV_BIN_PATH=C:\git\wtg\CargoWise\Dev\Bin"
::set "QGL_EXE_PATH=c:\WTG\QGL\qgl.exe"
set "NOTEPAD_PATH=C:\Program Files\Notepad++\notepad++.exe"
set "UPGRADE_DBS_PATH=C:\WTG\Cmd\Devs hacks\Upgrade DBs.cmd"
set "TEMP_PATH=%TEMP%"
set "QGL_LOGS_PATH=%LOCALAPPDATA%\WiseTech Global\QuickGetLatest\Logs"
set "VS_CHECK_FILE=%TEMP_PATH%\vs_check.txt"
set "GIT_BACKUP_DIR_PREFIX=%TEMP_PATH%\git_backup_"

:: Define repository paths
set "repos[0]=%DEV_REPO_PATH%"
set "repos[1]=%CUSTOMS_REPO_PATH%"
set "repos[2]=%SHARED_REPO_PATH%"
set "repos[3]=%GITHUB_SHARED_REPO_PATH%"
set "repos[4]=%REFDATAREPO_PATH%"
set "repos[5]=%REFDATAREPO_SHARED_PATH%"
set "total=6"
set "counter=0"

:: ---------------------------------------------------------
:: Check if Visual Studio is running - using simplest possible approach
:: ---------------------------------------------------------
:check_visual_studio
tasklist > "%VS_CHECK_FILE%"
type "%VS_CHECK_FILE%" | find "devenv"
if errorlevel 1 goto vs_not_running
    echo Visual Studio is running.
    echo Please close Visual Studio before proceeding.
    echo Press Y to continue or N to abort.
    set /p choice=Your choice (Y/N): 
    if /i "%choice%"=="n" (
        echo Operation aborted.
        endlocal
        exit /b 1
    )
    goto check_visual_studio
:vs_not_running
del "%VS_CHECK_FILE%"

:: ------------------------------------------------------------------
:: Delete backup folders older than 7 days in C:\Backups\DevBuilds
:: If all folders are older than 7 days, preserve the newest one.
:: ------------------------------------------------------------------
set "totalFolders=0"
for /D %%F in ("%BUILDS_BACKUP_DIR%\*") do (
    set /a totalFolders+=1
)

:: Count subdirectories older than 7 days using forfiles.
set "oldCount=0"
for /F "tokens=*" %%F in ('forfiles /P "%BUILDS_BACKUP_DIR%" /D -7 /C "cmd /c if @isdir==TRUE echo @path" 2^>NUL') do (
    set /a oldCount+=1
)

:: If at least one folder exists and all are older than 7 days,
:: then determine the newest folder (to be preserved) by capturing the first result.
if %totalFolders% GTR 0 if %oldCount% EQU %totalFolders% (
    for /F "tokens=*" %%G in ('dir /AD /B /O-D "%BUILDS_BACKUP_DIR%"') do (
        if not defined newestFolder (
            set "newestFolder=%%G"
        )
    )
)

:: Delete backup folders older than 7 days, skipping the newest folder if defined.
for /F "tokens=*" %%F in ('forfiles /P "%BUILDS_BACKUP_DIR%" /D -7 /C "cmd /c if @isdir==TRUE echo @path" 2^>NUL') do (
    for %%P in (%%F) do set "folderName=%%~nxP"
    if defined newestFolder (
        if /I "!folderName!"=="!newestFolder!" (
            echo Skipping newest backup folder: !folderName!
        ) else (
            echo Deleting folder: !folderName!
            rd /s /q "%%F"
        )
    ) else (
        echo Deleting folder: !folderName!
        rd /s /q "%%F"
    )
)

:: ------------------------------------------------------------------
:: Save current commit hash of the Dev repository (for potential rollback)
:: ------------------------------------------------------------------
if exist "%DEV_REPO_PATH%" (
    pushd "%DEV_REPO_PATH%"
    for /F "tokens=*" %%C in ('git rev-parse HEAD') do (
        set "devPrePull=%%C"
    )
    popd
    echo Saved current commit for CargoWise Dev: !devPrePull!
) else (
    echo ERROR: Repository %DEV_REPO_PATH% does not exist.
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
git status --porcelain | findstr "." >NUL
if not errorlevel 1 (
    echo Local changes detected in "!repo!"
    set /p choice="Discard changes? (y/N): " || set "choice=n"
    if /I "!choice!"=="n" (
        echo Operation aborted for "!repo!".
        goto :LOOP
    )
    set "gitBackupDir=%GIT_BACKUP_DIR_PREFIX%%RANDOM%"
    mkdir "!gitBackupDir!"
    echo Backing up local changes to "!gitBackupDir!"
    git diff > "!gitBackupDir!\changes.patch"
    git ls-files --modified --others --exclude-standard > "!gitBackupDir!\changed_files.txt"
    for /F "tokens=*" %%f in ('type "!gitBackupDir!\changed_files.txt"') do (
        copy "%%f" "!gitBackupDir!\" >NUL 2>&1
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

::echo "%DEV_REPO_PATH%"
::"%QGL_EXE_PATH%" build -m FULL --error-mode ShowError -v -i -r -p "%DEV_REPO_PATH%"
qgl build -m FULL --error-mode ShowError -v -i -p "%DEV_REPO_PATH%"

if errorlevel 1 (
    echo Build error occurred. Opening latest log file...
    set "LATEST_LOG="
    for /F "tokens=*" %%i in ('dir /B /O-D "%QGL_LOGS_PATH%\*.log"') do (
        if not defined LATEST_LOG set "LATEST_LOG=%%i"
    )
    if defined LATEST_LOG (
        start "" "%NOTEPAD_PATH%" "%QGL_LOGS_PATH%\%LATEST_LOG%"
    ) else (
        echo No log file found.
    )
    :: On build failure: revert Dev repository and restore latest backup.
    if defined devPrePull (
        echo Reverting %DEV_REPO_PATH% to commit !devPrePull!...
        pushd "%DEV_REPO_PATH%"
        git reset --hard !devPrePull!
        popd
    ) else (
        echo No previous commit recorded.
    )
    echo Clearing %DEV_BIN_PATH%...
    rd /s /q "%DEV_BIN_PATH%"
    mkdir "%DEV_BIN_PATH%"
    set "latestBackup="
    for /F "tokens=*" %%F in ('dir /AD /B /O-D "%BUILDS_BACKUP_DIR%"') do (
        if not defined latestBackup (
            set "latestBackup=%%F"
        )
    )
    if defined latestBackup (
        echo Restoring backup from "%BUILDS_BACKUP_DIR%\!latestBackup!"...
        xcopy "%BUILDS_BACKUP_DIR%\!latestBackup!\*" "%DEV_BIN_PATH%\" /S /E /H /Y
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
    set "newBackupDir=%BUILDS_BACKUP_DIR%\!timestamp!"
    mkdir "!newBackupDir!"
    echo Created backup directory: !newBackupDir!
    echo Copying %DEV_BIN_PATH% to !newBackupDir!...
    xcopy "%DEV_BIN_PATH%\*" "!newBackupDir!\" /S /E /H /Y >NUL
    echo QGL build succeeded. Launching DB upgrade...
    call "%UPGRADE_DBS_PATH%"
)

echo.
echo ========================================
echo Process completed. Press any key to exit.
pause
exit /B