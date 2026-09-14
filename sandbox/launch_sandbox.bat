@echo off
setlocal enabledelayedexpansion

echo =======================================================
echo      GitSetu Windows Sandbox Test Harness Launcher
echo =======================================================
echo.

set "SANDBOX_DIR=%~dp0"
if "%SANDBOX_DIR:~-1%"=="\" set "SANDBOX_DIR=%SANDBOX_DIR:~0,-1%"
for %%I in ("%SANDBOX_DIR%\..") do set "ROOT_DIR=%%~fI"

:: Check if Windows Sandbox is installed
where WindowsSandbox.exe >nul 2>&1
if %ERRORLEVEL% neq 0 (
    if not exist "%SystemRoot%\System32\WindowsSandbox.exe" (
        echo [ERROR] Windows Sandbox is not enabled or not found on this system.
        echo To enable Windows Sandbox:
        echo   1. Open 'Turn Windows features on or off'
        echo   2. Check 'Windows Sandbox'
        echo   3. Click OK and restart your PC
        echo.
        pause
        exit /b 1
    )
    set "SANDBOX_EXE=%SystemRoot%\System32\WindowsSandbox.exe"
) else (
    set "SANDBOX_EXE=WindowsSandbox.exe"
)

:: Check if Git is installed on host
if not exist "C:\Program Files\Git\bin\bash.exe" (
    echo [WARNING] Git for Windows was not found at 'C:\Program Files\Git'.
    echo Windows Sandbox maps this folder to provide zero-download offline Git/Bash.
    echo Please verify Git installation path.
    echo.
)

set "WSB_FILE=%SANDBOX_DIR%\gitsetu_test.wsb"

:: Generate WSB config with dynamic paths for portability
set "WSB_GENERATED=%TEMP%\gitsetu_test_dynamic.wsb"
set "RESULTS_DIR=%ROOT_DIR%\..\sandbox_results"
if not exist "%RESULTS_DIR%" mkdir "%RESULTS_DIR%"

(
echo ^<Configuration^>
echo   ^<VGpu^>Disable^</VGpu^>
echo   ^<Networking^>Default^</Networking^>
echo   ^<MappedFolders^>
echo     ^<MappedFolder^>
echo       ^<HostFolder^>%ROOT_DIR%^</HostFolder^>
echo       ^<SandboxFolder^>C:\gitsetu_source^</SandboxFolder^>
echo       ^<ReadOnly^>true^</ReadOnly^>
echo     ^</MappedFolder^>
echo     ^<MappedFolder^>
echo       ^<HostFolder^>C:\Program Files\Git^</HostFolder^>
echo       ^<SandboxFolder^>C:\Git_Host^</SandboxFolder^>
echo       ^<ReadOnly^>true^</ReadOnly^>
echo     ^</MappedFolder^>
echo     ^<MappedFolder^>
echo       ^<HostFolder^>%RESULTS_DIR%^</HostFolder^>
echo       ^<SandboxFolder^>C:\results^</SandboxFolder^>
echo       ^<ReadOnly^>false^</ReadOnly^>
echo     ^</MappedFolder^>
echo   ^</MappedFolders^>
echo   ^<LogonCommand^>
echo     ^<Command^>powershell.exe -ExecutionPolicy Bypass -Command "^&amp; { for ($i=0; $i -lt 60; $i++^) { if (Test-Path 'C:\gitsetu_source\sandbox\bootstrap.ps1'^) { ^&amp; 'C:\gitsetu_source\sandbox\bootstrap.ps1'; break } if (Test-Path 'C:\Users\WDAGUtilityAccount\Desktop\gitsetu\sandbox\bootstrap.ps1'^) { ^&amp; 'C:\Users\WDAGUtilityAccount\Desktop\gitsetu\sandbox\bootstrap.ps1'; break } Start-Sleep -Seconds 1 } }"^</Command^>
echo   ^</LogonCommand^>
echo ^</Configuration^>
) > "%WSB_GENERATED%"

echo Launching Windows Sandbox with:
echo   Source: %ROOT_DIR%
echo   Results: %RESULTS_DIR%
echo.
start "" "%SANDBOX_EXE%" "%WSB_GENERATED%"

echo.
echo Windows Sandbox has been started!
echo The sandbox runs in total isolation from your host system.
if "%~1" neq "--no-pause" pause
