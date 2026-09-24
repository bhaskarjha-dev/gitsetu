# Full PowerShell installer/uninstaller E2E using a controlled local ZIP.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("gitsetu-ps-e2e-" + [Guid]::NewGuid().ToString("N"))
$installRoot = Join-Path $testRoot "install"
$sourceRoot = Join-Path $testRoot "source"
$buildRoot = Join-Path $testRoot "build"
$zipPath = Join-Path $testRoot "gitsetu-windows-test.zip"
$oldTestMode = $env:GITSETU_TEST_MODE
$oldInstallDir = $env:GITSETU_INSTALL_DIR

try {
    [void][IO.Directory]::CreateDirectory($sourceRoot)
    [void][IO.Directory]::CreateDirectory($buildRoot)
    Copy-Item (Join-Path $repoRoot "gitsetu") (Join-Path $sourceRoot "gitsetu")
    Copy-Item (Join-Path $repoRoot "lib") (Join-Path $sourceRoot "lib") -Recurse

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "packaging\windows\build_launcher.ps1") -OutDir $buildRoot
    if ($LASTEXITCODE -ne 0) { throw "Native launcher build failed" }
    Copy-Item (Join-Path $buildRoot "gitsetu.exe") (Join-Path $sourceRoot "gitsetu.exe")
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "packaging\windows\build_release_zip.ps1") -SourceDir $sourceRoot -OutFile $zipPath
    if ($LASTEXITCODE -ne 0) { throw "Windows release ZIP build failed" }

    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $env:GITSETU_TEST_MODE = "1"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "install.ps1") `
        -TestMode -TestArtifact $zipPath -TestArtifactSha256 $zipHash -TestInstallDir $installRoot
    if ($LASTEXITCODE -ne 0) { throw "PowerShell installer failed" }

    $cmdShim = Join-Path $installRoot "bin\gitsetu.cmd"
    $psShim = Join-Path $installRoot "bin\gitsetu.ps1"
    $altCmdShim = Join-Path $installRoot "bin\git-setu.cmd"
    foreach ($required in @($cmdShim, $psShim, $altCmdShim, (Join-Path $installRoot "install.marker"), (Join-Path $installRoot "current.txt"))) {
        if (-not (Test-Path -LiteralPath $required)) { throw "Installed file is missing: $required" }
    }

    $previousAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $cmdOutput = (& cmd.exe /d /c "`"$cmdShim`" --version" 2>&1 | Out-String)
        $cmdExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousAction }
    if ($cmdExit -ne 0 -or $cmdOutput -notmatch "gitsetu v1\.1\.0") { throw "CMD alias failed: $cmdOutput" }

    $previousAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $psOutput = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $psShim --version 2>&1 | Out-String)
        $psExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousAction }
    if ($psExit -ne 0 -or $psOutput -notmatch "gitsetu v1\.1\.0") { throw "PowerShell alias failed: $psOutput" }

    $env:GITSETU_INSTALL_DIR = $installRoot
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "uninstall.ps1") -Force
    if ($LASTEXITCODE -ne 0) { throw "PowerShell uninstaller failed" }
    if (Test-Path -LiteralPath $installRoot) { throw "Uninstaller left installation residue" }

    Write-Host "PowerShell installer E2E: PASS" -ForegroundColor Green
} finally {
    if ($null -eq $oldTestMode) { Remove-Item Env:GITSETU_TEST_MODE -ErrorAction SilentlyContinue } else { $env:GITSETU_TEST_MODE = $oldTestMode }
    if ($null -eq $oldInstallDir) { Remove-Item Env:GITSETU_INSTALL_DIR -ErrorAction SilentlyContinue } else { $env:GITSETU_INSTALL_DIR = $oldInstallDir }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
