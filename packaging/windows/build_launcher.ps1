# packaging/windows/build_launcher.ps1
# Compiles the trusted native launcher with the OS .NET Framework compiler.
[CmdletBinding()]
param(
    [string]$OutDir = "",
    [switch]$TestMode
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function ConvertTo-NullableUInt32([byte[]]$Bytes, [int]$Offset) {
    if ($Offset -lt 0 -or ($Offset + 4) -gt $Bytes.Length) { throw "PE integer offset is out of range: $Offset (stage=$script:peStage)" }
    return [BitConverter]::ToUInt32($Bytes, $Offset)
}

function Set-PeUInt32([byte[]]$Bytes, [int]$Offset, [uint32]$Value) {
    if ($Offset -lt 0 -or ($Offset + 4) -gt $Bytes.Length) { throw "PE integer offset is out of range: $Offset" }
    [Array]::Copy([BitConverter]::GetBytes($Value), 0, $Bytes, $Offset, 4)
}

function Convert-RvaToFileOffset([byte[]]$Bytes, [int]$PeOffset, [uint32]$Rva) {
    $script:peStage = "section-size-$Rva"
    $sectionOffset = $PeOffset + 24 + [int][BitConverter]::ToUInt16($Bytes, $PeOffset + 20)
    $sectionCount = [int][BitConverter]::ToUInt16($Bytes, $PeOffset + 6)
    for ($index = 0; $index -lt $sectionCount; $index++) {
        $current = $sectionOffset + ($index * 40)
        $script:peStage = "section-$index-virtual-size-at-$current"
        $virtualSize = ConvertTo-NullableUInt32 -Bytes $Bytes -Offset ($current + 8)
        $script:peStage = "section-$index-virtual-address-at-$current"
        $virtualAddress = ConvertTo-NullableUInt32 -Bytes $Bytes -Offset ($current + 12)
        $script:peStage = "section-$index-raw-size-at-$current"
        $rawSize = ConvertTo-NullableUInt32 -Bytes $Bytes -Offset ($current + 16)
        $script:peStage = "section-$index-raw-offset-at-$current"
        $rawOffset = ConvertTo-NullableUInt32 -Bytes $Bytes -Offset ($current + 20)
        if ($Rva -ge $virtualAddress -and $Rva -lt ($virtualAddress + [Math]::Max($virtualSize, $rawSize))) {
            return [int]($rawOffset + ($Rva - $virtualAddress))
        }
    }
    throw "PE RVA does not map to a file section: $Rva"
}

function Normalize-CompilerOutput([string]$Path) {
    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 256 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) { throw "Compiler output is not a PE executable" }
    $peOffset = [int][BitConverter]::ToUInt32($bytes, 0x3c)
    if ([Text.Encoding]::ASCII.GetString($bytes, $peOffset, 4) -ne "PE`0`0") { throw "Compiler output has an invalid PE signature" }

    # Remove wall-clock PE timestamp and checksum.
    $script:peStage = "timestamp"
    Set-PeUInt32 -Bytes $bytes -Offset ($peOffset + 8) -Value 0
    $optionalOffset = $peOffset + 24
    $script:peStage = "checksum"
    Set-PeUInt32 -Bytes $bytes -Offset ($optionalOffset + 64) -Value 0

    $magic = [BitConverter]::ToUInt16($bytes, $optionalOffset)
    $directoriesOffset = if ($magic -eq 0x10b) { $optionalOffset + 96 } elseif ($magic -eq 0x20b) { $optionalOffset + 112 } else { throw "Unsupported PE optional header" }
    $script:peStage = "cli-directory"
    $cliRva = ConvertTo-NullableUInt32 -Bytes $bytes -Offset ($directoriesOffset + (14 * 8))
    if ($cliRva -eq 0) { throw "Compiler output has no CLI header" }
    $cliOffset = Convert-RvaToFileOffset -Bytes $bytes -PeOffset $peOffset -Rva $cliRva
    $script:peStage = "metadata-rva"
    $metadataRva = ConvertTo-NullableUInt32 -Bytes $bytes -Offset ($cliOffset + 8)
    $metadataOffset = Convert-RvaToFileOffset -Bytes $bytes -PeOffset $peOffset -Rva $metadataRva
    if ([Text.Encoding]::ASCII.GetString($bytes, $metadataOffset, 4) -ne "BSJB") { throw "Invalid .NET metadata signature" }

    $script:peStage = "metadata-version-length"
    $versionLength = ConvertTo-NullableUInt32 -Bytes $bytes -Offset ($metadataOffset + 12)
    $streamOffset = $metadataOffset + 16 + [int]$versionLength
    $streamOffset += ($streamOffset % 4)
    $streamOffset += 2 # flags
    $streamCount = [int][BitConverter]::ToUInt16($bytes, $streamOffset)
    $streamOffset += 2
    $guidOffset = -1
    for ($index = 0; $index -lt $streamCount; $index++) {
        $script:peStage = "metadata-stream-$index-at-$streamOffset"
        $streamDataOffset = ConvertTo-NullableUInt32 -Bytes $bytes -Offset $streamOffset
        $streamOffset += 4
        $streamSize = ConvertTo-NullableUInt32 -Bytes $bytes -Offset $streamOffset
        $streamOffset += 4
        $nameStart = $streamOffset
        while ($streamOffset -lt $bytes.Length -and $bytes[$streamOffset] -ne 0) { $streamOffset++ }
        $name = [Text.Encoding]::ASCII.GetString($bytes, $nameStart, $streamOffset - $nameStart)
        $streamOffset++
        while (($streamOffset % 4) -ne 0) { $streamOffset++ }
        if ($name -eq "#GUID") {
            $guidOffset = $metadataOffset + [int]$streamDataOffset
            if ($streamSize -lt 16) { throw "Invalid #GUID metadata stream" }
            break
        }
    }
    if ($guidOffset -lt 0) { throw "Compiler output has no #GUID heap" }

    # MVID is GUID heap index zero. Normalize the old compiler's random MVID.
    [byte[]]$fixedGuid = [Guid]::Parse("00112233-4455-6677-8899-aabbccddeeff").ToByteArray()
    [Array]::Copy($fixedGuid, 0, $bytes, $guidOffset, 16)
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Assert-NoReparsePath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $current = $full
    while ($current.Length -gt $root.Length -and $current.Length -gt 0) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing reparse-point build path: $current"
            }
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
if (-not $OutDir) { $OutDir = [IO.Path]::GetFullPath((Join-Path $scriptDir "..\..\dist")) }
$OutDir = [IO.Path]::GetFullPath($OutDir)
if ($OutDir -match '[\x00-\x1f\x7f]') { throw "Output directory contains control characters" }
Assert-NoReparsePath $OutDir

$windowsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
$cscCandidates = @(
    (Join-Path $windowsRoot "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $windowsRoot "Microsoft.NET\Framework\v4.0.30319\csc.exe")
)
$csc = $null
foreach ($candidate in $cscCandidates) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    $item = Get-Item -LiteralPath $candidate -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
    Assert-NoReparsePath $candidate
    $csc = $candidate
    break
}
if (-not $csc) { throw "Microsoft .NET C# compiler was not found in a trusted fixed Windows path." }

if (-not (Test-Path -LiteralPath $OutDir)) { [void][IO.Directory]::CreateDirectory($OutDir) }
Assert-NoReparsePath $OutDir
$sourceFile = [IO.Path]::GetFullPath((Join-Path $scriptDir "gitsetu.cs"))
$outFile = Join-Path $OutDir "gitsetu.exe"
$buildTempDir = Join-Path $OutDir (".gitsetu-build-" + [Guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($buildTempDir)
$outTemp = Join-Path $buildTempDir "gitsetu.exe"

Write-Host "Compiling $sourceFile with $csc..."
$compilerArguments = @('/nologo', '/target:exe', '/platform:anycpu', '/optimize+')
if ($TestMode) { $compilerArguments += '/define:GITSETU_TEST_MODE' }
$compilerArguments += "/out:$outTemp"
$compilerArguments += $sourceFile
& $csc @compilerArguments
if ($LASTEXITCODE -ne 0) {
    Remove-Item -LiteralPath $buildTempDir -Recurse -Force
    throw "Native launcher compilation failed with exit code $LASTEXITCODE"
}
Normalize-CompilerOutput $outTemp
Move-Item -LiteralPath $outTemp -Destination $outFile -Force
Remove-Item -LiteralPath $buildTempDir -Force
$digest = (Get-FileHash -LiteralPath $outFile -Algorithm SHA256).Hash.ToLowerInvariant()
# Keep the checksum manifest's embedded filename tied to the actual launcher.
[IO.File]::WriteAllText("$outFile.sha256", "$digest  $([IO.Path]::GetFileName($outFile))`n", (New-Object Text.UTF8Encoding($false)))
Write-Host "Successfully compiled native launcher: $outFile"
Write-Host "SHA-256: $digest"
