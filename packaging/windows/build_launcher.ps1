# packaging/windows/build_launcher.ps1
# Compiles gitsetu.cs into gitsetu.exe using the built-in Windows .NET Framework csc.exe compiler
[CmdletBinding()]
param(
    [string]$OutDir = ""
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

if (-not $OutDir) {
    $OutDir = [System.IO.Path]::GetFullPath((Join-Path $scriptDir "..\..\dist"))
}

$cscCandidates = @(
    'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe',
    'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe'
)

$csc = $cscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $csc) {
    Write-Error "Microsoft .NET C# compiler (csc.exe) not found on this system."
    exit 1
}

if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$sourceFile = Join-Path $scriptDir "gitsetu.cs"
$outFile = Join-Path $OutDir "gitsetu.exe"

Write-Host "Compiling $sourceFile with $csc..."
& $csc /nologo /target:exe /optimize+ /out:"$outFile" "$sourceFile"

if ($LASTEXITCODE -eq 0) {
    Write-Host "Successfully compiled native launcher: $outFile"
} else {
    Write-Error "Compilation failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}
