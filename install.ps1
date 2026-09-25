# GitSetu pinned Windows release installer.
#
# v1.1.0 is currently a non-public development build. This script deliberately
# fails closed without a versioned release.env and a signed, pinned ZIP.

[CmdletBinding()]
param(
    [switch]$TestMode,
    [switch]$LocalDevelopment,
    [string]$TestArtifact,
    [string]$TestArtifactSha256,
    [string]$TestInstallDir
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Stop-Install([string]$Message) {
    throw "GitSetu installer: $Message"
}

function Get-IsoSize([long]$Length) {
    return $Length.ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Read-ReleaseConfig([string]$ScriptDirectory) {
    $candidates = @(
        (Join-Path $ScriptDirectory "release.env"),
        (Join-Path $ScriptDirectory "packaging\release.env")
    )
    $config = $null
    foreach ($candidate in $candidates) {
        if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and
            ((Get-Item -LiteralPath $candidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            $config = $candidate
            break
        }
    }
    if (-not $config) {
        Stop-Install "Pinned release metadata was not found beside install.ps1. Do not execute a mutable branch installer."
    }

    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($config)) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) { continue }
        $separator = $line.IndexOf("=")
        if ($separator -le 0) { Stop-Install "Unsafe release metadata line: $line" }
        $key = $line.Substring(0, $separator)
        $value = $line.Substring($separator + 1)
        if ($key -notmatch '^GITSETU_[A-Z0-9_]+$' -or $value -match '[\s\\]') {
            Stop-Install "Unsafe release metadata line: $line"
        }
        if ($values.ContainsKey($key)) { Stop-Install "Duplicate release metadata key: $key" }
        $values[$key] = $value
    }

    foreach ($key in @(
        "GITSETU_RELEASE_STATE", "GITSETU_RELEASE_VERSION", "GITSETU_RELEASE_TAG",
        "GITSETU_RELEASE_COMMIT", "GITSETU_ARTIFACT_URL", "GITSETU_ARTIFACT_SHA256",
        "GITSETU_ARTIFACT_SIZE", "GITSETU_SIGNATURE_URL", "GITSETU_SIGNATURE_BUNDLE_URL",
        "GITSETU_CERTIFICATE_IDENTITY", "GITSETU_CERTIFICATE_OIDC_ISSUER",
        "GITSETU_WINDOWS_ZIP_URL", "GITSETU_WINDOWS_ZIP_SHA256", "GITSETU_WINDOWS_ZIP_SIZE",
        "GITSETU_WINDOWS_SIGNATURE_URL", "GITSETU_WINDOWS_SIGNATURE_BUNDLE_URL"
    )) {
        if (-not $values.ContainsKey($key)) { Stop-Install "Missing release metadata key: $key" }
    }
    if ($values["GITSETU_RELEASE_VERSION"] -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        Stop-Install "Invalid release version metadata"
    }
    return $values
}

function Assert-SafeText([string]$Value, [string]$Label) {
    if ($Value -match '[\x00-\x1f\x7f]') { Stop-Install "$Label contains control characters" }
}

function Assert-NoReparsePath([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path)) { Stop-Install "Path must be absolute: $Path" }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [IO.Path]::GetPathRoot($full)
    $current = $full
    while ($current.Length -gt $root.Length -and $current.Length -gt 0) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Stop-Install "Reparse-point path component is not allowed: $current"
            }
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName.TrimEnd('\', '/')
    }
}

function Test-TrustedOwner([string]$Path) {
    try {
        $acl = Get-Acl -LiteralPath $Path
        foreach ($rule in $acl.Access) {
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
            $dangerous = [Security.AccessControl.FileSystemRights]::WriteData -bor
                [Security.AccessControl.FileSystemRights]::AppendData -bor
                [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
                [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
                [Security.AccessControl.FileSystemRights]::Delete -bor
                [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
                [Security.AccessControl.FileSystemRights]::TakeOwnership
            if (($rule.FileSystemRights -band $dangerous) -ne 0) {
                $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier])
                $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
                $adminSid = New-Object Security.Principal.SecurityIdentifier("S-1-5-32-544")
                $systemSid = New-Object Security.Principal.SecurityIdentifier("S-1-5-18")
                $trusted = @($currentSid.Value, $adminSid.Value, $systemSid.Value)
                if ($sid.Value -notin $trusted) {
                    throw "Untrusted owner/ACL on Git for Windows component: $Path (rule $($sid.Value))"
                }
            }
        }
    } catch {
        if ($_.Exception.Message -like "Untrusted owner/ACL*") { throw }
        Stop-Install "Could not validate ownership and ACLs for: $Path"
    }
}

function Resolve-TrustedGitBash {
    $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    $programFilesX86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $roots = @(
        (Join-Path $programFiles "Git"),
        (Join-Path $programFilesX86 "Git"),
        (Join-Path $localAppData "Programs\Git")
    )
    $relativeCandidates = @("bin\bash.exe", "usr\bin\bash.exe")

    if ($env:GITSETU_TEST_MODE -eq "1" -and $env:GITSETU_TEST_GIT_BASH) {
        $testCandidate = [IO.Path]::GetFullPath($env:GITSETU_TEST_GIT_BASH)
        if (-not [IO.Path]::IsPathRooted($testCandidate) -or
            -not (Test-Path -LiteralPath $testCandidate -PathType Leaf) -or
            ((Get-Item -LiteralPath $testCandidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-Install "Test Git Bash path is invalid"
        }
        return $testCandidate
    }

    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        foreach ($relative in $relativeCandidates) {
            $candidate = [IO.Path]::GetFullPath((Join-Path $root $relative))
            if (-not $candidate.StartsWith(([IO.Path]::GetFullPath($root).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            if (((Get-Item -LiteralPath $candidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            Assert-NoReparsePath $candidate
            Test-TrustedOwner $candidate
            return $candidate
        }
    }
    return $null
}

function Resolve-TrustedGitExe([string]$BashPath) {
    if (-not $BashPath) { return $null }
    $gitBinDir = Split-Path -Path $BashPath -Parent
    $gitRoot = Split-Path -Path $gitBinDir -Parent
    foreach ($relative in @("cmd\git.exe", "bin\git.exe", "mingw64\bin\git.exe")) {
        $candidate = [IO.Path]::GetFullPath((Join-Path $gitRoot $relative))
        $prefix = [IO.Path]::GetFullPath($gitRoot).TrimEnd('\') + '\'
        if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        if (((Get-Item -LiteralPath $candidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        Assert-NoReparsePath $candidate
        Test-TrustedOwner $candidate
        return $candidate
    }
    return $null
}

function Assert-CleanDevelopmentCheckout([string]$Checkout, [string]$GitExe) {
    if (-not (Test-Path -LiteralPath (Join-Path $Checkout ".git"))) {
        Stop-Install "--Local-development must be run from a Git checkout"
    }
    $top = (& $GitExe -C $Checkout rev-parse --show-toplevel 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not [IO.Path]::GetFullPath($top).Equals([IO.Path]::GetFullPath($Checkout), [StringComparison]::OrdinalIgnoreCase)) {
        Stop-Install "Installer is not at the reviewed checkout root"
    }
    $status = (& $GitExe -C $Checkout status --porcelain=v1 --untracked-files=all | Out-String)
    if ($LASTEXITCODE -ne 0 -or $status.Length -ne 0) {
        Stop-Install "Local-development installation refuses a dirty Git checkout"
    }
}

function Expand-VerifiedZip([string]$Archive, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $allowedFiles = @(
        "gitsetu.exe", "gitsetu", "lib\completion.sh", "lib\core.sh", "lib\platform.sh",
        "lib\ui.sh", "lib\validate.sh", "lib\backup.sh", "lib\ssh.sh", "lib\gitconfig.sh",
        "lib\guard.sh", "lib\doctor.sh", "lib\verify.sh", "lib\teardown.sh", "lib\discovery.sh",
        "lib\setup.sh", "lib\keychain.sh"
    )
    $allowed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $allowedFiles) { [void]$allowed.Add($name.Replace('\', '/')) }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $destinationRoot = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $count = 0
    [long]$totalSize = 0

    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        if ($zip.Entries.Count -gt 64) { Stop-Install "Release ZIP contains too many members" }
        foreach ($entry in $zip.Entries) {
            $count++
            $name = $entry.FullName
            if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains("\") -or $name.StartsWith("/") -or $name.Contains(":")) {
                Stop-Install "Unsafe ZIP member name: $name"
            }
            $segments = $name.Split('/')
            if ($segments | Where-Object { $_ -eq ".." -or $_ -eq "." -or $_ -eq "" }) {
                Stop-Install "Unsafe ZIP member path: $name"
            }
            $normalized = [string]::Join('/', $segments)
            if (-not $allowed.Contains($normalized)) { Stop-Install "Unexpected ZIP member: $name" }
            if (-not $seen.Add($normalized)) { Stop-Install "Duplicate or case-colliding ZIP member: $name" }
            if ($entry.Length -gt 5MB) { Stop-Install "ZIP member is too large: $name" }
            $totalSize += $entry.Length
            if ($totalSize -gt 20MB) { Stop-Install "Release ZIP expands beyond the size limit" }
            $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($unixType -eq 0xA000) { Stop-Install "Symbolic-link ZIP member is forbidden: $name" }

            $target = [IO.Path]::GetFullPath((Join-Path $Destination $normalized.Replace('/', '\')))
            if (-not $target.StartsWith($destinationRoot, [StringComparison]::OrdinalIgnoreCase)) {
                Stop-Install "ZIP member escapes destination: $name"
            }
            $parent = [IO.Path]::GetDirectoryName($target)
            if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
            $input = $entry.Open()
            $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
        }
    } finally {
        $zip.Dispose()
    }
    if ($count -lt 3) { Stop-Install "Release ZIP does not contain the required GitSetu runtime" }
}

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDirectory) { $scriptDirectory = $PSScriptRoot }
$config = Read-ReleaseConfig $scriptDirectory
$usingTestMode = $TestMode.IsPresent -or $env:GITSETU_TEST_MODE -eq "1"
$hasDevelopmentCheckout = (Test-Path -LiteralPath (Join-Path $scriptDirectory ".git")) -and
    (Test-Path -LiteralPath (Join-Path $scriptDirectory "gitsetu") -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $scriptDirectory "lib") -PathType Container)
$usingLocalDevelopment = $LocalDevelopment.IsPresent -or
    (-not $usingTestMode -and $config["GITSETU_RELEASE_STATE"] -eq "development" -and $hasDevelopmentCheckout)
if ($usingTestMode -and $LocalDevelopment.IsPresent) { Stop-Install "Choose either test mode or local-development mode, not both" }
$localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
if ([string]::IsNullOrWhiteSpace($localAppData)) { Stop-Install "LOCALAPPDATA is unavailable" }

if ($usingTestMode) {
    $rootDir = if ($TestInstallDir) { $TestInstallDir } elseif ($env:GITSETU_INSTALL_DIR) { $env:GITSETU_INSTALL_DIR } else { Join-Path $localAppData "gitsetu" }
    $artifactPath = if ($TestArtifact) { $TestArtifact } else { $env:GITSETU_TEST_ARTIFACT }
    $expectedHash = if ($TestArtifactSha256) { $TestArtifactSha256.ToLowerInvariant() } else { $env:GITSETU_TEST_ARTIFACT_SHA256 }
    $expectedSize = 0
} else {
    $rootDir = if ($usingLocalDevelopment -and $TestInstallDir) { $TestInstallDir } else { Join-Path $localAppData "gitsetu" }
    $artifactPath = ""
    $expectedHash = ""
    $expectedSize = 0
    if ($config["GITSETU_RELEASE_STATE"] -eq "development") {
        if (-not $usingLocalDevelopment) {
            Stop-Install "v$($config['GITSETU_RELEASE_VERSION']) is in development. Use -LocalDevelopment from a clean reviewed checkout; no public artifact exists."
        }
    } elseif ($config["GITSETU_RELEASE_STATE"] -eq "released") {
        if ($usingLocalDevelopment) { Stop-Install "-LocalDevelopment is valid only while the release state is development" }
        if ($config["GITSETU_RELEASE_TAG"] -ne "v$($config['GITSETU_RELEASE_VERSION'])") { Stop-Install "Release tag/version mismatch" }
        if ($config["GITSETU_RELEASE_COMMIT"] -notmatch '^[0-9a-f]{40}$') { Stop-Install "Release commit pin is invalid" }
        if ($config["GITSETU_WINDOWS_ZIP_URL"] -notmatch '^https://github\.com/bhaskarjha-dev/gitsetu/releases/download/v[^\s/]+/[^\s]+$') {
            Stop-Install "Windows artifact URL is not pinned to the GitSetu release"
        }
        if ($config["GITSETU_WINDOWS_ZIP_SHA256"] -notmatch '^[0-9a-f]{64}$') { Stop-Install "Windows SHA-256 pin is invalid" }
        if ($config["GITSETU_WINDOWS_ZIP_SIZE"] -notmatch '^[1-9][0-9]*$') { Stop-Install "Windows artifact size is invalid" }
        if (-not $config["GITSETU_WINDOWS_SIGNATURE_URL"] -or -not $config["GITSETU_WINDOWS_SIGNATURE_BUNDLE_URL"] -or -not $config["GITSETU_CERTIFICATE_IDENTITY"]) {
            Stop-Install "Windows artifact signature metadata is required"
        }
        $artifactBase = $config["GITSETU_WINDOWS_ZIP_URL"].Substring(0, $config["GITSETU_WINDOWS_ZIP_URL"].LastIndexOf("/") + 1)
        if (-not $config["GITSETU_WINDOWS_SIGNATURE_URL"].StartsWith($artifactBase, [StringComparison]::Ordinal) -or
            -not $config["GITSETU_WINDOWS_SIGNATURE_BUNDLE_URL"].StartsWith($artifactBase, [StringComparison]::Ordinal)) {
            Stop-Install "Windows signature URLs are not pinned beside the artifact"
        }
        if (-not $config["GITSETU_CERTIFICATE_IDENTITY"].StartsWith("https://github.com/bhaskarjha-dev/gitsetu/", [StringComparison]::Ordinal)) {
            Stop-Install "Windows signature identity is outside the GitSetu repository"
        }
        $artifactPath = $config["GITSETU_WINDOWS_ZIP_URL"]
        $expectedHash = $config["GITSETU_WINDOWS_ZIP_SHA256"]
        $expectedSize = [long]$config["GITSETU_WINDOWS_ZIP_SIZE"]
    } else {
        Stop-Install "Unsupported release state: $($config['GITSETU_RELEASE_STATE'])"
    }
}

Assert-SafeText $rootDir "Installation root"
$rootDir = [IO.Path]::GetFullPath($rootDir)
if ($rootDir.TrimEnd('\') -eq [IO.Path]::GetPathRoot($rootDir).TrimEnd('\')) { Stop-Install "Refusing a drive-root installation" }
Assert-NoReparsePath $rootDir
if (-not $usingTestMode -and -not $usingLocalDevelopment) {
    if (-not $expectedHash -or $expectedHash -notmatch '^[0-9a-f]{64}$') { Stop-Install "A valid SHA-256 artifact pin is required" }
    if (-not $artifactPath) { Stop-Install "No Windows release artifact is available" }
}

$bash = Resolve-TrustedGitBash
if (-not $bash) { Stop-Install "Git for Windows was not found in a trusted standard installation root" }
$gitExe = $null
if ($usingLocalDevelopment) {
    $gitExe = Resolve-TrustedGitExe $bash
    if (-not $gitExe) { Stop-Install "A trusted Git for Windows executable is required for local-development mode" }
    Assert-CleanDevelopmentCheckout $scriptDirectory $gitExe
}

$rootPreexisted = Test-Path -LiteralPath $rootDir
$installComplete = $false
$tempRoot = $null
$stageDir = $null
try {
    if ($rootPreexisted) {
        $rootItem = Get-Item -LiteralPath $rootDir -Force
        if (-not $rootItem.PSIsContainer -or (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            Stop-Install "Installation root is not a real directory"
        }
        $markerPath = Join-Path $rootDir "install.marker"
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { Stop-Install "Refusing to replace an unmarked directory: $rootDir" }
    }

    [void][IO.Directory]::CreateDirectory((Join-Path $rootDir "releases"))
    $binDir = Join-Path $rootDir "bin"
    [void][IO.Directory]::CreateDirectory($binDir)
    Assert-NoReparsePath $rootDir
    Assert-NoReparsePath $binDir

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("gitsetu-install-" + [Guid]::NewGuid().ToString("N"))
    [void][IO.Directory]::CreateDirectory($tempRoot)
    $artifactFile = Join-Path $tempRoot "gitsetu-windows-x64.zip"
    if ($usingTestMode) {
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { Stop-Install "Test ZIP artifact does not exist" }
        Copy-Item -LiteralPath $artifactPath -Destination $artifactFile
        $expectedSize = (Get-Item -LiteralPath $artifactFile -Force).Length
    } elseif ($usingLocalDevelopment) {
        $sourceRoot = Join-Path $tempRoot "source"
        $launcherRoot = Join-Path $tempRoot "launcher"
        [void][IO.Directory]::CreateDirectory($sourceRoot)
        [void][IO.Directory]::CreateDirectory($launcherRoot)
        Copy-Item -LiteralPath (Join-Path $scriptDirectory "gitsetu") -Destination (Join-Path $sourceRoot "gitsetu")
        Copy-Item -LiteralPath (Join-Path $scriptDirectory "lib") -Destination (Join-Path $sourceRoot "lib") -Recurse
        $trustedPowerShell = Join-Path $PSHOME "powershell.exe"
        & $trustedPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDirectory "packaging\windows\build_launcher.ps1") -OutDir $launcherRoot
        if ($LASTEXITCODE -ne 0) { Stop-Install "Local-development launcher build failed" }
        Copy-Item -LiteralPath (Join-Path $launcherRoot "gitsetu.exe") -Destination (Join-Path $sourceRoot "gitsetu.exe")
        & $trustedPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDirectory "packaging\windows\build_release_zip.ps1") -SourceDir $sourceRoot -OutFile $artifactFile
        if ($LASTEXITCODE -ne 0) { Stop-Install "Local-development Windows ZIP build failed" }
        $expectedHash = (Get-FileHash -LiteralPath $artifactFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $expectedSize = (Get-Item -LiteralPath $artifactFile -Force).Length
    } else {
        Invoke-WebRequest -UseBasicParsing -Uri $artifactPath -OutFile $artifactFile -MaximumRedirection 3
        Invoke-WebRequest -UseBasicParsing -Uri $config["GITSETU_WINDOWS_SIGNATURE_URL"] -OutFile (Join-Path $tempRoot "gitsetu.zip.sig")
        Invoke-WebRequest -UseBasicParsing -Uri $config["GITSETU_WINDOWS_SIGNATURE_BUNDLE_URL"] -OutFile (Join-Path $tempRoot "gitsetu.zip.sigstore.json")

        $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
        $cosignCandidates = @(
            (Join-Path $localAppData "GitSetuTools\cosign.exe"),
            (Join-Path $programFiles "GitSetu\cosign.exe"),
            (Join-Path $programFiles "cosign\cosign.exe")
        )
        $cosign = $cosignCandidates | Where-Object {
            (Test-Path -LiteralPath $_ -PathType Leaf) -and
            (((Get-Item -LiteralPath $_ -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)
        } | Select-Object -First 1
        if (-not $cosign) { Stop-Install "A trusted cosign installation is required" }
        Assert-NoReparsePath $cosign
        Test-TrustedOwner $cosign
        & $cosign verify-blob `
            --certificate-identity $config["GITSETU_CERTIFICATE_IDENTITY"] `
            --certificate-oidc-issuer $config["GITSETU_CERTIFICATE_OIDC_ISSUER"] `
            --signature (Join-Path $tempRoot "gitsetu.zip.sig") `
            --bundle (Join-Path $tempRoot "gitsetu.zip.sigstore.json") `
            $artifactFile
        if ($LASTEXITCODE -ne 0) { Stop-Install "Windows artifact signature verification failed" }
    }

    $actualHash = (Get-FileHash -LiteralPath $artifactFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) { Stop-Install "Windows artifact SHA-256 verification failed" }
    $actualSize = (Get-Item -LiteralPath $artifactFile -Force).Length
    if ($actualSize -ne $expectedSize) { Stop-Install "Windows artifact size does not match release metadata" }

    $hashPrefix = $expectedHash.Substring(0, 16)
    $releaseId = "$($config['GITSETU_RELEASE_VERSION'])-$hashPrefix"
    $releaseDir = Join-Path (Join-Path $rootDir "releases") $releaseId
    $stageDir = Join-Path (Join-Path $rootDir "releases") (".stage-" + [Guid]::NewGuid().ToString("N"))
    [void][IO.Directory]::CreateDirectory($stageDir)
    Expand-VerifiedZip $artifactFile $stageDir

    $stageExe = Join-Path $stageDir "gitsetu.exe"
    $stageScript = Join-Path $stageDir "gitsetu"
    if (-not (Test-Path -LiteralPath $stageExe -PathType Leaf) -or -not (Test-Path -LiteralPath $stageScript -PathType Leaf)) {
        Stop-Install "Verified Windows release is incomplete"
    }
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $versionText = (& $stageExe --version 2>&1 | Out-String)
        $versionExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    if ($versionExitCode -ne 0 -or $versionText -notmatch [regex]::Escape("gitsetu v$($config['GITSETU_RELEASE_VERSION'])")) {
        Stop-Install "Verified Windows release failed its version self-check"
    }
    [IO.File]::WriteAllText((Join-Path $stageDir "release.marker"), "format=1`nversion=$($config['GITSETU_RELEASE_VERSION'])`nartifact_sha256=$expectedHash`n", (New-Object Text.UTF8Encoding($false)))

    if (Test-Path -LiteralPath $releaseDir) {
        $existingMarker = Join-Path $releaseDir "release.marker"
        if (-not (Test-Path -LiteralPath $existingMarker -PathType Leaf) -or
            -not (Select-String -LiteralPath $existingMarker -SimpleMatch "artifact_sha256=$expectedHash" -Quiet)) {
            Stop-Install "Existing versioned installation failed marker verification"
        }
        Remove-Item -LiteralPath $stageDir -Recurse -Force
    } else {
        Move-Item -LiteralPath $stageDir -Destination $releaseDir
    }
    $stageDir = $null

    $currentFile = Join-Path $rootDir "current.txt"
    if (Test-Path -LiteralPath $currentFile) {
        $currentItem = Get-Item -LiteralPath $currentFile -Force
        if ($currentItem.PSIsContainer -or (($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            Stop-Install "Current release pointer is not a regular file"
        }
    }
    $pointerTemp = Join-Path $rootDir (".current-" + [Guid]::NewGuid().ToString("N") + ".tmp")
    [IO.File]::WriteAllText($pointerTemp, "releases/$releaseId`n", (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $pointerTemp -Destination $currentFile -Force

    $rootMarker = Join-Path $rootDir "install.marker"
    $rootMarkerTemp = Join-Path $rootDir (".install-marker-" + [Guid]::NewGuid().ToString("N") + ".tmp")
    [IO.File]::WriteAllText($rootMarkerTemp, "format=1`nversion=$($config['GITSETU_RELEASE_VERSION'])`nartifact_sha256=$expectedHash`nrelease_id=$releaseId`n", (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $rootMarkerTemp -Destination $rootMarker -Force

    $escapedRoot = $rootDir.Replace("'", "''")
    $psShim = @'
# gitsetu-managed-installation v1
$ErrorActionPreference = "Stop"
$root = '__ROOT__'
$currentFile = Join-Path $root "current.txt"
if ((Test-Path -LiteralPath $currentFile) -and (((Get-Item -LiteralPath $currentFile -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw "Unsafe GitSetu pointer" }
$releaseDir = [IO.File]::ReadAllLines($currentFile)[0]
if ($releaseDir -notmatch '^releases/[0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]{16}$') { throw "Unsafe GitSetu release pointer" }
$exe = [IO.Path]::GetFullPath((Join-Path $root ($releaseDir.Replace('/', '\') + '\gitsetu.exe')))
$releaseRoot = [IO.Path]::GetFullPath((Join-Path $root "releases")) + '\'
if (-not $exe.StartsWith($releaseRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "GitSetu release escapes root" }
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "GitSetu release is missing" }
& $exe @args
exit $LASTEXITCODE
'@
    $psShim = $psShim.Replace('__ROOT__', $escapedRoot)
    # Invoke the verified native launcher by an installation-root-relative path.
    # A bare PowerShell command would be resolved from the caller's current directory or PATH.
    $cmdShim = "@echo off`r`nREM gitsetu-managed-installation v1`r`n`"%~dp0..\releases\$releaseId\gitsetu.exe`" %*`r`nexit /b %errorlevel%`r`n"
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    foreach ($name in @("gitsetu", "git-setu")) {
        $target = Join-Path $binDir $name
        if (Test-Path -LiteralPath $target) {
            $item = Get-Item -LiteralPath $target -Force
            if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { Stop-Install "Refusing unrelated executable: $target" }
        }
        [IO.File]::WriteAllText((Join-Path $binDir "$name.ps1"), $psShim, $utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $binDir "$name.cmd"), $cmdShim, $utf8NoBom)
    }

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $normalizedBin = $rootDir.TrimEnd('\') + "\bin"
    $found = $false
    foreach ($entry in ($userPath -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        try {
            $candidate = [IO.Path]::GetFullPath($entry.Trim()).TrimEnd('\')
            if ($candidate.Equals($normalizedBin, [StringComparison]::OrdinalIgnoreCase)) { $found = $true; break }
        } catch { }
    }
    $isolatedInvocation = $usingTestMode -or ($usingLocalDevelopment -and [bool]$TestInstallDir)
    if (-not $found -and -not $isolatedInvocation) {
        $newPath = if ([string]::IsNullOrWhiteSpace($userPath)) { $normalizedBin } else { "$userPath;$normalizedBin" }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    }
    $processPathFound = $false
    foreach ($entry in ($env:Path -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        try {
            $candidate = [IO.Path]::GetFullPath($entry.Trim()).TrimEnd('\')
            if ($candidate.Equals($normalizedBin, [StringComparison]::OrdinalIgnoreCase)) { $processPathFound = $true; break }
        } catch { }
    }
    if (-not $processPathFound) { $env:Path = "$normalizedBin;$env:Path" }

    $installComplete = $true
    if ($usingLocalDevelopment) {
        Write-Host "GitSetu v$($config['GITSETU_RELEASE_VERSION']) local-development build installed at $rootDir" -ForegroundColor Green
        Write-Host "This build is not a public release and was not downloaded from a remote." -ForegroundColor Yellow
    } else {
        Write-Host "GitSetu v$($config['GITSETU_RELEASE_VERSION']) installed at $rootDir" -ForegroundColor Green
    }
    Write-Host "Aliases: gitsetu, git-setu" -ForegroundColor Green
} finally {
    if ($stageDir -and (Test-Path -LiteralPath $stageDir)) { Remove-Item -LiteralPath $stageDir -Recurse -Force }
    if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    if (-not $rootPreexisted -and -not $installComplete -and (Test-Path -LiteralPath $rootDir)) {
        Remove-Item -LiteralPath $rootDir -Recurse -Force
    }
}
