# GitSetu Windows PowerShell Uninstaller
#
# Removes %LOCALAPPDATA%\gitsetu and cleans the user PATH.
#
# Usage:
#   irm https://raw.githubusercontent.com/bhaskarjha-dev/gitsetu/main/uninstall.ps1 | iex
#   irm https://gitsetu.bhaskarjha.dev/uninstall.ps1 | iex

param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Write-StyledHeader {
    Write-Host ""
    Write-Host "--- Uninstalling GitSetu for Windows ---" -ForegroundColor Cyan
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

Write-StyledHeader

$rootDir = Join-Path $env:LOCALAPPDATA "gitsetu"
$binDir = Join-Path $rootDir "bin"

# 1. Teardown Notice
Write-StyledWarning "Wait! If you have active GitSetu configurations in your global ~/.gitconfig,"
Write-Host "    you should run 'gitsetu teardown --deep' before uninstalling to remove them cleanly." -ForegroundColor White
Write-Host ""

$isNonInteractive = $Force -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected -or ($env:CI -eq "true") -or ($env:GITSETU_TEST -eq "true")

if (-not $isNonInteractive) {
    $confirmation = Read-Host "  Are you sure you want to remove GitSetu executables? [y/N]"
    if ($confirmation -notmatch "^[Yy]$") {
        Write-Host "  Uninstallation aborted." -ForegroundColor Yellow
        exit 0
    }
}

# 2. Remove files
if (Test-Path $rootDir) {
    Write-StyledInfo "Removing GitSetu files from $rootDir..."
    try {
        Remove-Item -Recurse -Force $rootDir
        Write-StyledSuccess "GitSetu directory removed."
    } catch {
        Write-Host "  [ERROR] Could not completely remove $rootDir (files may be in use)." -ForegroundColor Red
    }
}

# 3. Clean User PATH
$userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($userPath) {
    $normalizedBinDir = $binDir.TrimEnd('\')
    $parts = $userPath.Split(';') | Where-Object {
        $_ -and ($_.TrimEnd('\') -ne $normalizedBinDir)
    }
    $newPath = $parts -join ';'
    if ($newPath -ne $userPath) {
        Write-StyledInfo "Removing $binDir from User PATH..."
        if (-not $env:GITSETU_TEST) {
            [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        }
        Write-StyledSuccess "User PATH updated."
    }
}

Write-Host ""
Write-StyledSuccess "GitSetu has been successfully removed from Windows."
Write-Host "  (Note: Any generated SSH keys in ~/.ssh/ were preserved for safety)" -ForegroundColor Gray
Write-Host ""
