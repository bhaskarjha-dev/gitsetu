# Builds the canonical Windows ZIP with forward-slash, allowlisted members.
[CmdletBinding()]
param(
    [string]$SourceDir = "",
    [string]$OutFile = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = [IO.Path]::GetFullPath((Join-Path $scriptDir "..\.."))
if (-not $SourceDir) { $SourceDir = $repoRoot }
if (-not $OutFile) { $OutFile = Join-Path $repoRoot "dist\gitsetu-windows-x64.zip" }
$SourceDir = [IO.Path]::GetFullPath($SourceDir)
$OutFile = [IO.Path]::GetFullPath($OutFile)

$members = @(
    "gitsetu.exe", "gitsetu", "lib/completion.sh", "lib/core.sh", "lib/platform.sh",
    "lib/ui.sh", "lib/validate.sh", "lib/backup.sh", "lib/ssh.sh", "lib/gitconfig.sh",
    "lib/guard.sh", "lib/doctor.sh", "lib/verify.sh", "lib/teardown.sh", "lib/discovery.sh",
    "lib/setup.sh", "lib/keychain.sh"
)
foreach ($member in $members) {
    $path = [IO.Path]::GetFullPath((Join-Path $SourceDir $member.Replace('/', '\')))
    if (-not $path.StartsWith($SourceDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Member escapes source: $member" }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required release member is missing: $member" }
    $item = Get-Item -LiteralPath $path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse-point release member is forbidden: $member" }
}

$outParent = [IO.Path]::GetDirectoryName($OutFile)
if (-not [IO.Directory]::Exists($outParent)) { [void][IO.Directory]::CreateDirectory($outParent) }
$tempZip = Join-Path $outParent ("gitsetu-windows-" + [Guid]::NewGuid().ToString("N") + ".zip")
try {
    $stream = [IO.File]::Open($tempZip, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($member in $members) {
                $entry = $archive.CreateEntry($member, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = New-Object DateTimeOffset (1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $input = [IO.File]::OpenRead([IO.Path]::GetFullPath((Join-Path $SourceDir $member.Replace('/', '\'))))
                $output = $entry.Open()
                try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
    Move-Item -LiteralPath $tempZip -Destination $OutFile -Force
} finally {
    if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force }
}
$digest = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$OutFile.sha256", "$digest  $([IO.Path]::GetFileName($OutFile))`n", (New-Object Text.UTF8Encoding($false)))
Write-Host "Built $OutFile"
Write-Host "SHA-256: $digest"
