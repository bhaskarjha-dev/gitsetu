# Windows-native command dispatch contract for the GitSetu launcher.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) ("gitsetu-dispatch-test-" + [Guid]::NewGuid().ToString("N"))
$launcherDir = Join-Path $temp "launcher"
$launcher = Join-Path $launcherDir "gitsetu.exe"
$oldEnvironment = @{}
$environmentNames = @("HOME", "USERPROFILE", "XDG_CONFIG_HOME", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM", "GITSETU_TEST_MODE", "CI")

function Get-DispatchResult([string[]]$Arguments) {
    $previousAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = (& $launcher @Arguments 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousAction
    }
    [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

try {
    foreach ($name in $environmentNames) {
        $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }
    New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "packaging\windows\build_launcher.ps1") -OutDir $launcherDir -TestMode
    if ($LASTEXITCODE -ne 0) { throw "test-mode launcher build failed" }
    Copy-Item (Join-Path $repoRoot "gitsetu") (Join-Path $launcherDir "gitsetu")
    Copy-Item (Join-Path $repoRoot "lib") (Join-Path $launcherDir "lib") -Recurse

    $env:HOME = $temp
    $env:USERPROFILE = $temp
    $env:XDG_CONFIG_HOME = (Join-Path $temp ".config")
    $env:GIT_CONFIG_GLOBAL = (Join-Path $temp ".gitconfig")
    $env:GIT_CONFIG_NOSYSTEM = "1"
    $env:GITSETU_TEST_MODE = "1"
    $env:CI = "1"

    $version = Get-DispatchResult @("--version")
    if ($version.ExitCode -ne 0 -or $version.Output -notmatch "gitsetu v1\.1\.0") {
        throw "version dispatch failed: $($version.Output)"
    }

    $help = Get-DispatchResult @("--help")
    if ($help.ExitCode -ne 0 -or $help.Output -notmatch "USAGE" -or $help.Output -notmatch "profile" -or $help.Output -notmatch "credential") {
        throw "help dispatch is incomplete: $($help.Output)"
    }

    $status = Get-DispatchResult @("status")
    if ($status.ExitCode -ne 0 -or $status.Output -notmatch "Current Directory") {
        throw "status dispatch failed: $($status.Output)"
    }

    $prompt = Get-DispatchResult @("prompt")
    if ($prompt.ExitCode -ne 0 -or $prompt.Output -match "Unknown command") {
        throw "prompt dispatch failed: $($prompt.Output)"
    }

    $unknown = Get-DispatchResult @("definitely-not-a-command")
    if ($unknown.ExitCode -eq 0 -or $unknown.Output -notmatch "Unknown command") {
        throw "unknown command was not rejected: $($unknown.Output)"
    }

    $run = Get-DispatchResult @("run")
    if ($run.ExitCode -eq 0 -or $run.Output -notmatch "Usage: gitsetu run") {
        throw "run arity was not rejected: $($run.Output)"
    }

    $credential = Get-DispatchResult @("credential", "not-an-action")
    if ($credential.ExitCode -eq 0 -or $credential.Output -notmatch "Unknown credential action") {
        throw "credential action validation was not dispatched: $($credential.Output)"
    }

    $guard = Get-DispatchResult @("guard")
    if ($guard.ExitCode -eq 0 -or $guard.Output -notmatch "Usage: gitsetu guard") {
        throw "guard validation was not dispatched: $($guard.Output)"
    }

    Write-Host "Windows CLI dispatch contract passed"
} finally {
    foreach ($name in $environmentNames) {
        $value = $oldEnvironment[$name]
        if ($null -eq $value) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
