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

if ($state.status -eq "installed") {
    $existingBackup = Get-VerifiedInstallBackup $targetRoot $manifest
    if ($null -eq $existingBackup) {
        throw "The complete Chinese payload is present but no verified Steam-original backup from this release was found. Refusing to claim that it can be uninstalled safely."
    }
    Write-Host "MBAA Chinese Patch Stable v1.1.5 is already installed."
    Write-Host "Verified Steam-original backup: $($existingBackup.root)"
    exit 0
}
if ($state.status -ne "steam-original") {
    Write-Host "Unexpected game-file state:"
    foreach ($entry in @($manifest.files)) {
        $name = [string]$entry.name
        Write-Host "  $name=$($state.actual_hashes[$name])"
    }
    Write-Host "Accepted install state: complete Steam-original runtime only."
    throw "Refusing to overwrite an old patch, a mixed state, or unknown files. Use Steam file verification before retrying."
}
if ($VerifyOnly) {
    Write-Host "MBAA Chinese Patch Stable v1.1.5 is eligible for installation from the complete Steam-original runtime."
    exit 0
}

Assert-GameClosed $targetRoot
$backupRoot = New-ManagedDirectory $targetRoot ([string]$manifest.backup_directory_prefix)
$recordPath = Join-Path $backupRoot "install-record.json"
$profile = Get-ManifestProfile $manifest
$record = [ordered]@{
    schema_version = 3
    release_id = $manifest.release_id
    release_version = $manifest.release_version
    status = "backup-in-progress"
    installed_at = $null
    uninstalled_at = $null
    error = $null
    game_root = $targetRoot
    package_root = $packageRoot
    backup_root = $backupRoot
    preinstall_profile_id = [string]$profile.id
    files = @()
    changed_files = @()
    rollback = @()
}
foreach ($entry in @($manifest.files)) {
    $name = [string]$entry.name
    $descriptor = Get-InstallPayloadDescriptor $entry
    $record.files += [ordered]@{
        name = $name
        original_sha256 = [string]$state.actual_hashes[$name]
        payload_sha256 = [string]$descriptor.sha256
        payload_relative_path = [string]$descriptor.path
    }
}
Write-JsonFile $recordPath $record

try {
    foreach ($entry in @($manifest.files)) {
        $name = [string]$entry.name
        $source = Join-Path $targetRoot $name
        $backup = Join-Path $backupRoot $name
        Copy-Item -LiteralPath $source -Destination $backup -ErrorAction Stop
        Assert-Hash $backup $state.actual_hashes[$name] "Steam-original backup $name"
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
        $payload = Join-Path $packageRoot $descriptor.path
        $target = Join-Path $targetRoot $name
        Replace-VerifiedFile $payload $target $state.actual_hashes[$name] $descriptor.sha256 "Install $name"
        [void]$changed.Add($entry)
        $record.changed_files = @($changed | ForEach-Object { $_.name })
        Write-JsonFile $recordPath $record
    }
    foreach ($entry in @($manifest.files)) {
        $descriptor = Get-InstallPayloadDescriptor $entry
        Assert-Hash (Join-Path $targetRoot $entry.name) $descriptor.sha256 "Installed $($entry.name)"
    }
} catch {
    $failure = $_
    $record.status = "install-failed-rollback-pending"
    $record.error = $failure.Exception.Message
    foreach ($index in (($changed.Count - 1)..0)) {
        if ($index -lt 0) {
            break
        }
        $entry = $changed[$index]
        $name = [string]$entry.name
        $target = Join-Path $targetRoot $name
        $backup = Join-Path $backupRoot $name
        $descriptor = Get-InstallPayloadDescriptor $entry
        try {
            if ((Get-Sha256 $target) -eq $descriptor.sha256.ToLowerInvariant()) {
                Replace-VerifiedFile $backup $target $descriptor.sha256 $state.actual_hashes[$name] "Install rollback $name"
                $record.rollback += "$name:restored"
            } else {
                $record.rollback += "$name:skipped-unexpected-current-hash"
            }
        } catch {
            $record.rollback += "$name:rollback-error:$($_.Exception.Message)"
        }
    }
    $record.status = "install-failed"
    Write-JsonFile $recordPath $record
    throw $failure
}

$record.status = "installed"
$record.installed_at = (Get-Date).ToString("o")
Write-JsonFile $recordPath $record
Write-Host "MBAA Chinese Patch Stable v1.1.5 installed successfully."
Write-Host "Verified Steam-original backup: $backupRoot"
