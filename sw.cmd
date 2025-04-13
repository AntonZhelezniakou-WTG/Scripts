@echo off
setlocal enabledelayedexpansion

:: ---------------------------------------------------------
:: Global Paths (Define all paths here)
:: ---------------------------------------------------------
set "GIT_BASE=C:\git\wtg"
set "GITHUB_WTG_BASE=C:\git\GitHub\WiseTechGlobal"
set "GITHUB_WTG_PERSONAL=%GITHUB_WTG_BASE%\Personal"
set "BACKUP_BASE=C:\Backups\DevBuilds"
set "DEV_BIN=%GIT_BASE%\CargoWise\Dev\Bin"
set "TORTOISE_GIT=C:\Program Files\TortoiseGit\bin\TortoiseGitProc.exe"

:: ---------------------------------------------------------
:: 1) Define aliases as "alias=path" separated by semicolons.
::    (No trailing semicolon; no spaces around '=')
:: ---------------------------------------------------------
set "aliases="
set "aliases=!aliases!dev=%GIT_BASE%\CargoWise\Dev;"
set "aliases=!aliases!customs=%GIT_BASE%\CargoWise\Customs;"
set "aliases=!aliases!refdata=%GIT_BASE%\RefDataRepo\RefDataRepo;"
set "aliases=!aliases!shared=%GITHUB_WTG_BASE%\CargoWise.Shared;"
set "aliases=!aliases!devtools=%GITHUB_WTG_BASE%\DevTools;"
set "aliases=!aliases!scripts=%GITHUB_WTG_PERSONAL%\Scripts;"
set "aliases=!aliases!shared.old=%GIT_BASE%\CargoWise\Shared;"
set "aliases=!aliases!shared.refdata=%GIT_BASE%\RefDataRepo\Shared"

:: ---------------------------------------------------------
:: 2) Capture command-line parameters.
:: ---------------------------------------------------------
set "PARAM1=%~1"
set "PARAM2=%~2"
if "%PARAM1%"=="" (
    echo You must specify a branch name or a folder alias.
    endlocal
    exit /b 1
)

:: ---------------------------------------------------------
:: 3) Try to treat PARAM1 as a folder directly.
:: ---------------------------------------------------------
cd /d "%PARAM1%" >nul 2>&1
if not errorlevel 1 (
    echo Switching to folder: %PARAM1%
    if not "%PARAM2%"=="" (
       set "BRANCH=%PARAM2%"
       goto :MAIN
    ) else (
       endlocal & cd /d "%PARAM1%"
       exit /b 0
    )
)

:: ---------------------------------------------------------
:: 4) If PARAM1 is not a valid folder, try matching it as an alias.
:: ---------------------------------------------------------
set "foundAlias="
for %%A in ("%aliases:;=" "%") do (
    for /F "tokens=1,* delims==" %%B in (%%A) do (
        if /I "%%B"=="%PARAM1%" (
            cd /d "%%C" >nul 2>&1
            if not errorlevel 1 (
                echo Switching to repo: %%C
                set "foundAlias=1"
                set "ALIASFOLDER=%%C"
                if not "%PARAM2%"=="" (
                    set "BRANCH=%PARAM2%"
                    goto :AFTER_ALIAS_LOOP
                ) else (
                    endlocal & cd /d "%%C"
                    exit /b 0
                )
            )
        )
    )
)

:AFTER_ALIAS_LOOP
if not defined foundAlias (
    set "BRANCH=%PARAM1%"
)

:: ---------------------------------------------------------
:: 5) MAIN: Process branch switching and merging.
:: ---------------------------------------------------------
:MAIN
if "%BRANCH%"=="" (
    echo You must specify a valid branch name.
    goto :error_exit
)

git status --porcelain | findstr /r /c:"." >nul 2>&1
if not errorlevel 1 (
    set "HAS_CHANGES=1"
)
if defined HAS_CHANGES (
    echo Local changes detected:
    git status --short
    echo.
    set /p choice="Discard them? (y/N, default: N): "
    if /i "!choice!"=="" set "choice=n"
    if /i "!choice:~0,1!"=="n" (
        echo Operation aborted.
        goto :error_exit
    ) else (
        if /i "!choice:~0,1!"=="y" (
            echo Discarding all uncommitted changes...
            git reset --hard
            git clean -df
        ) else (
            echo Invalid input. Operation aborted.
            goto :error_exit
        )
    )
)

:: ---------------------------------------------------------
:: 6) Switch to the specified branch.
::    If the branch does not exist locally, try to create it from remote.
:: ---------------------------------------------------------
git rev-parse --verify "%BRANCH%" >nul 2>&1
if errorlevel 1 (
    echo Branch "%BRANCH%" does not exist locally. Attempting to check out from remote...
    git checkout -b "%BRANCH%" origin/"%BRANCH%"
    if errorlevel 1 (
        echo Error while checking out branch "%BRANCH%" from remote.
        goto :error_exit
    )
    echo Successfully checked out branch "%BRANCH%" from remote.
    goto :merge_master
) else (
    git switch "%BRANCH%" --quiet
    if errorlevel 1 (
        git checkout "%BRANCH%"
        if errorlevel 1 (
            echo Error while switching to branch "%BRANCH%".
            goto :error_exit
        )
    )
    echo Switched to branch "%BRANCH%".
)

:: ---------------------------------------------------------
:: 7) Pull updates for the current branch
:: ---------------------------------------------------------
if /I "%BRANCH%"=="master" (
    rem No pull for master branch.
) else (
    for /f "delims=" %%r in ('git rev-parse --abbrev-ref --symbolic-full-name @{u}') do (
       set "REMOTE_FULL=%%r"
    )
    for /f "tokens=1,* delims=/" %%a in ("%REMOTE_FULL%") do (
       set "REMOTE_BRANCH=%%b"
    )
    git pull --rebase=true origin !REMOTE_BRANCH! --prune
    if errorlevel 1 (
       echo Could not pull from origin!
    )
)

:: ---------------------------------------------------------
:: 8) Merge local master into the current branch, except for master.
:: ---------------------------------------------------------
:merge_master
if /I "%BRANCH%"=="master" (
    rem No merge for master branch.
) else (
    echo Merging local master into branch "%BRANCH%"...
    git merge master --no-edit
    if errorlevel 1 (
        echo Merge conflicts detected. Gathering conflict files...
        set "CONFLICT_FILES="
        for /f "tokens=2 delims= " %%I in ('git status --porcelain ^| findstr /r "^UU"') do (
            set "CONFLICT_FILES=!CONFLICT_FILES! %%I"
        )
        echo Launching TortoiseGit Resolve Tool...
        "%TORTOISE_GIT%" /command:resolve /path:"%cd%"

        :WAIT_FOR_RESOLVE
        choice /c RA /m "Conflicts detected. Type R to retry conflict check, A to abort the merge."
        if errorlevel 2 (
            echo Aborting merge...
            git merge --abort
            goto :error_exit
        )

        git status --porcelain | findstr /r "^UU" >nul 2>&1
        if not errorlevel 1 (
            echo Conflicts still unresolved. Retry or abort.
            goto :WAIT_FOR_RESOLVE
        )

        echo All conflicts resolved. Continuing...
        echo Creating auto-generated commit message...
        set "COMMIT_MESSAGE=Merged master into %BRANCH%. Conflicts resolved in:%CONFLICT_FILES%"
        echo Commit message:
        echo %COMMIT_MESSAGE%
        git add .
        git commit -m "%COMMIT_MESSAGE%"
        if errorlevel 1 (
            echo Error: Commit operation failed.
            goto :error_exit
        )
        echo Merge complete.
    ) else (
        echo Merge complete. Checking for staged changes...
        git diff --staged --exit-code >nul 2>&1
        if "%ERRORLEVEL%"=="0" (
            echo Nothing to commit, working tree clean.
        ) else (
            echo Changes detected. Committing merge...
            git commit --no-edit
            if errorlevel 1 (
                echo Error: Commit operation failed.
                goto :error_exit
            )
            echo Merge complete.
        )
    )
)

:: ---------------------------------------------------------
:: 9) Copy latest successful build to Dev\Bin (only if repo is CargoWise\Dev)
:: ---------------------------------------------------------
if /I "%cd%"=="%GIT_BASE%\CargoWise\Dev" (
    echo Copying latest successful build to Dev\Bin...

    for /f "delims=" %%D in ('dir /b /ad /o-d "%BACKUP_BASE%\"') do (
        set "latestBuild=%%D"
        goto :copy_build
    )

    :copy_build
    robocopy "%BACKUP_BASE%\!latestBuild!" "%DEV_BIN%" /MIR /XO
    if errorlevel 8 (
        echo Error copying files from latest build.
        goto :error_exit
    )
)

goto :success

:success
if defined foundAlias (
    echo Successfully switched to branch "%BRANCH%" and processed updates.
    echo Changing prompt directory to: %ALIASFOLDER%
    endlocal & cd /d "%ALIASFOLDER%"
) else (
    echo Successfully switched to branch "%BRANCH%" and processed updates.
    endlocal
    pause
)
exit /b 0

:error_exit
if defined foundAlias (
    echo Error encountered. Switching to alias folder: %ALIASFOLDER%
    endlocal & cd /d "%ALIASFOLDER%"
) else (
    endlocal
)
exit /b 1
