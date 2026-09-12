Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace("-", "")).ToLowerInvariant()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $algorithm.Dispose()
    }
}

function Join-ArchiveParts {
    param(
        [Parameter(Mandatory = $true)][string[]]$Parts,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ExpectedHash
    )

    foreach ($partPath in $Parts) {
        if (-not (Test-Path -LiteralPath $partPath -PathType Leaf)) {
            throw "Missing split archive part: $partPath"
        }
    }
    if (Test-Path -LiteralPath $Destination) {
        throw "Stale joined archive temporary exists: $Destination"
    }

    $output = $null
    try {
        $output = [System.IO.File]::Open($Destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        foreach ($partPath in $Parts) {
            $input = $null
            try {
                $input = [System.IO.File]::OpenRead($partPath)
                $input.CopyTo($output)
            } finally {
                if ($null -ne $input) { $input.Dispose() }
            }
        }
    } catch {
        if ($null -ne $output) { $output.Dispose(); $output = $null }
        if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
        throw
    } finally {
        if ($null -ne $output) { $output.Dispose() }
    }

    if ((Get-Sha256 $Destination) -ne $ExpectedHash.ToLowerInvariant()) {
        Remove-Item -LiteralPath $Destination -Force
        throw "Joined repository archive hash mismatch. Download the repository files again."
    }
}

function Expand-VerifiedPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$ExpectedArchiveHash,
        [string[]]$ArchiveParts = @()
    )

    $matchingEntries = @($script:manifest.files | Where-Object { $_.name -eq $Name })
    if ($matchingEntries.Count -ne 1) {
        throw "The release manifest has no unique $Name payload entry."
    }
    $descriptor = $matchingEntries[0].install_payload
    $expectedHash = ([string]$descriptor.sha256).ToLowerInvariant()
    $expectedBytes = [Int64]$descriptor.bytes
    $destinationPath = Join-Path $script:payloadRoot $Name
    $temporaryPath = $destinationPath + ".mbaa_cn_repo_extract.tmp"

    if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
        if ((Get-Sha256 $destinationPath) -eq $expectedHash) {
            Write-Host "$Name is already prepared and verified."
            return
        }
        throw "Existing payload\$Name has an unexpected hash. Remove it manually after inspection, then run this script again."
    }
    if (Test-Path -LiteralPath $temporaryPath) {
        throw "Stale extraction temporary exists: $temporaryPath"
    }

    $archiveForRead = $ArchivePath
    $joinedArchivePath = $ArchivePath + ".mbaa_cn_repo_join.tmp"
    $removeJoinedArchive = $false
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        if ($ArchiveParts.Count -eq 0) {
            throw "Missing repository archive: $ArchivePath"
        }
        Join-ArchiveParts -Parts $ArchiveParts -Destination $joinedArchivePath -ExpectedHash $ExpectedArchiveHash
        $archiveForRead = $joinedArchivePath
        $removeJoinedArchive = $true
    } elseif ((Get-Sha256 $ArchivePath) -ne $ExpectedArchiveHash.ToLowerInvariant()) {
        throw "Repository archive hash mismatch: $ArchivePath"
    }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($archiveForRead)
        $input = $null
        $output = $null
        try {
            $entries = @($archive.Entries | Where-Object { $_.FullName -eq $Name })
            if ($entries.Count -ne 1 -or $entries[0].Length -ne $expectedBytes) {
                throw "The compressed repository payload has an unexpected $Name entry."
            }
            $input = $entries[0].Open()
            $output = [System.IO.File]::Open($temporaryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $input.CopyTo($output)
        } finally {
            if ($null -ne $output) { $output.Dispose() }
            if ($null -ne $input) { $input.Dispose() }
            $archive.Dispose()
        }

        if ((Get-Sha256 $temporaryPath) -ne $expectedHash) {
            throw "Extracted $Name hash mismatch."
        }
        Move-Item -LiteralPath $temporaryPath -Destination $destinationPath
        $temporaryPath = $null
        Write-Host "$Name prepared and verified."
    } finally {
        if ($null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        if ($removeJoinedArchive -and (Test-Path -LiteralPath $joinedArchivePath)) {
            Remove-Item -LiteralPath $joinedArchivePath -Force
        }
    }
}

$packageRoot = $PSScriptRoot
$script:payloadRoot = Join-Path $packageRoot "payload"
$script:manifest = Get-Content -LiteralPath (Join-Path $packageRoot "manifest.json") -Raw | ConvertFrom-Json

Expand-VerifiedPayload `
    -Name "0003.p" `
    -ArchivePath (Join-Path $script:payloadRoot "0003.p.zip") `
    -ExpectedArchiveHash "e2ce4b81bd8c08d4f368690367daf74029f22f9c27ebbe64d6aa5e387997381e" `
    -ArchiveParts @(
        (Join-Path $script:payloadRoot "0003.p.zip.001"),
        (Join-Path $script:payloadRoot "0003.p.zip.002")
    )

Expand-VerifiedPayload `
    -Name "0007.p" `
    -ArchivePath (Join-Path $script:payloadRoot "0007.p.zip") `
    -ExpectedArchiveHash "fe77d861f2841f678fc42d9bd334fcdd3b6418589e2ba8d323adf4d19c841c73"

Write-Host "Repository payloads are ready."
