[CmdletBinding()]
param(
    [switch]$VerifyOnly,
    [string]$GameRoot
)

$packageRoot = $PSScriptRoot
. (Join-Path $packageRoot "common.ps1")

$manifest = Get-PatchManifest $packageRoot
$targetRoot = Resolve-GameRoot $packageRoot $GameRoot
Assert-Payload $packageRoot $manifest | Out-Null
$state = Get-InstallState $targetRoot $manifest

if ($state.status -eq "steam-original") {
    Write-Host "MBAA Chinese Patch Stable v1.1.4 is not installed; the Steam-original runtime is already present."
    exit 0
}
if ($state.status -ne "installed") {
    Write-Host "Unexpected game-file state:"
    foreach ($entry in @($manifest.files)) {
        $name = [string]$entry.name
        Write-Host "  $name=$($state.actual_hashes[$name])"
    }
    throw "Refusing to restore over an old patch, a mixed state, or unknown files."
}

$installBackup = Get-VerifiedInstallBackup $targetRoot $manifest
if ($null -eq $installBackup) {
    throw "No verified Steam-original backup from this release was found. The patch was not changed. Use Steam file verification to recover the original runtime."
}
if ($VerifyOnly) {
    Write-Host "MBAA Chinese Patch Stable v1.1.4 is eligible for restoration to the complete Steam-original runtime."
    Write-Host "Restore source: $($installBackup.root)"
    exit 0
}

Assert-GameClosed $targetRoot
$transactionPrefix = ([string]$manifest.backup_directory_prefix + "Uninstall_")
$transactionRoot = New-ManagedDirectory $targetRoot $transactionPrefix
$recordPath = Join-Path $transactionRoot "uninstall-record.json"
$record = [ordered]@{
    schema_version = 2
    release_id = $manifest.release_id
    release_version = $manifest.release_version
    operation = "uninstall"
    status = "backup-in-progress"
    completed_at = $null
    error = $null
    game_root = $targetRoot
    restore_source = $installBackup.root
    transaction_root = $transactionRoot
    files = @()
    changed_files = @()
    rollback = @()
}
foreach ($entry in @($manifest.files)) {
    $name = [string]$entry.name
    $descriptor = Get-InstallPayloadDescriptor $entry
    $restoreEntry = @($installBackup.record.files | Where-Object { $_.name -eq $name })
    if ($restoreEntry.Count -ne 1) {
        throw "Verified install backup has no unique restore record for $name."
    }
    $record.files += [ordered]@{
        name = $name
        chinese_payload_sha256 = [string]$descriptor.sha256
        steam_original_sha256 = [string]$restoreEntry[0].original_sha256
    }
}
Write-JsonFile $recordPath $record

try {
    foreach ($entry in @($manifest.files)) {
        $name = [string]$entry.name
        $descriptor = Get-InstallPayloadDescriptor $entry
        $source = Join-Path $targetRoot $name
        $backup = Join-Path $transactionRoot $name
        Copy-Item -LiteralPath $source -Destination $backup -ErrorAction Stop
        Assert-Hash $backup $descriptor.sha256 "Uninstall transaction backup $name"
    }
    $record.status = "backup-complete"
    Write-JsonFile $recordPath $record
} catch {
    $record.status = "backup-failed"
    $record.error = $_.Exception.Message
    Write-JsonFile $recordPath $record
    throw
}

$changed = New-Object System.Collections.ArrayList
try {
    foreach ($entry in @($manifest.files)) {
        $name = [string]$entry.name
        $descriptor = Get-InstallPayloadDescriptor $entry
        $recordEntry = @($installBackup.record.files | Where-Object { $_.name -eq $name })
        $source = Join-Path $installBackup.root $name
        $target = Join-Path $targetRoot $name
        Replace-VerifiedFile $source $target $descriptor.sha256 $recordEntry[0].original_sha256 "Restore $name"
        [void]$changed.Add($entry)
        $record.changed_files = @($changed | ForEach-Object { $_.name })
        Write-JsonFile $recordPath $record
    }
    foreach ($entry in @($manifest.files)) {
        $name = [string]$entry.name
        $recordEntry = @($installBackup.record.files | Where-Object { $_.name -eq $name })
        Assert-Hash (Join-Path $targetRoot $name) $recordEntry[0].original_sha256 "Restored $name"
    }
} catch {
    $failure = $_
    $record.status = "restore-failed-rollback-pending"
    $record.error = $failure.Exception.Message
    foreach ($index in (($changed.Count - 1)..0)) {
        if ($index -lt 0) {
            break
        }
        $entry = $changed[$index]
        $name = [string]$entry.name
        $target = Join-Path $targetRoot $name
        $backup = Join-Path $transactionRoot $name
        $descriptor = Get-InstallPayloadDescriptor $entry
        $recordEntry = @($installBackup.record.files | Where-Object { $_.name -eq $name })
        try {
            if ((Get-Sha256 $target) -eq $recordEntry[0].original_sha256.ToLowerInvariant()) {
                Replace-VerifiedFile $backup $target $recordEntry[0].original_sha256 $descriptor.sha256 "Uninstall rollback $name"
                $record.rollback += "$name:restored"
            } else {
                $record.rollback += "$name:skipped-unexpected-current-hash"
            }
        } catch {
            $record.rollback += "$name:rollback-error:$($_.Exception.Message)"
        }
    }
    $record.status = "restore-failed"
    Write-JsonFile $recordPath $record
    throw $failure
}

$installBackup.record.status = "uninstalled"
$installBackup.record.uninstalled_at = (Get-Date).ToString("o")
Write-JsonFile (Join-Path $installBackup.root "install-record.json") $installBackup.record
$record.status = "restored-steam-original"
$record.completed_at = (Get-Date).ToString("o")
Write-JsonFile $recordPath $record
try {
    Remove-ManagedDirectory $targetRoot $transactionRoot $transactionPrefix
} catch {
    Write-Warning "Steam-original restoration succeeded, but the temporary Chinese rollback backup was kept: $transactionRoot"
}
try {
    Remove-ManagedDirectory $targetRoot $installBackup.root ([string]$manifest.backup_directory_prefix)
} catch {
    Write-Warning "Steam-original restoration succeeded, but the original backup was kept: $($installBackup.root)"
}
Write-Host "MBAA Chinese Patch Stable v1.1.4 was restored to the Steam-original runtime successfully."
