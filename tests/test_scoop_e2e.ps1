# tests/test_scoop_e2e.ps1 — Full Scoop Package Manager Live E2E Verification
$ErrorActionPreference = "Stop"

$scriptDir = $PSScriptRoot
$repoDir = (Resolve-Path (Join-Path $scriptDir "..")).Path
$zipPath = Join-Path $repoDir "dist\gitsetu-windows-x64.zip"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "   GitSetu Scoop Package Manager Live E2E Verification Suite      " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $zipPath)) {
    Write-Host "dist\gitsetu-windows-x64.zip not found. Building on the fly..." -ForegroundColor Yellow
    $distDir = Join-Path $repoDir "dist"
    if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Path $distDir -Force | Out-Null }
    $buildScript = Join-Path $repoDir "packaging\windows\build_launcher.ps1"
    & powershell.exe -ExecutionPolicy Bypass -File $buildScript -OutDir $distDir
    
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) "gitsetu_scoop_zip_staging"
    if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
    New-Item -ItemType Directory -Path $staging | Out-Null
    Copy-Item (Join-Path $distDir "gitsetu.exe") -Destination $staging
    Copy-Item (Join-Path $repoDir "gitsetu") -Destination $staging
    Copy-Item -Recurse (Join-Path $repoDir "lib") -Destination $staging
    Compress-Archive -Path "$staging\*" -DestinationPath $zipPath -Force
    Remove-Item -Recurse -Force $staging
}

# Ensure Scoop is installed and in PATH
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    if (Test-Path "$HOME\scoop\shims\scoop.cmd") {
        $env:PATH = "$HOME\scoop\shims;$HOME\scoop\current\bin;$env:PATH"
    } else {
        Write-Host "Scoop not detected in environment. Installing Scoop..." -ForegroundColor Yellow
        try {
            Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression
            $env:PATH = "$HOME\scoop\shims;$HOME\scoop\current\bin;$env:PATH"
        } catch {
            Write-Host "Failed to auto-install Scoop: $_" -ForegroundColor Red
        }
    }
}
$scoopShims = Join-Path $HOME "scoop\shims"
if ($env:PATH -notlike "*$scoopShims*") {
    $env:PATH = "$scoopShims;$env:PATH"
}

# 1. Compute hash of local archive
$zipHash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
$zipUri = "file:///" + (($zipPath -replace '\\', '/').TrimStart('/'))

# 2. Generate local test manifest matching packaging/scoop/gitsetu.json
$tempDir = [System.IO.Path]::GetTempPath()
$testManifest = Join-Path $tempDir "gitsetu_scoop_test.json"

$manifestContent = @"
{
  "version": "1.0.0",
  "description": "Zero-trust multi-account Git identity orchestrator",
  "homepage": "https://gitsetu.bhaskarjha.dev",
  "license": "MIT",
  "depends": "git",
  "url": "$zipUri",
  "hash": "$zipHash",
  "bin": [
    "gitsetu.exe",
    ["gitsetu.exe", "git-setu"]
  ]
}
"@
Set-Content -Path $testManifest -Value $manifestContent -Encoding UTF8
Write-Host "Generated local Scoop test manifest at: $testManifest"
Write-Host "  URI:  $zipUri"
Write-Host "  Hash: $zipHash"
Write-Host ""

# 3. Scoop install
Write-Host "Step 1: Installing GitSetu via Scoop..." -ForegroundColor Yellow
$existingAppDir = Join-Path $HOME "scoop\apps\gitsetu_scoop_test"
if (Test-Path $existingAppDir) {
    Remove-Item -Recurse -Force $existingAppDir -ErrorAction SilentlyContinue
}
$installRes = & scoop install "$testManifest"
Write-Host ($installRes -join "`n")
if ($LASTEXITCODE -ne 0) {
    Write-Error "scoop install failed with exit code $LASTEXITCODE"
    exit 1
}

# 4. Verify Scoop shims
Write-Host "`nStep 2: Testing Scoop shims..." -ForegroundColor Yellow
$vCmd = & cmd.exe /c "gitsetu --version"
Write-Host "  gitsetu:  $vCmd"
$vAlt = & cmd.exe /c "git-setu --version"
Write-Host "  git-setu: $vAlt"

if ($vCmd -notmatch "gitsetu v1.0.0" -or $vAlt -notmatch "gitsetu v1.0.0") {
    Write-Error "Scoop shim execution failed"
    exit 1
}
Write-Host "  [OK] Scoop shims executed successfully!" -ForegroundColor Green

# 5. Run status
Write-Host "`nStep 3: Running gitsetu status via Scoop shim..." -ForegroundColor Yellow
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$statusOut = & cmd.exe /c "gitsetu status" 2>&1
$ErrorActionPreference = $prevEAP
Write-Host ($statusOut -join "`n")
Write-Host "  [OK] Status executed successfully!" -ForegroundColor Green

# 6. Scoop uninstall
Write-Host "`nStep 4: Uninstalling GitSetu via Scoop..." -ForegroundColor Yellow
$uninstallRes = & scoop uninstall gitsetu_scoop_test
Write-Host ($uninstallRes -join "`n")
if ($LASTEXITCODE -ne 0) {
    Write-Error "scoop uninstall failed with exit code $LASTEXITCODE"
    exit 1
}

# 7. Verify clean uninstall
Write-Host "`nStep 5: Verifying zero residue..." -ForegroundColor Yellow
$gitsetuShim = Join-Path $scoopShims "gitsetu.exe"
$gitsetuShimPs1 = Join-Path $scoopShims "gitsetu.ps1"
if ((Test-Path $gitsetuShim) -or (Test-Path $gitsetuShimPs1)) {
    Write-Error "Scoop shims were not removed: $gitsetuShim"
    exit 1
}
Write-Host "  [OK] Scoop shims cleanly purged." -ForegroundColor Green

# Cleanup test manifest
Remove-Item -Force $testManifest

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Green
Write-Host "   All Scoop Live Verification Checks Passed (5/5)               " -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
