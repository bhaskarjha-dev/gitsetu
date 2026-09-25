# Full PowerShell installer/uninstaller E2E using a controlled local ZIP.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("gitsetu-ps-e2e-" + [Guid]::NewGuid().ToString("N"))
$installRoot = Join-Path $testRoot "install"
$sourceRoot = Join-Path $testRoot "source"
$buildRoot = Join-Path $testRoot "build"
$zipPath = Join-Path $testRoot "gitsetu-windows-test.zip"
$trustedPowerShell = $null
try { $trustedPowerShell = (Get-Process -Id $PID).Path } catch { $trustedPowerShell = $null }
if ([string]::IsNullOrWhiteSpace($trustedPowerShell)) {
    $trustedPowerShell = Join-Path $PSHOME "powershell.exe"
}
$trustedPowerShell = [IO.Path]::GetFullPath($trustedPowerShell)
if (-not (Test-Path -LiteralPath $trustedPowerShell -PathType Leaf)) {
    throw "A trusted absolute PowerShell executable is required for this test"
}
$cmdExe = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)) "System32\cmd.exe"
$oldTestMode = $env:GITSETU_TEST_MODE
$oldInstallDir = $env:GITSETU_INSTALL_DIR
$oldPath = $env:Path
$oldHostileMarker = $env:GITSETU_HOSTILE_MARKER

function Assert-LauncherSidecar([string]$Directory) {
    $launcher = Join-Path $Directory "gitsetu.exe"
    $sidecar = "$launcher.sha256"
    if (-not (Test-Path -LiteralPath $sidecar -PathType Leaf)) {
        throw "Launcher checksum sidecar is missing: $sidecar"
    }
    $lines = [IO.File]::ReadAllLines($sidecar)
    if ($lines.Count -ne 1 -or $lines[0] -notmatch '^([0-9a-f]{64})  gitsetu\.exe$') {
        throw "Launcher checksum sidecar has the wrong digest or filename: $sidecar"
    }
    $expectedDigest = (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($lines[0] -notmatch "^$expectedDigest  gitsetu\.exe$") {
        throw "Launcher checksum sidecar digest does not match: $sidecar"
    }
    $misspelledSidecar = Join-Path $Directory "gitsetsu.exe.sha256"
    if (Test-Path -LiteralPath $misspelledSidecar) {
        throw "Misspelled launcher checksum sidecar was generated: $misspelledSidecar"
    }
}

try {
    [void][IO.Directory]::CreateDirectory($sourceRoot)
    [void][IO.Directory]::CreateDirectory($buildRoot)
    Copy-Item (Join-Path $repoRoot "gitsetu") (Join-Path $sourceRoot "gitsetu")
    Copy-Item (Join-Path $repoRoot "lib") (Join-Path $sourceRoot "lib") -Recurse

    & $trustedPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "packaging\windows\build_launcher.ps1") -OutDir $buildRoot
    if ($LASTEXITCODE -ne 0) { throw "Native launcher build failed" }
    Assert-LauncherSidecar $buildRoot
    Copy-Item (Join-Path $buildRoot "gitsetu.exe") (Join-Path $sourceRoot "gitsetu.exe")
    & $trustedPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "packaging\windows\build_release_zip.ps1") -SourceDir $sourceRoot -OutFile $zipPath
    if ($LASTEXITCODE -ne 0) { throw "Windows release ZIP build failed" }

    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $env:GITSETU_TEST_MODE = "1"
    & $trustedPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "install.ps1") `
        -TestMode -TestArtifact $zipPath -TestArtifactSha256 $zipHash -TestInstallDir $installRoot
    if ($LASTEXITCODE -ne 0) { throw "PowerShell installer failed" }

    $cmdShim = Join-Path $installRoot "bin\gitsetu.cmd"
    $psShim = Join-Path $installRoot "bin\gitsetu.ps1"
    $altCmdShim = Join-Path $installRoot "bin\git-setu.cmd"
    foreach ($required in @($cmdShim, $psShim, $altCmdShim, (Join-Path $installRoot "install.marker"), (Join-Path $installRoot "current.txt"))) {
        if (-not (Test-Path -LiteralPath $required)) { throw "Installed file is missing: $required" }
    }

    # The CMD shim must not fall back to a caller-controlled powershell.exe.
    $cmdText = [IO.File]::ReadAllText($cmdShim)
    if ($cmdText -match '(?im)^\s*powershell(?:\.exe)?(?:\s|$)') {
        throw "CMD shim invokes an unqualified PowerShell executable"
    }
    if ($cmdText -notmatch '(?m)^"%~dp0\.\.\\releases\\[^"]+\\gitsetu\.exe" %\*') {
        throw "CMD shim does not invoke the installed native launcher directly"
    }

    # Build a small real PE that records execution. Invalid or batch-file
    # fixtures would not prove that CMD resolved the planted executable.
    $hostileBuildRoot = Join-Path $testRoot "hostile-build"
    $hostileSource = Join-Path $hostileBuildRoot "HostilePowerShell.cs"
    $hostileExe = Join-Path $hostileBuildRoot "powershell.exe"
    [void][IO.Directory]::CreateDirectory($hostileBuildRoot)
    [IO.File]::WriteAllText($hostileSource, @'
using System;
using System.IO;

public static class HostilePowerShell {
    public static int Main(string[] args) {
        string marker = Environment.GetEnvironmentVariable("GITSETU_HOSTILE_MARKER");
        if (!String.IsNullOrEmpty(marker)) {
            File.AppendAllText(marker, "executed" + Environment.NewLine);
        }
        Console.Error.WriteLine("HOSTILE_POWERSHELL_EXECUTED");
        return 77;
    }
}
'@, (New-Object Text.UTF8Encoding($false)))
    $windowsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    $hostileCsc = $null
    foreach ($candidate in @(
        (Join-Path $windowsRoot "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
        (Join-Path $windowsRoot "Microsoft.NET\Framework\v4.0.30319\csc.exe")
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $hostileCsc = [IO.Path]::GetFullPath($candidate)
            break
        }
    }
    if (-not $hostileCsc) { throw "A trusted C# compiler is required for the hostile shim fixture" }
    & $hostileCsc /nologo /target:exe "/out:$hostileExe" $hostileSource
    if ($LASTEXITCODE -ne 0) { throw "Hostile PowerShell fixture compilation failed" }

    $hostileCurrent = Join-Path $testRoot "hostile-current"
    $hostilePath = Join-Path $testRoot "hostile-path"
    [void][IO.Directory]::CreateDirectory($hostileCurrent)
    [void][IO.Directory]::CreateDirectory($hostilePath)
    Copy-Item -LiteralPath $hostileExe -Destination (Join-Path $hostileCurrent "powershell.exe")
    Copy-Item -LiteralPath $hostileExe -Destination (Join-Path $hostilePath "powershell.exe")
    $hostileMarker = Join-Path $testRoot "hostile-powershell.marker"
    $env:GITSETU_HOSTILE_MARKER = $hostileMarker
    $invokeWithHostileFixture = {
        param([string]$WorkingDirectory, [string]$PathPrefix)
        Remove-Item -LiteralPath $hostileMarker -Force -ErrorAction SilentlyContinue
        Push-Location -LiteralPath $WorkingDirectory
        $savedPath = $env:Path
        $savedAction = $ErrorActionPreference
        $output = ""
        $exitCode = 1
        try {
            $env:Path = "$PathPrefix;$savedPath"
            $ErrorActionPreference = "Continue"
            $output = (& $cmdExe /d /c "`"$cmdShim`" --version" 2>&1 | Out-String)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedAction
            $env:Path = $savedPath
            Pop-Location
        }
        [PSCustomObject]@{
            ExitCode = $exitCode
            Output = $output
            MarkerExists = (Test-Path -LiteralPath $hostileMarker)
        }
    }
    $result = & $invokeWithHostileFixture $hostileCurrent $hostileCurrent
    if ($result.ExitCode -ne 0 -or $result.Output -notmatch "gitsetu v1\.1\.0" -or $result.MarkerExists) {
        throw "CMD shim executed the current-directory PowerShell fixture: $($result.Output)"
    }
    $result = & $invokeWithHostileFixture $testRoot $hostilePath
    if ($result.ExitCode -ne 0 -or $result.Output -notmatch "gitsetu v1\.1\.0" -or $result.MarkerExists) {
        throw "CMD shim executed the PATH PowerShell fixture: $($result.Output)"
    }

    $previousAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $cmdOutput = (& $cmdExe /d /c "`"$cmdShim`" --version" 2>&1 | Out-String)
        $cmdExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousAction }
    if ($cmdExit -ne 0 -or $cmdOutput -notmatch "gitsetu v1\.1\.0") { throw "CMD alias failed: $cmdOutput" }

    $previousAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $psOutput = (& $trustedPowerShell -NoProfile -ExecutionPolicy Bypass -File $psShim --version 2>&1 | Out-String)
        $psExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousAction }
    if ($psExit -ne 0 -or $psOutput -notmatch "gitsetu v1\.1\.0") { throw "PowerShell alias failed: $psOutput" }

    $env:GITSETU_INSTALL_DIR = $installRoot
    & $trustedPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "uninstall.ps1") -Force
    if ($LASTEXITCODE -ne 0) { throw "PowerShell uninstaller failed" }
    if (Test-Path -LiteralPath $installRoot) { throw "Uninstaller left installation residue" }

    Write-Host "PowerShell installer E2E: PASS" -ForegroundColor Green
} finally {
    if ($null -eq $oldTestMode) { Remove-Item Env:GITSETU_TEST_MODE -ErrorAction SilentlyContinue } else { $env:GITSETU_TEST_MODE = $oldTestMode }
    if ($null -eq $oldInstallDir) { Remove-Item Env:GITSETU_INSTALL_DIR -ErrorAction SilentlyContinue } else { $env:GITSETU_INSTALL_DIR = $oldInstallDir }
    if ($null -eq $oldPath) { Remove-Item Env:Path -ErrorAction SilentlyContinue } else { $env:Path = $oldPath }
    if ($null -eq $oldHostileMarker) { Remove-Item Env:GITSETU_HOSTILE_MARKER -ErrorAction SilentlyContinue } else { $env:GITSETU_HOSTILE_MARKER = $oldHostileMarker }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
