@echo off
setlocal enabledelayedexpansion

:: 1. Fetch remote branches (only once)
:: echo Fetching remote branches...
:: git fetch --all

:: 2. Detect current branch
echo Detecting current branch
for /f "delims=" %%c in ('git rev-parse --abbrev-ref HEAD') do (
    set "CURRENT_BRANCH=%%c"
)
echo Current branch: %CURRENT_BRANCH%
echo.

:: 3. If not on master, check for uncommitted changes and optionally switch to master
if /i not "%CURRENT_BRANCH%"=="master" (
    echo You are not on the master branch. Checking for local changes...
    git status --porcelain | findstr /r /c:"." >nul 2>&1
    if not errorlevel 1 (
        echo Uncommitted changes detected:
        git status --short
        echo.
        set /p disc="Discard them? (y/N, default: N): "
        if /i "!disc!"=="y" (
            git reset --hard
            git clean -df
        ) else (
            echo Operation aborted.
            goto :end
        )
    )
    git checkout master || goto :end
    set "CURRENT_BRANCH=master"
    echo Switched to master.
    echo.
)

:: 4. Process each local branch (excluding master)
echo Iterating all local branches
for /f "delims=" %%b in ('git for-each-ref --format="%%(refname:short)" refs/heads/') do (
    if /i not "%%b"=="master" (
        set "BRANCH=%%b"
        set "CHECK_BRANCH=%%b"
        set "PROPOSE_DELETE=false"
        set "EFFECTIVE_MERGED=false"

        :: Get upstream branch name, if available
        for /f "delims=" %%u in ('git rev-parse --abbrev-ref %%b@{upstream} 2^>nul') do (
            set "CHECK_BRANCH=%%u"
        )

        :: Use patch-check method: get merge base between CHECK_BRANCH and origin/master
        for /f "delims=" %%m in ('git merge-base !CHECK_BRANCH! origin/master') do set "MB=%%m"
        echo Merge base for !CHECK_BRANCH! is !MB!
        
        :: Create a patch (diff) from merge-base to CHECK_BRANCH
        git diff !MB! !CHECK_BRANCH! > patch.diff
        
        :: Check if reverse applying the patch to origin/master works (i.e. changes already exist)
        git apply --reverse --check patch.diff >nul 2>&1
        if !errorlevel! equ 0 (
            set "EFFECTIVE_MERGED=true"
            echo !BRANCH! is effectively merged into origin/master.
        ) else (
            echo !BRANCH! is NOT effectively merged into origin/master.
        )
        del patch.diff

        :: Mark branch for deletion if its name does NOT start with "AEM/"
        if /i not "!BRANCH:~0,4!"=="AEM/" (
            set "PROPOSE_DELETE=true"
            echo !BRANCH! does not start with AEM/.
        )

        :: Also mark for deletion if the patch-check indicates effective merge
        if /i "!EFFECTIVE_MERGED!"=="true" (
            set "PROPOSE_DELETE=true"
        )

        :: If deletion is proposed, prompt the user with three options: Yes, No, or Exit (default: No)
        if /i "!PROPOSE_DELETE!"=="true" (
            if /i not "!BRANCH!"=="%CURRENT_BRANCH%" (
                choice /c YNE /n /t 9999 /d N /m "Delete branch !BRANCH!? (Y)es/(N)o/(E)xit: "
                if errorlevel 3 (
                    echo Exiting script.
                    goto :end
                )
                if errorlevel 2 (
                    echo Skipping branch !BRANCH!.
                ) else (
                    git branch -D !BRANCH!
                )
            ) else (
                echo Skipping current branch !BRANCH!.
            )
        )
        echo.
    )
)

:end
endlocal
pause
exit /b
