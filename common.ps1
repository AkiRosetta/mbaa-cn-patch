Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $hash = $algorithm.ComputeHash($stream)
        return ([System.BitConverter]::ToString($hash).Replace("-", "")).ToLowerInvariant()
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if ($null -ne $algorithm) {
            $algorithm.Dispose()
        }
    }
}

function Assert-Hash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $actual = Get-Sha256 $Path
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "$Description hash mismatch: expected $Expected, got $actual"
    }
}

function Test-Sha256Value {
    param([string]$Value)

    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match "^[0-9a-fA-F]{64}$"
}

function Get-ReleaseFileNames {
    param([Parameter(Mandatory = $true)][object]$Manifest)

    return @($Manifest.files | ForEach-Object { [string]$_.name } | Sort-Object)
}

function Get-ManifestProfile {
    param([Parameter(Mandatory = $true)][object]$Manifest)

    $property = @($Manifest.PSObject.Properties | Where-Object { $_.Name -eq "install_profile" })
    if ($property.Count -ne 1 -or $null -eq $property[0].Value) {
        throw "The release manifest has no install profile."
    }
    return $property[0].Value
}

function Get-ProfileHash {
    param(
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = @($Profile.files.PSObject.Properties | Where-Object { $_.Name -eq $Name })
    if ($property.Count -ne 1) {
        throw "Profile $($Profile.id) is missing $Name."
    }
    return [string]$property[0].Value
}

function Get-InstallPayloadDescriptor {
    param([Parameter(Mandatory = $true)][object]$Entry)

    $property = @($Entry.PSObject.Properties | Where-Object { $_.Name -eq "install_payload" })
    if ($property.Count -ne 1 -or $null -eq $property[0].Value) {
        throw "Payload entry $($Entry.name) is missing install_payload."
    }
    $descriptor = $property[0].Value
    if ([string]::IsNullOrWhiteSpace([string]$descriptor.path) -or
        -not (Test-Sha256Value ([string]$descriptor.sha256))) {
        throw "Payload entry $($Entry.name) has an invalid install_payload descriptor."
    }
    try {
        $bytes = [Int64]$descriptor.bytes
    } catch {
        throw "Payload entry $($Entry.name) has an invalid install_payload byte count."
    }
    if ($bytes -le 0) {
        throw "Payload entry $($Entry.name) has a non-positive install_payload byte count."
    }
    return $descriptor
}

function Assert-SafePayloadPath {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$DirectoryName,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ([System.IO.Path]::IsPathRooted($RelativePath) -or
        -not $RelativePath.StartsWith(($DirectoryName + "/"), [System.StringComparison]::OrdinalIgnoreCase) -or
        $RelativePath.Contains("..")) {
        throw "$Description has an unsafe path: $RelativePath"
    }
}

function Assert-ProfileShape {
    param(
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][string[]]$ExpectedFiles
    )

    if ([string]$Profile.id -ne "steam-clean" -or $null -eq $Profile.files) {
        throw "Install profile must be the Steam-original profile."
    }
    $actualFiles = @($Profile.files.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
    if ($actualFiles.Count -ne $ExpectedFiles.Count -or (($actualFiles -join "|") -ne ($ExpectedFiles -join "|"))) {
        throw "Install profile has an unexpected file set."
    }
    foreach ($name in $ExpectedFiles) {
        if (-not (Test-Sha256Value (Get-ProfileHash $Profile $name))) {
            throw "Install profile has an invalid hash for $name."
        }
    }
}

function Get-PatchManifest {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)

    $manifestPath = Join-Path $PackageRoot "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Missing manifest.json beside the installer."
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema_version -ne 4 -or
        $manifest.release_id -ne "mbaa-cn-stable-v1-1-4" -or
        $manifest.release_version -ne "1.1.4") {
        throw "This installer does not have the recognized compact Stable v1.1.4 manifest."
    }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.payload_directory) -or
        [string]$manifest.backup_directory_prefix -ne "MBAA_CN_Stable_v1_1_4_") {
        throw "The release manifest has an invalid payload or backup directory setting."
    }
    $expectedFiles = @("0003.p", "0004.p", "0007.p", "MBAA.exe" | Sort-Object)
    $actualFiles = Get-ReleaseFileNames $manifest
    if ($actualFiles.Count -ne $expectedFiles.Count -or (($actualFiles -join "|") -ne ($expectedFiles -join "|"))) {
        throw "The release manifest has an unexpected file set."
    }
    $profile = Get-ManifestProfile $manifest
    Assert-ProfileShape $profile $expectedFiles
    foreach ($entry in @($manifest.files)) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.name)) {
            throw "The release manifest has an incomplete payload file entry."
        }
        $descriptor = Get-InstallPayloadDescriptor $entry
        Assert-SafePayloadPath ([string]$descriptor.path) ([string]$manifest.payload_directory) "Install payload $($entry.name)"
    }
    return $manifest
}

function Resolve-GameRoot {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [string]$GameRootOverride
    )

    if ([string]::IsNullOrWhiteSpace($GameRootOverride)) {
        $gameRoot = Split-Path -Parent $PackageRoot
    } else {
        if (-not (Test-Path -LiteralPath $GameRootOverride -PathType Container)) {
            throw "The requested game root does not exist: $GameRootOverride"
        }
        $gameRoot = (Resolve-Path -LiteralPath $GameRootOverride).Path
    }
    if (-not (Test-Path -LiteralPath (Join-Path $gameRoot "MBAA.exe") -PathType Leaf)) {
        throw "Place this release folder directly inside the MELTY BLOOD game folder, beside MBAA.exe."
    }
    return $gameRoot
}

function Assert-GameClosed {
    param([Parameter(Mandatory = $true)][string]$GameRoot)

    $expectedPath = [System.IO.Path]::GetFullPath((Join-Path $GameRoot "MBAA.exe"))
    $matchingPids = @()
    foreach ($process in @(Get-Process -Name MBAA -ErrorAction SilentlyContinue)) {
        try {
            $actualPath = $process.Path
        } catch {
            throw "Cannot verify MBAA process path for PID $($process.Id). Close the game manually before continuing."
        }
        if ([string]::IsNullOrWhiteSpace($actualPath)) {
            throw "Cannot verify MBAA process path for PID $($process.Id). Close the game manually before continuing."
        }
        if ([System.IO.Path]::GetFullPath($actualPath) -ieq $expectedPath) {
            $matchingPids += $process.Id
        }
    }
    if ($matchingPids.Count -gt 0) {
        throw "MBAA is running (PID $($matchingPids -join ', ')). Close the game before continuing."
    }
}

function Assert-Payload {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    foreach ($entry in @($Manifest.files)) {
        $descriptor = Get-InstallPayloadDescriptor $entry
        Assert-Hash (Join-Path $PackageRoot $descriptor.path) $descriptor.sha256 "Install payload $($entry.name)"
    }
}

function Get-InstallState {
    param(
        [Parameter(Mandatory = $true)][string]$GameRoot,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    $actual = [ordered]@{}
    $steamOriginal = $true
    $installed = $true
    $profile = Get-ManifestProfile $Manifest
    foreach ($entry in @($Manifest.files)) {
        $name = [string]$entry.name
        $actual[$name] = Get-Sha256 (Join-Path $GameRoot $name)
        if ($actual[$name] -ne (Get-ProfileHash $profile $name).ToLowerInvariant()) {
            $steamOriginal = $false
        }
        $descriptor = Get-InstallPayloadDescriptor $entry
        if ($actual[$name] -ne $descriptor.sha256.ToLowerInvariant()) {
            $installed = $false
        }
    }
    if ($installed) {
        return [pscustomobject]@{ status = "installed"; actual_hashes = $actual }
    }
    if ($steamOriginal) {
        return [pscustomobject]@{ status = "steam-original"; actual_hashes = $actual }
    }
    return [pscustomobject]@{ status = "unexpected"; actual_hashes = $actual }
}

function New-ManagedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$GameRoot,
        [Parameter(Mandatory = $true)][string]$Prefix
    )

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        $suffix = if ($attempt -eq 0) { "" } else { "_" + $attempt }
        $candidate = Join-Path $GameRoot ($Prefix + $timestamp + $suffix)
        if (Test-Path -LiteralPath $candidate) {
            continue
        }
        try {
            New-Item -ItemType Directory -Path $candidate -ErrorAction Stop | Out-Null
            return $candidate
        } catch {
            if (Test-Path -LiteralPath $candidate) {
                continue
            }
            throw
        }
    }
    throw "Could not create a unique managed directory."
}

function Assert-ManagedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$GameRoot,
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$RequiredPrefix
    )

    $directoryName = Split-Path -Leaf $Directory
    if (-not $directoryName.StartsWith($RequiredPrefix, [System.StringComparison]::Ordinal)) {
        throw "Managed directory has an unexpected name: $Directory"
    }
    $expectedParent = [System.IO.Path]::GetFullPath($GameRoot).TrimEnd("\\")
    $actualParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $Directory)).TrimEnd("\\")
    if ($actualParent -ine $expectedParent) {
        throw "Managed directory escaped the game root: $Directory"
    }
}

function Remove-ManagedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$GameRoot,
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$RequiredPrefix
    )

    Assert-ManagedDirectory $GameRoot $Directory $RequiredPrefix
    Remove-Item -LiteralPath $Directory -Recurse -Force -ErrorAction Stop
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $temporary = "$Path.tmp"
    if (Test-Path -LiteralPath $temporary) {
        throw "Stale temporary record must be inspected first: $temporary"
    }
    try {
        $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-VerifiedInstallBackup {
    param(
        [Parameter(Mandatory = $true)][string]$GameRoot,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    $profile = Get-ManifestProfile $Manifest
    $prefix = [string]$Manifest.backup_directory_prefix
    foreach ($candidate in @(Get-ChildItem -LiteralPath $GameRoot -Directory -Filter ($prefix + "*") -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        $recordPath = Join-Path $candidate.FullName "install-record.json"
        if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
            continue
        }
        try {
            $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
        } catch {
            continue
        }
        if ($record.schema_version -ne 3 -or
            $record.release_id -ne $Manifest.release_id -or
            $record.release_version -ne $Manifest.release_version -or
            $record.status -ne "installed" -or
            $record.preinstall_profile_id -ne $profile.id) {
            continue
        }
        try {
            if ([System.IO.Path]::GetFullPath([string]$record.backup_root) -ine [System.IO.Path]::GetFullPath($candidate.FullName)) {
                continue
            }
        } catch {
            continue
        }
        $valid = $true
        foreach ($entry in @($Manifest.files)) {
            $name = [string]$entry.name
            $recordEntry = @($record.files | Where-Object { $_.name -eq $name })
            $backupFile = Join-Path $candidate.FullName $name
            $descriptor = Get-InstallPayloadDescriptor $entry
            $expectedOriginal = Get-ProfileHash $profile $name
            if ($recordEntry.Count -ne 1 -or
                $recordEntry[0].original_sha256 -ne $expectedOriginal -or
                $recordEntry[0].payload_sha256 -ne $descriptor.sha256 -or
                $recordEntry[0].payload_relative_path -ne $descriptor.path -or
                (Get-Sha256 $backupFile) -ne $expectedOriginal.ToLowerInvariant()) {
                $valid = $false
                break
            }
        }
        if ($valid) {
            return [pscustomobject]@{ record = $record; root = $candidate.FullName }
        }
    }
    return $null
}

function Replace-VerifiedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$ExpectedTarget,
        [Parameter(Mandatory = $true)][string]$ExpectedSource,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $targetDirectory = Split-Path -Parent $Target
    $targetName = Split-Path -Leaf $Target
    $temporary = Join-Path $targetDirectory ("." + $targetName + ".mbaa_cn_stable_v1_1_4.tmp")
    $replaceBackup = Join-Path $targetDirectory ("." + $targetName + ".mbaa_cn_stable_v1_1_4.replace-backup")
    if (Test-Path -LiteralPath $temporary) {
        throw "Stale replacement temporary must be inspected first: $temporary"
    }
    if (Test-Path -LiteralPath $replaceBackup) {
        throw "Stale replacement backup must be inspected first: $replaceBackup"
    }
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary -ErrorAction Stop
        Assert-Hash $temporary $ExpectedSource "$Description temporary"
        Assert-Hash $Target $ExpectedTarget "$Description target before replacement"
        [System.IO.File]::Replace($temporary, $Target, $replaceBackup)
        $temporary = $null
        Assert-Hash $Target $ExpectedSource "$Description target after replacement"
    } finally {
        if ($null -ne $temporary -and (Test-Path -LiteralPath $temporary)) {
            Remove-Item -LiteralPath $temporary -Force
        }
        if (Test-Path -LiteralPath $replaceBackup) {
            Remove-Item -LiteralPath $replaceBackup -Force
        }
    }
}
