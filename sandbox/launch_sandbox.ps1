# sandbox/launch_sandbox.ps1 — Windows Sandbox Launcher for GitSetu Test Harness
param(
    [switch]$NoPause
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

# 3. Destination results directory
$resultsDir = [System.IO.Path]::GetFullPath((Join-Path $rootDir "..\sandbox_results"))
if (-not (Test-Path $resultsDir)) {
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
}

# 4. Generate WSB Configuration
$wsbGenerated = Join-Path $env:TEMP "gitsetu_test_dynamic.wsb"

$wsbContent = @"
<Configuration>
  <VGpu>Disable</VGpu>
  <Networking>Default</Networking>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$rootDir</HostFolder>
      <SandboxFolder>C:\gitsetu_source</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$gitHostDir</HostFolder>
      <SandboxFolder>C:\Git_Host</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$resultsDir</HostFolder>
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

Write-Host "Launching Windows Sandbox with:"
Write-Host "  Source:  $rootDir"
Write-Host "  Results: $resultsDir"
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
