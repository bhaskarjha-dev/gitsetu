# Scoop behavior test using a workflow-pinned, hash-verified Scoop dependency.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$oldUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($env:SCOOP) {
    $scoop = Join-Path $env:SCOOP "bin\scoop.ps1"
} else {
    $command = Get-Command scoop -ErrorAction SilentlyContinue
    if (-not $command) { throw "A preinstalled, hash-pinned Scoop test dependency is required" }
    $scoop = $command.Source
}
if (-not (Test-Path -LiteralPath $scoop -PathType Leaf)) { throw "Pinned Scoop executable is missing: $scoop" }
$scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Split-Path (Split-Path $scoop -Parent) -Parent }
if (-not $scoopRoot) { throw "Unable to determine the Scoop installation root" }
if ($env:SCOOP) {
    foreach ($directory in @("shims", "apps", "cache", "buckets")) {
        $path = Join-Path $env:SCOOP $directory
        if (-not (Test-Path -LiteralPath $path)) { [void][IO.Directory]::CreateDirectory($path) }
    }
    $scoopAppRoot = Join-Path $env:SCOOP "apps\scoop\current"
    $scoopSupporting = Join-Path $scoopAppRoot "supporting"
    if (-not (Test-Path -LiteralPath $scoopSupporting)) {
        [void][IO.Directory]::CreateDirectory($scoopAppRoot)
        Copy-Item (Join-Path $env:SCOOP "supporting") $scoopSupporting -Recurse
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("gitsetu-scoop-e2e-" + [Guid]::NewGuid().ToString("N"))
$sourceRoot = Join-Path $testRoot "source"
$buildRoot = Join-Path $testRoot "build"
$zipPath = Join-Path $testRoot "gitsetu-windows-test.zip"
$manifestPath = Join-Path $testRoot "gitsetu_distribution_test.json"
$appName = "gitsetu_distribution_test"

try {
    $scoopTemplate = Get-Content (Join-Path $repoRoot "packaging\templates\scoop\gitsetu.json.in") -Raw
    if ($scoopTemplate -notmatch '"depends"\s*:\s*"git"' -or $scoopTemplate -notmatch '\{\{WINDOWS_ZIP_SHA256\}\}') {
        throw "Scoop release template is missing its Git dependency or digest pin"
    }
    [void][IO.Directory]::CreateDirectory($sourceRoot)
    [void][IO.Directory]::CreateDirectory($buildRoot)
    Copy-Item (Join-Path $repoRoot "gitsetu") (Join-Path $sourceRoot "gitsetu")
    Copy-Item (Join-Path $repoRoot "lib") (Join-Path $sourceRoot "lib") -Recurse
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "packaging\windows\build_launcher.ps1") -OutDir $buildRoot
    if ($LASTEXITCODE -ne 0) { throw "Native launcher build failed" }
    Copy-Item (Join-Path $buildRoot "gitsetu.exe") (Join-Path $sourceRoot "gitsetu.exe")
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "packaging\windows\build_release_zip.ps1") -SourceDir $sourceRoot -OutFile $zipPath
    if ($LASTEXITCODE -ne 0) { throw "Windows ZIP build failed" }

    $zipHash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $zipUri = ([Uri]$zipPath).AbsoluteUri
    $manifest = @"
{
  "version": "1.1.0",
  "description": "Controlled GitSetu distribution test",
  "homepage": "https://gitsetu.bhaskarjha.dev",
  "license": "MIT",
  "url": "$zipUri",
  "hash": "$zipHash",
  "bin": [
    "gitsetu.exe",
    ["gitsetu.exe", "git-setu"]
  ]
}
"@
    [IO.File]::WriteAllText($manifestPath, $manifest, (New-Object Text.UTF8Encoding($false)))

    & $scoop uninstall $appName 2>$null
    & $scoop install --no-update-scoop $manifestPath
    if ($LASTEXITCODE -ne 0) { throw "Scoop install failed" }

    $scoopShims = Join-Path $scoopRoot "shims"
    $primaryShim = Join-Path $scoopShims "gitsetu.exe"
    $aliasShim = Join-Path $scoopShims "git-setu.exe"
    $previousAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $primary = (& $primaryShim --version 2>&1 | Out-String)
        $primaryExit = $LASTEXITCODE
        $alias = (& $aliasShim --version 2>&1 | Out-String)
        $aliasExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousAction }
    if ($primaryExit -ne 0 -or $primary -notmatch "gitsetu v1\.1\.0") { throw "Scoop gitsetu shim failed: $primary" }
    if ($aliasExit -ne 0 -or $alias -notmatch "gitsetu v1\.1\.0") { throw "Scoop git-setu shim failed: $alias" }

    & $scoop uninstall $appName
    if ($LASTEXITCODE -ne 0) { throw "Scoop uninstall failed" }
    Write-Host "Controlled Scoop E2E: PASS" -ForegroundColor Green
} finally {
    [Environment]::SetEnvironmentVariable("Path", $oldUserPath, "User")
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
