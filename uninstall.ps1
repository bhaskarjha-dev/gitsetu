# GitSetu Windows uninstaller. Recursive deletion requires an exact marker.

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Teardown
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Stop-Uninstall([string]$Message) {
    throw "GitSetu uninstaller: $Message"
}

function Assert-NoReparsePath([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path)) { Stop-Uninstall "Path must be absolute: $Path" }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [IO.Path]::GetPathRoot($full)
    $current = $full
    while ($current.Length -gt $root.Length -and $current.Length -gt 0) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Stop-Uninstall "Reparse-point path component is not allowed: $current"
            }
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName.TrimEnd('\', '/')
    }
}

$usingTestMode = $env:GITSETU_TEST_MODE -eq "1"
$localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
if ($usingTestMode -and $env:GITSETU_INSTALL_DIR) {
    $rootDir = $env:GITSETU_INSTALL_DIR
} else {
    $rootDir = Join-Path $localAppData "gitsetu"
}
$rootDir = [IO.Path]::GetFullPath($rootDir)
if ($rootDir.TrimEnd('\') -eq [IO.Path]::GetPathRoot($rootDir).TrimEnd('\')) { Stop-Uninstall "Refusing a drive-root target" }
if ($rootDir -match '[\x00-\x1f\x7f]') { Stop-Uninstall "Installation path contains control characters" }
Assert-NoReparsePath $rootDir

if (-not (Test-Path -LiteralPath $rootDir)) {
    Write-Host "GitSetu is not installed at $rootDir; nothing to remove."
    exit 0
}
$rootItem = Get-Item -LiteralPath $rootDir -Force
if (-not $rootItem.PSIsContainer -or (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
    Stop-Uninstall "Installation root is not a real directory"
}

$markerPath = Join-Path $rootDir "install.marker"
if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
    Stop-Uninstall "Refusing to remove an unmarked directory: $rootDir"
}
$markerItem = Get-Item -LiteralPath $markerPath -Force
if (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    Stop-Uninstall "Refusing a reparse-point installation marker"
}

$marker = @{}
foreach ($line in [IO.File]::ReadAllLines($markerPath)) {
    $separator = $line.IndexOf("=")
    if ($separator -le 0) { Stop-Uninstall "Invalid installation marker" }
    $key = $line.Substring(0, $separator)
    $value = $line.Substring($separator + 1)
    if ($key -notin @("format", "version", "artifact_sha256", "release_id")) {
        Stop-Uninstall "Invalid installation marker"
    }
    if ($marker.ContainsKey($key)) { Stop-Uninstall "Duplicate installation marker key" }
    $marker[$key] = $value
}
if ($marker.Count -ne 4 -or $marker["format"] -ne "1" -or
    $marker["version"] -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or
    $marker["artifact_sha256"] -notmatch '^[0-9a-f]{64}$') {
    Stop-Uninstall "Installation marker is incomplete or invalid"
}
$expectedReleaseId = "$($marker['version'])-$($marker['artifact_sha256'].Substring(0, 16))"
if ($marker["release_id"] -ne $expectedReleaseId) { Stop-Uninstall "Installation marker release ID is inconsistent" }

$currentPath = Join-Path $rootDir "current.txt"
if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) { Stop-Uninstall "Current release pointer is missing" }
$currentItem = Get-Item -LiteralPath $currentPath -Force
if ($currentItem.PSIsContainer -or (($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
    Stop-Uninstall "Current release pointer is not a regular file"
}
$currentLines = [IO.File]::ReadAllLines($currentPath)
if ($currentLines.Count -ne 1 -or $currentLines[0] -ne "releases/$expectedReleaseId") {
    Stop-Uninstall "Current release pointer does not match the installation marker"
}
$releaseDir = Join-Path $rootDir ("releases\" + $expectedReleaseId)
$exePath = Join-Path $releaseDir "gitsetu.exe"
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { Stop-Uninstall "Current GitSetu executable is missing" }
$exeItem = Get-Item -LiteralPath $exePath -Force
if (($exeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-Uninstall "Current GitSetu executable is redirected" }

Write-Host "GitSetu v$($marker['version']) is installed at $rootDir"
Write-Host "Generated SSH keys and Git identity configuration are preserved by default." -ForegroundColor Gray
if ($Teardown) {
    Write-Host "Running explicit managed-state teardown..."
    & $exePath teardown --deep --force
    if ($LASTEXITCODE -ne 0) { Stop-Uninstall "Managed-state teardown failed; installation was not removed" }
}

if (-not $Force) {
    $confirmation = Read-Host "Remove the GitSetu executables and versioned installation? [y/N]"
    if ($confirmation -notmatch '^[Yy]$') {
        Write-Host "Uninstallation aborted."
        exit 0
    }
}

$binDir = Join-Path $rootDir "bin"
$removeStatus = 0
foreach ($name in @("gitsetu", "git-setu")) {
    foreach ($extension in @(".cmd", ".ps1")) {
        $path = Join-Path $binDir ($name + $extension)
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
            -not (Select-String -LiteralPath $path -SimpleMatch "gitsetu-managed-installation v1" -Quiet)) {
            Write-Error "Refusing unmanaged executable: $path"
            $removeStatus = 1
        } else {
            try { Remove-Item -LiteralPath $path -Force } catch { $removeStatus = 1 }
        }
    }
}
if ($removeStatus -ne 0) { Stop-Uninstall "One or more GitSetu wrappers could not be removed; installation was preserved." }

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath) {
    $normalizedBin = $binDir.TrimEnd('\')
    $kept = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in ($userPath -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $remove = $false
        try {
            $candidate = [IO.Path]::GetFullPath($entry.Trim()).TrimEnd('\')
            $remove = $candidate.Equals($normalizedBin, [StringComparison]::OrdinalIgnoreCase)
        } catch { }
        if (-not $remove) { $kept.Add($entry) }
    }
    $newPath = [string]::Join(";", $kept)
    if ($newPath -ne $userPath -and -not $usingTestMode) {
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    }
}

try {
    Remove-Item -LiteralPath $rootDir -Recurse -Force
} catch {
    Stop-Uninstall "Could not completely remove $rootDir"
}
Write-Host "GitSetu was removed successfully." -ForegroundColor Green
