@echo off
SETLOCAL

for /f "delims=" %%R in ('call "%~dp0resolve-branch-root.cmd"') do (
	set "WTGBranchRoot=%%R"
)

cd "%WTGBranchRoot%"
dotnet tool run AssemblyMetaDataExtractor -- Build.xml

ENDLOCAL
pauses