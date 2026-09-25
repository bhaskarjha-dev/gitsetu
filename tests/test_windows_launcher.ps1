# Native launcher quoting/trust and Windows installer traversal tests.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

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

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) ("gitsetu-launcher-test-" + [Guid]::NewGuid().ToString("N"))
$one = Join-Path $temp "one"
$two = Join-Path $temp "two"
$oldTestMode = $env:GITSETU_TEST_MODE
$oldBash = $env:GITSETU_BASH
$oldInstallDir = $env:GITSETU_INSTALL_DIR

try {
    [void][IO.Directory]::CreateDirectory($one)
    [void][IO.Directory]::CreateDirectory($two)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "packaging\windows\build_launcher.ps1") -OutDir $one -TestMode
    if ($LASTEXITCODE -ne 0) { throw "First launcher build failed" }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "packaging\windows\build_launcher.ps1") -OutDir $two -TestMode
    if ($LASTEXITCODE -ne 0) { throw "Second launcher build failed" }
    Assert-LauncherSidecar $one
    Assert-LauncherSidecar $two
    $hashOne = (Get-FileHash (Join-Path $one "gitsetu.exe") -Algorithm SHA256).Hash
    $hashTwo = (Get-FileHash (Join-Path $two "gitsetu.exe") -Algorithm SHA256).Hash
    if ($hashOne -ne $hashTwo) { throw "Native launcher build is not deterministic" }

    Copy-Item (Join-Path $repoRoot "gitsetu") (Join-Path $one "gitsetu")
    Copy-Item (Join-Path $repoRoot "lib") (Join-Path $one "lib") -Recurse
    $env:GITSETU_TEST_MODE = "1"
    & (Join-Path $one "gitsetu.exe") --argv-self-test
    if ($LASTEXITCODE -ne 0) { throw "Argument quoting self-test failed" }

    # The production launcher must ignore the historical arbitrary GITSETU_BASH
    # override and use a validated standard Git for Windows installation.
    $env:GITSETU_TEST_MODE = "0"
    $env:GITSETU_BASH = (Join-Path $temp "attacker.exe")
    $previousAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $versionOutput = (& (Join-Path $one "gitsetu.exe") --version 2>&1 | Out-String)
        $versionExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousAction }
    if ($versionExit -ne 0 -or $versionOutput -notmatch "gitsetu v1\.1\.0") {
        throw "GITSETU_BASH was not ignored: $versionOutput"
    }

    # Exercise the native launcher's actual command dispatch, not only its
    # version and argument self-test. Status is read-only and should succeed in
    # the isolated test HOME; malformed/unknown commands must fail explicitly.
    $env:GITSETU_TEST_MODE = "1"
    $previousAction = $ErrorActionPreference
    $oldHome = $env:HOME
    $oldUserProfile = $env:USERPROFILE
    $oldXdg = $env:XDG_CONFIG_HOME
    $oldGitConfig = $env:GIT_CONFIG_GLOBAL
    $env:HOME = $temp
    $env:USERPROFILE = $temp
    $env:XDG_CONFIG_HOME = (Join-Path $temp ".config")
    $env:GIT_CONFIG_NOSYSTEM = "1"
    $env:GIT_CONFIG_GLOBAL = (Join-Path $temp ".gitconfig")
    $ErrorActionPreference = "Continue"
    try {
        $helpExit = 0
        $helpOutput = (& (Join-Path $one "gitsetu.exe") --help 2>&1 | Out-String)
        $helpExit = $LASTEXITCODE
        if ($helpExit -ne 0 -or $helpOutput -notmatch "USAGE") { throw "native launcher --help failed: $helpOutput" }
        $statusExit = 0
        $statusOutput = (& (Join-Path $one "gitsetu.exe") status 2>&1 | Out-String)
        $statusExit = $LASTEXITCODE
        if ($statusExit -ne 0 -or $statusOutput -notmatch "Current Directory") { throw "native launcher status failed: $statusOutput" }
        $unknownExit = 0
        $unknownOutput = (& (Join-Path $one "gitsetu.exe") definitely-not-a-command 2>&1 | Out-String)
        $unknownExit = $LASTEXITCODE
        if ($unknownExit -eq 0 -or $unknownOutput -notmatch "Unknown command") { throw "native launcher accepted an unknown command" }
    } finally {
        $ErrorActionPreference = $previousAction
        if ($null -eq $oldHome) { Remove-Item Env:HOME -ErrorAction SilentlyContinue } else { $env:HOME = $oldHome }
        if ($null -eq $oldUserProfile) { Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue } else { $env:USERPROFILE = $oldUserProfile }
        if ($null -eq $oldXdg) { Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue } else { $env:XDG_CONFIG_HOME = $oldXdg }
        if ($null -eq $oldGitConfig) { Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_GLOBAL = $oldGitConfig }
    }

    # A hash-valid but hostile ZIP must be rejected before extraction.
    $badZip = Join-Path $temp "bad.zip"
    $stream = [IO.File]::Open($badZip, [IO.FileMode]::CreateNew)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $entry = $archive.CreateEntry("../escape.txt")
            $writer = New-Object IO.StreamWriter($entry.Open())
            try { $writer.Write("owned") } finally { $writer.Dispose() }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
    $badHash = (Get-FileHash $badZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $badInstall = Join-Path $temp "bad-install"
    $env:GITSETU_TEST_MODE = "1"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "install.ps1") `
        -TestMode -TestArtifact $badZip -TestArtifactSha256 $badHash -TestInstallDir $badInstall
    if ($LASTEXITCODE -eq 0) { throw "Traversal ZIP was accepted" }
    if (Test-Path (Join-Path $temp "escape.txt")) { throw "Traversal ZIP wrote outside destination" }
    if (Test-Path $badInstall) { Remove-Item -LiteralPath $badInstall -Recurse -Force; throw "Failed install left a partial root" }

    # Build a clean fixture from the current source and exercise the explicit
    # local-development path without using a remote release artifact.
    $checkout = Join-Path $temp "clean-checkout"
    $sourceTar = Join-Path $temp "source.tar"
    [void][IO.Directory]::CreateDirectory($checkout)
    & git -C $repoRoot archive --format=tar --output=$sourceTar HEAD
    if ($LASTEXITCODE -ne 0) { throw "git archive failed" }
    $windowsTar = Join-Path $env:windir "System32\tar.exe"
    & $windowsTar -xf $sourceTar -C $checkout
    if ($LASTEXITCODE -ne 0) { throw "source fixture extraction failed" }
    Copy-Item (Join-Path $repoRoot "gitsetu") (Join-Path $checkout "gitsetu") -Force
    Remove-Item (Join-Path $checkout "lib") -Recurse -Force
    Copy-Item (Join-Path $repoRoot "lib") (Join-Path $checkout "lib") -Recurse
    foreach ($file in @("install.ps1", "uninstall.ps1", "package.json", "package-lock.json", "flake.nix", "flake.lock")) {
        Copy-Item (Join-Path $repoRoot $file) (Join-Path $checkout $file) -Force
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $checkout "packaging\windows"))
    foreach ($file in @("build_launcher.ps1", "build_release_zip.ps1", "gitsetu.cs")) {
        Copy-Item (Join-Path $repoRoot "packaging\windows\$file") (Join-Path $checkout "packaging\windows\$file") -Force
    }
    foreach ($file in @("release.js", "release.json", "release.env")) {
        Copy-Item (Join-Path $repoRoot "packaging\$file") (Join-Path $checkout "packaging\$file") -Force
    }
    Push-Location $checkout
    try {
        & git init -q
        & git config user.name "Distribution Test"
        & git config user.email "distribution@example.invalid"
        & git -c core.autocrlf=false add .
        & git commit -q -m "test: clean Windows local-development fixture"
        if ($LASTEXITCODE -ne 0) { throw "clean fixture commit failed" }
    } finally { Pop-Location }
    $localInstall = Join-Path $temp "local-install"
    $env:GITSETU_TEST_MODE = "0"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $checkout "install.ps1") -LocalDevelopment -TestInstallDir $localInstall
    if ($LASTEXITCODE -ne 0) { throw "PowerShell local-development install failed" }
    $env:GITSETU_TEST_MODE = "1"
    $env:GITSETU_INSTALL_DIR = $localInstall
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $checkout "uninstall.ps1") -Force
    if ($LASTEXITCODE -ne 0 -or (Test-Path $localInstall)) { throw "PowerShell local-development uninstall failed" }

    Write-Host "Windows launcher/security tests: PASS" -ForegroundColor Green
} finally {
    if ($null -eq $oldTestMode) { Remove-Item Env:GITSETU_TEST_MODE -ErrorAction SilentlyContinue } else { $env:GITSETU_TEST_MODE = $oldTestMode }
    if ($null -eq $oldBash) { Remove-Item Env:GITSETU_BASH -ErrorAction SilentlyContinue } else { $env:GITSETU_BASH = $oldBash }
    if ($null -eq $oldInstallDir) { Remove-Item Env:GITSETU_INSTALL_DIR -ErrorAction SilentlyContinue } else { $env:GITSETU_INSTALL_DIR = $oldInstallDir }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
