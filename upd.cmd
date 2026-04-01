@echo off
setlocal

set "GITEXTENSIONS_EXE=C:\Program Files\GitExtensions\GitExtensions.exe"
rem git merge master --no-edit

:merge_master
echo [info] Merging master (quiet)...
git merge master --no-edit --quiet --no-stat
if errorlevel 1 (
	echo [warn] Merge conflicts detected. Gathering conflict files...
	setlocal EnableDelayedExpansion
	set "CONFLICT_FILES="
	for /f "tokens=2 delims= " %%I in ('git status --porcelain ^| findstr /r "^UU"') do (
		set "CONFLICT_FILES=!CONFLICT_FILES! %%I"
	)
	endlocal & set "CONFLICT_FILES=%CONFLICT_FILES%"

	if exist "%GITEXTENSIONS_EXE%" (
		echo [info] Launching GitExtensions mergeconflicts UI...
		"%GITEXTENSIONS_EXE%" mergeconflicts
	) else (
		echo [info] Resolve conflicts manually, then continue here.
	)

:WAIT_FOR_RESOLVE
	choice /c RA /m "Conflicts unresolved. R=Re-check, A=Abort merge"
	if errorlevel 2 (
		echo [info] Aborting merge...
		git merge --abort
		exit /b 1
	)

	git status --porcelain | findstr /r "^UU" >nul 2>&1
	if not errorlevel 1 (
		echo [info] Conflicts still present. Retry or abort.
		goto :WAIT_FOR_RESOLVE
	)

	echo [info] Conflicts resolved. Committing if needed...
	git diff --cached --exit-code >nul 2>&1
	if errorlevel 1 (
		git add . && git commit -m "Merged master. Conflicts resolved in:%CONFLICT_FILES%" || (
			echo Commit failed.& exit /b 1
		)
	)
) else (
	git diff --staged --exit-code >nul 2>&1
	if not errorlevel 1 (
		rem nothing to commit
	) else (
		git commit -m "Merged master (no conflicts)" || ( echo Commit failed.& exit /b 1 )
	)
)

:copying_binaries_from_master
rem --- bin is always copied (overwrite allowed) ---
xcopy "C:\git\GitHub\WiseTechGlobal\CargoWise\Bin\*" ".\Bin\" /E /I /Y
if %ERRORLEVEL% GEQ 8 exit /b %ERRORLEVEL%
robocopy "C:\git\GitHub\WiseTechGlobal\CargoWise\.paket" ".\.paket" /E /COPY:DAT /R:3 /W:5 /NJH /NJS
robocopy "C:\git\GitHub\WiseTechGlobal\CargoWise\paket-files" ".\paket-files" /E /COPY:DAT /R:3 /W:5 /NJH /NJS
robocopy "C:\git\GitHub\WiseTechGlobal\CargoWise\packages" ".\packages" /E /COPY:DAT /R:3 /W:5 /NJH /NJS
robocopy "C:\git\GitHub\WiseTechGlobal\CargoWise\.config" ".\.config" /E /COPY:DAT /R:3 /W:5 /NJH /NJS
rem robocopy "C:\git\GitHub\WiseTechGlobal\CargoWise\.idea" ".\.idea" /E /COPY:DAT /R:3 /W:5 /NJH /NJS

rem --- everything else: copy only newer files ---
if /I not "%~1"=="full" goto :end
robocopy "C:\git\GitHub\WiseTechGlobal\CargoWise\.github" ".\.github" /E /COPY:DAT /R:3 /W:5 /NJH /NJS
rem xcopy "C:\git\GitHub\WiseTechGlobal\CargoWise\.github" ".\.github" /E /I /Y

rem :copying_additional_binaries_from_master
rem xcopy "C:\git\GitHub\WiseTechGlobal\CargoWise\publish" ".\publish" /E /I /Y
rem xcopy "C:\git\GitHub\WiseTechGlobal\CargoWise\TestResults" ".\TestResults" /E /I /Y

:end
pause
