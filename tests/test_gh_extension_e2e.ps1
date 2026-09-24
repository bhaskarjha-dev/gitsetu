# Controlled GitHub CLI extension lifecycle test. No GitHub token is needed.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$gh = Get-Command gh.exe -ErrorAction SilentlyContinue
if (-not $gh) { throw "GitHub CLI is required for this E2E test" }
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("gitsetu-gh-e2e-" + [Guid]::NewGuid().ToString("N"))
$extensionNames = @("gh-gitsetu", "gh-setu")
$oldConfig = $env:GH_CONFIG_DIR
$oldAppData = $env:APPDATA
$oldLocalAppData = $env:LOCALAPPDATA
$oldToken = $env:GH_TOKEN

try {
    $env:GH_CONFIG_DIR = Join-Path $testRoot "gh-config"
    $env:APPDATA = Join-Path $testRoot "appdata"
    $env:LOCALAPPDATA = Join-Path $testRoot "localappdata"
    [void][IO.Directory]::CreateDirectory($env:GH_CONFIG_DIR)
    [void][IO.Directory]::CreateDirectory($env:APPDATA)
    [void][IO.Directory]::CreateDirectory($env:LOCALAPPDATA)
    Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
    $installedExtensions = @()
    foreach ($extensionName in $extensionNames) {
        $extensionRepo = Join-Path $testRoot $extensionName
        [void][IO.Directory]::CreateDirectory($extensionRepo)
        Copy-Item (Join-Path $repoRoot "packaging\gh-extension\$extensionName") $extensionRepo
        Copy-Item (Join-Path $repoRoot "gitsetu") $extensionRepo
        Copy-Item (Join-Path $repoRoot "lib") (Join-Path $extensionRepo "lib") -Recurse
        Copy-Item (Join-Path $repoRoot "packaging\release.env") (Join-Path $extensionRepo "release.env")

        Push-Location $extensionRepo
        try {
            & git init -q
            if ($LASTEXITCODE -ne 0) { throw "git init failed" }
            & git config user.name "GitSetu Test"
            & git config user.email "test@gitsetu.invalid"
            & git -c core.autocrlf=false add .
            if ($LASTEXITCODE -ne 0) { throw "git add failed" }
            & git commit -q -m "test: controlled gitsetu extension"
            if ($LASTEXITCODE -ne 0) { throw "git commit failed" }

            & gh extension install .
            if ($LASTEXITCODE -ne 0) { throw "gh extension install failed for $extensionName" }
        } finally {
            Pop-Location
        }

        $installedExtension = Join-Path $env:LOCALAPPDATA "GitHub CLI\extensions\$extensionName"
        if (-not (Test-Path -LiteralPath $installedExtension)) {
            throw "Installed extension is absent from isolated GitHub CLI state: $extensionName"
        }
        $installedExtensions += $installedExtension
    }

    $previousAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $version = (& gh gitsetu --version 2>&1 | Out-String)
        $versionExit = $LASTEXITCODE
        $aliasVersion = (& gh setu --version 2>&1 | Out-String)
        $aliasExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousAction }
    if ($versionExit -ne 0 -or $version -notmatch "gitsetu v1\.1\.0") { throw "gh gitsetu failed: $version" }
    if ($aliasExit -ne 0 -or $aliasVersion -notmatch "gitsetu v1\.1\.0") { throw "gh setu failed: $aliasVersion" }

    # Current gh releases may require authentication even for removal.
    # Cleanup is therefore exact and confined to the isolated APPDATA tree.
    foreach ($installedExtension in $installedExtensions) {
        Remove-Item -LiteralPath $installedExtension -Recurse -Force
        if (Test-Path -LiteralPath $installedExtension) { throw "Extension remained after isolated cleanup: $installedExtension" }
    }
    Write-Host "GitHub extension E2E: PASS" -ForegroundColor Green
} finally {
    if ($null -eq $oldToken) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue } else { $env:GH_TOKEN = $oldToken }
    if ($null -eq $oldConfig) { Remove-Item Env:GH_CONFIG_DIR -ErrorAction SilentlyContinue } else { $env:GH_CONFIG_DIR = $oldConfig }
    if ($null -eq $oldAppData) { Remove-Item Env:APPDATA -ErrorAction SilentlyContinue } else { $env:APPDATA = $oldAppData }
    if ($null -eq $oldLocalAppData) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $oldLocalAppData }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
