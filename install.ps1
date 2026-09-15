# GitSetu Windows PowerShell Installer
#
# Clones or updates GitSetu to %LOCALAPPDATA%\gitsetu\share
# and configures executable shims in %LOCALAPPDATA%\gitsetu\bin
#
# Usage:
#   irm https://raw.githubusercontent.com/bhaskarjha-dev/gitsetu/main/install.ps1 | iex
#   irm https://gitsetu.bhaskarjha.dev/install.ps1 | iex

$ErrorActionPreference = "Stop"

function Write-StyledHeader {
    Write-Host ""
    Write-Host "--- Installing GitSetu for Windows ---" -ForegroundColor Cyan
    Write-Host ""
}

function Write-StyledSuccess {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-StyledInfo {
    param([string]$Message)
    Write-Host "  [i]  $Message" -ForegroundColor Gray
}

function Write-StyledWarning {
    param([string]$Message)
    Write-Host "  [!]  $Message" -ForegroundColor Yellow
}

function Write-StyledError {
    param([string]$Message)
    Write-Host "  [ERROR] $Message" -ForegroundColor Red
}

Write-StyledHeader

# 1. Prerequisite: Check for Git
$gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
if (-not $gitCmd) {
    Write-StyledError "Git is required to install GitSetu, but was not found in PATH."
    Write-Host "  Please install Git for Windows: https://git-scm.com/download/win" -ForegroundColor Yellow
    exit 1
}

# 2. Prerequisite: Check for Git Bash (exclude WSL System32\bash.exe)
function Find-GitBash {
    param([string]$GitExePath)

    # 1. Derive from git.exe path
    if ($GitExePath) {
        $gitDir = Split-Path (Split-Path $GitExePath -Parent) -Parent
        $candidates = @(
            (Join-Path $gitDir "bin\bash.exe"),
            (Join-Path $gitDir "usr\bin\bash.exe")
        )
        foreach ($c in $candidates) {
            if (Test-Path $c) { return $c }
        }
    }

    # 2. Known installation locations
    $knownLocations = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "$env:ProgramFiles\Git\usr\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\usr\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\usr\bin\bash.exe"
    )
    foreach ($loc in $knownLocations) {
        if (Test-Path $loc) { return $loc }
    }

    # 3. Check PATH bash.exe, strictly excluding System32 and SysWOW64 (WSL)
    $bashCmd = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($bashCmd -and ($bashCmd.Source -notmatch "(?i)System32|SysWOW64")) {
        return $bashCmd.Source
    }

    return $null
}

$bashExe = Find-GitBash -GitExePath $gitCmd.Source
if (-not $bashExe) {
    Write-StyledError "Git Bash (bash.exe) is required to run GitSetu, but was not found."
    Write-Host "  Please ensure Git for Windows is installed with Git Bash: https://git-scm.com/download/win" -ForegroundColor Yellow
    exit 1
}

# 3. Directories setup
$repoUrl = "https://github.com/bhaskarjha-dev/gitsetu.git"
if ($env:GITSETU_REPO_URL) {
    $repoUrl = $env:GITSETU_REPO_URL
}
$rootDir = Join-Path $env:LOCALAPPDATA "gitsetu"
if ($env:GITSETU_INSTALL_DIR) {
    $rootDir = $env:GITSETU_INSTALL_DIR
}
$shareDir = Join-Path $rootDir "share"
$binDir = Join-Path $rootDir "bin"

New-Item -ItemType Directory -Force -Path $binDir | Out-Null
New-Item -ItemType Directory -Force -Path $rootDir | Out-Null

# 4. Clone or Update
if (Test-Path (Join-Path $shareDir ".git")) {
    Write-StyledInfo "Updating existing GitSetu installation in $shareDir..."
    Push-Location $shareDir
    try {
        & git fetch --quiet origin
        if ($LASTEXITCODE -ne 0) { throw "git fetch failed with exit code $LASTEXITCODE" }
        & git reset --quiet --hard origin/main
        if ($LASTEXITCODE -ne 0) { throw "git reset failed with exit code $LASTEXITCODE" }
    } catch {
        Write-StyledError "Failed to update existing checkout from origin."
        Pop-Location
        exit 1
    }
    Pop-Location
    Write-StyledSuccess "Repository updated to latest origin/main."
} else {
    if (Test-Path $shareDir) {
        Remove-Item -Recurse -Force $shareDir
    }
    Write-StyledInfo "Cloning GitSetu into $shareDir..."
    try {
        & git clone --quiet $repoUrl $shareDir
        if ($LASTEXITCODE -ne 0) { throw "git clone failed with exit code $LASTEXITCODE" }
    } catch {
        Write-StyledError "Failed to clone $repoUrl. Check your internet connection and GitHub access."
        exit 1
    }
    Write-StyledSuccess "Repository cloned successfully."
}

# 5. Generate Shims (CMD and PowerShell)
Write-StyledInfo "Configuring Windows command shims in $binDir..."

# 5a. gitsetu.cmd (for Command Prompt and general shell execution)
$cmdShim = @'
@echo off
setlocal
REM Look for Git for Windows bash explicitly; do NOT use System32\bash.exe
if exist "%ProgramFiles%\Git\bin\bash.exe" (
    "%ProgramFiles%\Git\bin\bash.exe" "%~dp0..\share\gitsetu" %*
    exit /b
)
if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" (
    "%ProgramFiles(x86)%\Git\bin\bash.exe" "%~dp0..\share\gitsetu" %*
    exit /b
)
if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" (
    "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" "%~dp0..\share\gitsetu" %*
    exit /b
)
for /f "tokens=*" %%i in ('where git.exe 2^>nul') do (
    if exist "%%~dpi..\bin\bash.exe" (
        "%%~dpi..\bin\bash.exe" "%~dp0..\share\gitsetu" %*
        exit /b
    )
    if exist "%%~dpi..\usr\bin\bash.exe" (
        "%%~dpi..\usr\bin\bash.exe" "%~dp0..\share\gitsetu" %*
        exit /b
    )
)
for /f "tokens=*" %%i in ('where bash.exe 2^>nul') do (
    echo "%%i" | findstr /i "System32 SysWOW64" >nul
    if errorlevel 1 (
        "%%i" "%~dp0..\share\gitsetu" %*
        exit /b
    )
)
echo Error: Git Bash is required to run GitSetu. Please install Git for Windows: https://git-scm.com >&2
exit /b 1
'@

Set-Content -Path (Join-Path $binDir "gitsetu.cmd") -Value $cmdShim -Encoding ASCII
Set-Content -Path (Join-Path $binDir "git-setu.cmd") -Value $cmdShim -Encoding ASCII

# 5b. gitsetu.ps1 (for native PowerShell execution with parameter forwarding)
$psShim = @'
$ErrorActionPreference = "Stop"
$bash = $null
$gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
if ($gitCmd) {
    $gitDir = Split-Path (Split-Path $gitCmd.Source -Parent) -Parent
    $candidates = @(
        (Join-Path $gitDir "bin\bash.exe"),
        (Join-Path $gitDir "usr\bin\bash.exe")
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $bash = $c; break }
    }
}
if (-not $bash) {
    $knownLocations = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "$env:ProgramFiles\Git\usr\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\usr\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\usr\bin\bash.exe"
    )
    foreach ($loc in $knownLocations) {
        if (Test-Path $loc) { $bash = $loc; break }
    }
}
if (-not $bash) {
    $bashCmd = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($bashCmd -and ($bashCmd.Source -notmatch "(?i)System32|SysWOW64")) {
        $bash = $bashCmd.Source
    }
}
if (-not $bash) {
    Write-Error "Git Bash is required to run GitSetu. Please install Git for Windows: https://git-scm.com"
    exit 1
}
$scriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "share\gitsetu") -replace '\\', '/'
& $bash "$scriptPath" @args
exit $LASTEXITCODE
'@

Set-Content -Path (Join-Path $binDir "gitsetu.ps1") -Value $psShim -Encoding ASCII
Set-Content -Path (Join-Path $binDir "git-setu.ps1") -Value $psShim -Encoding ASCII

Write-StyledSuccess "Executable shims created (gitsetu and git-setu)."

# 6. Ensure binDir is in User PATH
$userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
$pathParts = @()
if ($userPath) {
    $pathParts = $userPath.Split(';')
}
$normalizedBinDir = (Resolve-Path $binDir).Path

$found = $false
foreach ($p in $pathParts) {
    if ($p -and ((Resolve-Path $p -ErrorAction SilentlyContinue).Path -eq $normalizedBinDir)) {
        $found = $true
        break
    }
}

if (-not $found) {
    Write-StyledInfo "Adding $binDir to User PATH..."
    $newPath = $binDir
    if ($userPath) {
        $newPath = "$userPath;$binDir"
    }
    if (-not $env:GITSETU_TEST) {
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
    }
    Write-StyledSuccess "User PATH updated permanently."
}

# Update current process PATH so gitsetu works immediately in this terminal
if ($env:PATH -notlike "*$binDir*") {
    $env:PATH = "$binDir;$env:PATH"
}

Write-Host ""
Write-StyledSuccess "GitSetu successfully installed on Windows!"
Write-Host ""
Write-Host "  You can now run 'gitsetu setup' or 'git setu setup' directly in:" -ForegroundColor White
Write-Host "    - PowerShell" -ForegroundColor Cyan
Write-Host "    - Command Prompt (cmd.exe)" -ForegroundColor Cyan
Write-Host "    - Windows Terminal" -ForegroundColor Cyan
Write-Host "    - Git Bash" -ForegroundColor Cyan
Write-Host ""
Write-Host "  To get started:" -ForegroundColor Yellow
Write-Host "    gitsetu setup" -ForegroundColor White
Write-Host ""
