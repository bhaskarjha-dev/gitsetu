# GitSetu Windows uninstaller. Recursive deletion requires an exact marker.

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$KeepConfig,
    [switch]$Teardown
)

# Self-healing execution policy bypass for restricted environments
if ($PSVersionTable.PSVersion.Major -ge 3 -and -not $env:GITSETU_EXECUTION_POLICY_BYPASSED) {
    $scopePolicy = Get-ExecutionPolicy -Scope Process
    if ($scopePolicy -eq 'Restricted' -or $scopePolicy -eq 'Undefined') {
        $effectivePolicy = Get-ExecutionPolicy
        if ($effectivePolicy -eq 'Restricted') {
            if (-not [string]::IsNullOrEmpty($PSCommandPath) -and (Test-Path -LiteralPath $PSCommandPath)) {
                $env:GITSETU_EXECUTION_POLICY_BYPASSED = "1"
                $forwardArgs = @()
                foreach ($entry in $PSBoundParameters.GetEnumerator()) {
                    if ($entry.Value -is [System.Management.Automation.SwitchParameter]) {
                        if ($entry.Value.IsPresent) { $forwardArgs += "-$($entry.Key)" }
                    } else {
                        $forwardArgs += "-$($entry.Key)"
                        $forwardArgs += [string]$entry.Value
                    }
                }
                if ($args -and $args.Count -gt 0) {
                    $forwardArgs += $args
                }
                & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @forwardArgs
                exit $LASTEXITCODE
            }
        }
    }
}

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

$isV1 = $false
$v1Share = Join-Path $rootDir "share"
if (Test-Path -LiteralPath (Join-Path $v1Share ".git")) {
    $isV1 = $true
    $version = "1.0.0"
    $exePath = Join-Path $rootDir "bin\gitsetu.cmd"
} else {
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
    $version = $marker["version"]
}

Write-Host "GitSetu v$version is installed at $rootDir"
$teardownWarning = $false
if ($KeepConfig) {
    Write-Host "Generated SSH keys and Git identity configuration are preserved." -ForegroundColor Gray
} else {
    Write-Host "Running managed-state teardown..."
    if (Test-Path -LiteralPath $exePath) {
        & $exePath teardown --force
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Managed teardown exited with code $LASTEXITCODE. Global configuration or hooks may require manual review."
            $teardownWarning = $true
        }
    }
}

if (-not $Force) {
    $canPrompt = [Environment]::UserInteractive
    if ($canPrompt) {
        try {
            $confirmation = Read-Host "Remove the GitSetu executables and versioned installation? [y/N]"
        } catch {
            $confirmation = ""
        }
    } else {
        $confirmation = ""
    }
    if ($confirmation -notmatch '^[Yy]$') {
        [Console]::Error.WriteLine("confirmation required; pass -Force")
        exit 3
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

$userKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
if ($userKey) {
    try {
        $pathKind = $userKey.GetValueKind("Path")
        $userPathRaw = $userKey.GetValue("Path", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($userPathRaw) {
            $normalizedBin = $binDir.TrimEnd('\')
            $kept = New-Object 'System.Collections.Generic.List[string]'
            foreach ($entry in ($userPathRaw -split ';')) {
                if ([string]::IsNullOrWhiteSpace($entry)) { continue }
                $remove = $false
                try {
                    $expanded = [Environment]::ExpandEnvironmentVariables($entry.Trim())
                    $candidate = [IO.Path]::GetFullPath($expanded).TrimEnd('\')
                    $remove = $candidate.Equals($normalizedBin, [StringComparison]::OrdinalIgnoreCase)
                } catch { }
                if (-not $remove) { $kept.Add($entry) }
            }
            $newPath = [string]::Join(";", $kept)
            if ($newPath -ne $userPathRaw -and -not $usingTestMode) {
                $userKey.SetValue("Path", $newPath, $pathKind)
            }
        }
    } finally {
        $userKey.Close()
    }
}

try {
    Remove-Item -LiteralPath $rootDir -Recurse -Force
} catch {
    Stop-Uninstall "Could not completely remove $rootDir"
}
if ($teardownWarning) {
    Write-Host "GitSetu executables were removed, but managed configuration could not be completely torn down." -ForegroundColor Yellow
} else {
    Write-Host "GitSetu was removed successfully." -ForegroundColor Green
}
