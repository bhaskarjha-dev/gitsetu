# tests/test_gh_extension_e2e.ps1 — GitHub CLI Extension E2E lifecycle test
$ErrorActionPreference = "Continue"

# Ensure PATH has GitHub CLI and current gitsetu
$machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$env:Path = "$repoRoot;$machinePath;$userPath;$env:Path"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Warning "gh CLI not found on PATH. Skipping gh extension E2E test."
    exit 0
}

$env:GH_TOKEN = "ghp_dummytokenfortestinglocalextension123456"

$passed = 0
$failed = 0

function Pass-Test($name) {
    Write-Host "  [PASS] $name" -ForegroundColor Green
    $script:passed++
}

function Fail-Test($name, $reason) {
    Write-Host "  [FAIL] ${name}: $reason" -ForegroundColor Red
    $script:failed++
}

Write-Host "=== Running tests/test_gh_extension_e2e.ps1 ==="

$testBase = Join-Path $env:TEMP "gitsetu-gh-e2e-$([System.Guid]::NewGuid().ToString('N'))"
$extDir = Join-Path $testBase "gh-gitsetu"

try {
    New-Item -ItemType Directory -Path $extDir -Force | Out-Null
    Copy-Item "$repoRoot\packaging\gh-extension\gh-gitsetu" "$extDir\gh-gitsetu"

    Push-Location $extDir
    git init -q
    git config user.name "GitSetu Test"
    git config user.email "test@gitsetu.dev"
    git add .
    git commit -q -m "feat: initial gh-gitsetu"

    # 1. Install extension
    gh extension install . 2>&1 | Out-Null
    $extList = (gh extension list | Out-String)
    if ($extList -match "gitsetu") {
        Pass-Test "gh extension install ."
    } else {
        Fail-Test "gh extension install ." "gitsetu not found in gh extension list"
    }

    # 2. Test --version
    $ver = (gh gitsetu --version 2>&1 | Out-String)
    if ($ver -match "gitsetu v1\.0\.0") {
        Pass-Test "gh gitsetu --version"
    } else {
        Fail-Test "gh gitsetu --version" "Unexpected version output: $ver"
    }

    # 3. Test status
    $statusOut = (gh gitsetu status 2>&1 | Out-String)
    if ($statusOut -match "Active Identity" -or $statusOut -match "gitsetu v1\.0\.0") {
        Pass-Test "gh gitsetu status"
    } else {
        Fail-Test "gh gitsetu status" "Status command failed: $statusOut"
    }

    # 4. Test remove
    gh extension remove gitsetu 2>&1 | Out-Null
    $extListAfter = (gh extension list | Out-String)
    if ($extListAfter -notmatch "gitsetu") {
        Pass-Test "gh extension remove gitsetu"
    } else {
        Fail-Test "gh extension remove gitsetu" "Extension still listed after removal: $extListAfter"
    }

    Pop-Location
} finally {
    if (Test-Path $testBase) {
        Remove-Item -Recurse -Force $testBase -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "GitHub CLI E2E tests: $passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
exit 0
