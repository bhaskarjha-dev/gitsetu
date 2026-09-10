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

if not exist "%WSB_FILE%" (
    echo [ERROR] %WSB_FILE% not found.
    pause
    exit /b 1
)

echo Launching Windows Sandbox with:
echo   %WSB_FILE%
echo.
start "" "%SANDBOX_EXE%" "%WSB_FILE%"

echo.
echo Windows Sandbox has been started!
echo The sandbox runs in total isolation from your host system.
if "%~1" neq "--no-pause" pause
