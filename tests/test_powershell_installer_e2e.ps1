# tests/test_powershell_installer_e2e.ps1 — Full E2E test for PowerShell installer & uninstaller
$ErrorActionPreference = "Stop"

$scriptDir = $PSScriptRoot
$repoDir = (Resolve-Path (Join-Path $scriptDir "..")).Path

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "   GitSetu PowerShell Installer & Uninstaller Verification Suite  " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host ""

$testDir = Join-Path $env:LOCALAPPDATA "GitSetu_Test"
if (Test-Path $testDir) {
    Remove-Item -Recurse -Force $testDir
}

$env:GITSETU_INSTALL_DIR = $testDir
$env:GITSETU_REPO_URL = $repoDir
$env:GITSETU_TEST = "true"

$binDir = Join-Path $testDir "bin"
$cmdShim = Join-Path $binDir "gitsetu.cmd"
$psShim = Join-Path $binDir "gitsetu.ps1"

# 1. Run install.ps1
Write-Host "Step 1: Running install.ps1..." -ForegroundColor Yellow
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoDir "install.ps1")
if ($LASTEXITCODE -ne 0) {
    Write-Error "install.ps1 failed with exit code $LASTEXITCODE"
    exit 1
}

# 2. Check installed files
Write-Host "Step 2: Verifying installed structure..." -ForegroundColor Yellow
if (-not (Test-Path $cmdShim)) {
    Write-Error "gitsetu.cmd shim missing at $cmdShim"
    exit 1
}
if (-not (Test-Path $psShim)) {
    Write-Error "gitsetu.ps1 shim missing at $psShim"
    exit 1
}
if (-not (Test-Path (Join-Path $testDir "share\gitsetu"))) {
    Write-Error "GitSetu source missing at $testDir\share\gitsetu"
    exit 1
}
Write-Host "  [OK] Shims and repository structure successfully created." -ForegroundColor Green

# 3. Test gitsetu.cmd
Write-Host "Step 3: Testing gitsetu.cmd shim..." -ForegroundColor Yellow
$cmdOut = & cmd.exe /c "`"$cmdShim`" --version"
Write-Host "  CMD output: $cmdOut"
if ($cmdOut -notmatch "gitsetu v1.0.0") {
    Write-Error "gitsetu.cmd output did not match 'gitsetu v1.0.0'"
    exit 1
}
Write-Host "  [OK] gitsetu.cmd executed successfully!" -ForegroundColor Green

# 4. Test gitsetu.ps1
Write-Host "Step 4: Testing gitsetu.ps1 shim..." -ForegroundColor Yellow
$psOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$psShim" --version
Write-Host "  PowerShell output: $psOut"
if ($psOut -notmatch "gitsetu v1.0.0") {
    Write-Error "gitsetu.ps1 output did not match 'gitsetu v1.0.0'"
    exit 1
}
Write-Host "  [OK] gitsetu.ps1 executed successfully!" -ForegroundColor Green

# 5. Run uninstall.ps1 -Force
Write-Host "Step 5: Running uninstall.ps1 -Force..." -ForegroundColor Yellow
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoDir "uninstall.ps1") -Force
if ($LASTEXITCODE -ne 0) {
    Write-Error "uninstall.ps1 failed with exit code $LASTEXITCODE"
    exit 1
}

# 6. Verify zero residue
Write-Host "Step 6: Verifying complete removal..." -ForegroundColor Yellow
if (Test-Path $testDir) {
    Write-Error "Installation directory was not completely purged: $testDir"
    exit 1
}
Write-Host "  [OK] Zero directory residue." -ForegroundColor Green

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Green
Write-Host "   All PowerShell Installer & Uninstaller Checks Passed (6/6)     " -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
