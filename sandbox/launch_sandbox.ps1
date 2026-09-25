# sandbox/launch_sandbox.ps1 — Windows Sandbox Launcher for GitSetu Test Harness
param(
    [string]$ResultsDir = "",
    [switch]$NoPause,
    [switch]$EnableNetworking
)

$ErrorActionPreference = "Stop"

Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "     GitSetu Windows Sandbox Test Harness Launcher     " -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host ""

$sandboxDir = $PSScriptRoot
$rootDir = (Resolve-Path (Join-Path $sandboxDir "..")).Path

# 1. Locate WindowsSandbox.exe
$sandboxExe = "WindowsSandbox.exe"
$sandboxCmd = Get-Command $sandboxExe -ErrorAction SilentlyContinue
if (-not $sandboxCmd) {
    $systemSandbox = "$env:SystemRoot\System32\WindowsSandbox.exe"
    if (Test-Path $systemSandbox) {
        $sandboxExe = $systemSandbox
    } else {
        Write-Host "[ERROR] Windows Sandbox is not enabled or not found on this system." -ForegroundColor Red
        Write-Host "To enable Windows Sandbox:"
        Write-Host "  1. Open 'Turn Windows features on or off'"
        Write-Host "  2. Check 'Windows Sandbox'"
        Write-Host "  3. Click OK and restart your PC"
        if (-not $NoPause) { Read-Host "Press Enter to exit..." }
        exit 1
    }
}

# 2. Check for Git on host
$gitHostDir = "C:\Program Files\Git"
if (-not (Test-Path "$gitHostDir\bin\bash.exe")) {
    Write-Host "[WARNING] Git for Windows was not found at '$gitHostDir'." -ForegroundColor Yellow
    Write-Host "Windows Sandbox maps this folder to provide zero-download offline Git/Bash."
}

# 3. Destination results directory. Every invocation receives a unique
# run-scoped directory so a previous terminal status cannot be mistaken for a
# new result.
$resultsBase = if ($ResultsDir) { $ResultsDir } else { Join-Path $rootDir "..\sandbox_results" }
$resultsBase = [System.IO.Path]::GetFullPath($resultsBase)
$runId = (Get-Date -Format "yyyyMMdd_HHmmss") + "_" + [Guid]::NewGuid().ToString("N")
$resultsDir = Join-Path $resultsBase $runId
New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

$sourceCommit = "unknown"
$sourceDirty = "unknown"
try {
    $sourceCommit = (& git -C $rootDir rev-parse HEAD 2>$null | Out-String).Trim()
    $sourceStatus = (& git -C $rootDir status --porcelain=v1 --untracked-files=all 2>$null | Out-String).Trim()
    if ($sourceStatus) { $sourceDirty = "dirty" } else { $sourceDirty = "clean" }
} catch {
    $sourceCommit = "unavailable"
    $sourceDirty = "unavailable"
}

# XML-escape all host paths before embedding them in the generated .wsb file.
$rootDirXml = [System.Security.SecurityElement]::Escape($rootDir)
$gitHostDirXml = [System.Security.SecurityElement]::Escape($gitHostDir)
$resultsDirXml = [System.Security.SecurityElement]::Escape($resultsDir)

# 4. Generate WSB Configuration
# Use a unique configuration per launch so a stale Sandbox session cannot
# silently reuse an older mapped source tree or results directory.
$wsbGenerated = Join-Path $env:TEMP ("gitsetu_test_" + [Guid]::NewGuid().ToString("N") + ".wsb")

$networkingMode = if ($EnableNetworking) { "Default" } else { "Disable" }
$wsbContent = @"
<Configuration>
  <VGpu>Disable</VGpu>
  <Networking>$networkingMode</Networking>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$rootDirXml</HostFolder>
      <SandboxFolder>C:\gitsetu_source</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$gitHostDirXml</HostFolder>
      <SandboxFolder>C:\Git_Host</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$resultsDirXml</HostFolder>
      <SandboxFolder>C:\results</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -ExecutionPolicy Bypass -Command "&amp; { for (`$i=0; `$i -lt 60; `$i++) { if (Test-Path 'C:\gitsetu_source\sandbox\bootstrap.ps1') { &amp; 'C:\gitsetu_source\sandbox\bootstrap.ps1'; break }; if (Test-Path 'C:\Users\WDAGUtilityAccount\Desktop\gitsetu\sandbox\bootstrap.ps1') { &amp; 'C:\Users\WDAGUtilityAccount\Desktop\gitsetu\sandbox\bootstrap.ps1'; break }; Start-Sleep -Seconds 1 } }"</Command>
  </LogonCommand>
</Configuration>
"@

Set-Content -Path $wsbGenerated -Value $wsbContent -Encoding UTF8
$wsbHash = (Get-FileHash -LiteralPath $wsbGenerated -Algorithm SHA256).Hash.ToLowerInvariant()
@(
    "run_id=$runId"
    "source_commit=$sourceCommit"
    "source_dirty=$sourceDirty"
    "networking=$networkingMode"
    "wsb_sha256=$wsbHash"
) | Set-Content -LiteralPath (Join-Path $resultsDir "run-metadata.txt") -Encoding UTF8

Write-Host "Launching Windows Sandbox with:"
Write-Host "  Source:  $rootDir"
Write-Host "  Results: $resultsDir (run-scoped)"
Write-Host "  Config:  $wsbGenerated"
Write-Host ""

Start-Process -FilePath $sandboxExe -ArgumentList "`"$wsbGenerated`""

Write-Host "Windows Sandbox has been started!" -ForegroundColor Green
Write-Host "The sandbox runs in total isolation from your host system." -ForegroundColor Gray
Write-Host "Results and progress will be logged to: $resultsDir\sandbox_run.log" -ForegroundColor Gray

if (-not $NoPause) {
    Write-Host ""
    Read-Host "Press Enter to continue..."
}
