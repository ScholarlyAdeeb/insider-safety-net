#Requires -Version 5.1
<#
.SYNOPSIS
    Backs up what a clean reinstall cannot give back, restores it, and reclaims
    disk space after a Windows Insider build installs.
.DESCRIPTION
    Run with no arguments for a menu. Choices made in the menu are saved to
    config.json next to this script.

    Backup writes a small bundle (system info, drivers, app list, Wi-Fi profiles)
    under .\bundles and uploads it, plus the folders and files you picked, to every
    destination. A destination is an rclone path such as gdrive:insider-safety-net
    or terabox:insider-safety-net, or a local folder such as E:\Backup. Reruns only
    send what changed.

    Run elevated for drivers, BitLocker status, and the rollback actions.
.EXAMPLE
    .\InsiderSafetyNet.ps1
.EXAMPLE
    .\InsiderSafetyNet.ps1 -Action Backup -DryRun
.EXAMPLE
    .\InsiderSafetyNet.ps1 -Action Backup -Folders Documents,D:\Projects -Destinations gdrive:backup -Skip Drivers
.EXAMPLE
    .\InsiderSafetyNet.ps1 -Action Restore -AcceptAgreements -RestoreUserData
    Run from the copy of this script inside a downloaded bundle.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Menu', 'Choose', 'Backup', 'Restore', 'Report', 'ExtendRollback', 'Cleanup', 'RemoveRollback')]
    [string]$Action = 'Menu',
    # Override config.json for this run only.
    [string[]]$Folders,
    [string[]]$Destinations,
    # Any of Drivers, Apps, Wifi.
    [string[]]$Skip,
    [switch]$DryRun,
    [switch]$NoUpload,
    # Restore: folder holding manifest.json. Defaults to this script's folder.
    [string]$BundlePath,
    # Restore: pass winget's --accept-package-agreements and --accept-source-agreements.
    [switch]$AcceptAgreements,
    # Restore: pull the folders and files back from the first reachable destination.
    [switch]$RestoreUserData,
    [ValidateRange(2, 60)]
    [int]$RollbackDays = 60
)

$ErrorActionPreference = 'Stop'

# Resolved here, not in the param block: $PSScriptRoot is empty there under powershell -File.
$scriptPath = $MyInvocation.MyCommand.Path
$scriptDir = Split-Path -Parent $scriptPath
$configPath = Join-Path $scriptDir 'config.json'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

$config = [ordered]@{
    destinations        = @()
    folders             = @('Documents', 'Desktop', 'Pictures')
    include             = @('Drivers', 'Apps', 'Wifi')
    exportWifiPasswords = $false
    exclude             = @('.venv/**', 'node_modules/**', '__pycache__/**')
    rcloneArgs          = @('--transfers', '4', '--progress')
}
if (Test-Path -LiteralPath $configPath) {
    $saved = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    foreach ($key in @($config.Keys)) {
        if ($null -ne $saved.$key) { $config[$key] = $saved.$key }
    }
}

function Split-List {
    # powershell -File passes "a,b" as one string, so split it ourselves.
    param([string[]]$Values)
    @($Values | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if ($Folders) { $config.folders = Split-List $Folders }
if ($Destinations) { $config.destinations = Split-List $Destinations }
if ($Skip) { $config.include = @($config.include | Where-Object { (Split-List $Skip) -notcontains $_ }) }

function Save-Config {
    # Lists are recast to plain string arrays; PS 5.1 can serialize arrays read from JSON as {value, Count}.
    $out = [ordered]@{}
    foreach ($key in $config.Keys) {
        if ($config[$key] -is [bool]) { $out[$key] = $config[$key] } else { $out[$key] = [string[]]@($config[$key]) }
    }
    $out | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $configPath -Encoding utf8
    Write-Host "Saved to $configPath"
}

function Assert-Admin {
    if (-not $isAdmin) { throw 'This needs an elevated PowerShell (Run as administrator).' }
}

function Resolve-UserPath {
    param([string]$Name)
    # Known folders are resolved through the shell so OneDrive redirection is honoured.
    $known = @{ Documents = 'MyDocuments'; Desktop = 'Desktop'; Pictures = 'MyPictures'; Music = 'MyMusic'; Videos = 'MyVideos' }
    if ($known.ContainsKey($Name)) { return [Environment]::GetFolderPath($known[$Name]) }
    if ([IO.Path]::IsPathRooted($Name)) { return $Name }
    return (Join-Path $env:USERPROFILE $Name)
}

function Get-RcloneRemotes {
    if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) { return @() }
    return @(& rclone listremotes)
}

function Get-DestinationProblem {
    param([string]$Destination)
    if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
        return 'rclone is not installed (winget install Rclone.Rclone)'
    }
    # A one-letter prefix is a drive letter, so only longer names are rclone remotes.
    if ($Destination -match '^([^:\\/]{2,}):' -and (Get-RcloneRemotes) -notcontains "$($Matches[1]):") {
        return "rclone remote '$($Matches[1])' is not configured (run: rclone config)"
    }
    return $null
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Body, [switch]$NeedsAdmin)
    if ($NeedsAdmin -and -not $isAdmin) {
        Write-Warning "$Name skipped: needs an elevated PowerShell."
        $script:steps[$Name] = 'skipped (not elevated)'
        return
    }
    Write-Host "==> $Name"
    try {
        & $Body
        $script:steps[$Name] = 'ok'
    } catch {
        Write-Warning "$Name failed: $($_.Exception.Message)"
        $script:steps[$Name] = "failed: $($_.Exception.Message)"
    }
}

function Invoke-Rclone {
    param([string]$Source, [string]$Target)
    # Per-file messages go to the log so the terminal only shows progress.
    $rcloneArgs = @('copy', $Source, $Target, '--log-file', $logFile) + @($config.rcloneArgs)
    foreach ($pattern in @($config.exclude)) { $rcloneArgs += '--exclude', $pattern }
    if ($DryRun) { $rcloneArgs += '--dry-run' }
    & rclone @rcloneArgs
    if ($LASTEXITCODE -ne 0) { throw "rclone exited with code $LASTEXITCODE" }
}

function Select-Items {
    param([string]$Title, [string[]]$Offered, [string[]]$Current, [string]$CustomHint)
    $all = New-Object System.Collections.Generic.List[string]
    $picked = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Offered) + @($Current)) { if ($item -and -not $all.Contains($item)) { $all.Add($item) } }
    foreach ($item in @($Current)) { if ($item) { $picked.Add($item) } }

    while ($true) {
        Write-Host ''
        Write-Host $Title
        for ($i = 0; $i -lt $all.Count; $i++) {
            $mark = ' '
            if ($picked.Contains($all[$i])) { $mark = 'x' }
            Write-Host ('  {0,2}. [{1}] {2}' -f ($i + 1), $mark, $all[$i])
        }
        $prompt = 'Numbers to toggle'
        if ($CustomHint) { $prompt += ", or type $CustomHint to add it" }
        $answer = "$(Read-Host "$prompt (Enter = done)")".Trim()
        if (-not $answer) { break }

        if ($answer -match '^[\d,\s]+$') {
            foreach ($number in ($answer -split '[,\s]+' | Where-Object { $_ })) {
                $index = [int]$number - 1
                if ($index -lt 0 -or $index -ge $all.Count) { continue }
                if ($picked.Contains($all[$index])) { [void]$picked.Remove($all[$index]) } else { $picked.Add($all[$index]) }
            }
        } elseif ($CustomHint) {
            $item = $answer.Trim('"')
            if (-not $all.Contains($item)) { $all.Add($item) }
            if (-not $picked.Contains($item)) { $picked.Add($item) }
        }
    }
    return $picked.ToArray()
}

function Invoke-Choose {
    $config.include = @(Select-Items 'What to capture from this PC' @('Drivers', 'Apps', 'Wifi') $config.include)
    $config.folders = @(Select-Items 'Folders and files to back up' `
            @('Documents', 'Desktop', 'Pictures', 'Music', 'Videos', 'Downloads') $config.folders 'a full path')
    $offered = @(Get-RcloneRemotes | ForEach-Object { "${_}insider-safety-net" })
    $config.destinations = @(Select-Items 'Where to upload' $offered $config.destinations `
            'remote:path (e.g. terabox:insider-safety-net) or a local folder')
    Save-Config
}

function Get-BackupItems {
    $items = @()
    $used = @()
    foreach ($name in @($config.folders)) {
        $source = Resolve-UserPath $name
        if (-not (Test-Path -LiteralPath $source)) {
            Write-Warning "Not found, skipping: $source"
            continue
        }
        $isFile = Test-Path -LiteralPath $source -PathType Leaf
        if ($isFile) {
            $remoteDir = 'files'
        } else {
            $remoteDir = (Split-Path $source -Leaf) -replace '[:\\/]', ''
            if ($used -contains $remoteDir) { $remoteDir = "$remoteDir-$($used.Count)" }
            $used += $remoteDir
        }
        $items += [ordered]@{ name = $name; source = $source; remoteDir = $remoteDir; isFile = $isFile }
    }
    return $items
}

function Invoke-Backup {
    $script:steps = [ordered]@{}
    $outputRoot = Join-Path $scriptDir 'bundles'
    $bundleDir = Join-Path $outputRoot $env:COMPUTERNAME
    $logFile = Join-Path $outputRoot ('rclone-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    # The bundle is regenerated every run; the previous one is this script's own output.
    if (Test-Path -LiteralPath $bundleDir) { Remove-Item -LiteralPath $bundleDir -Recurse -Force }
    New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null

    Invoke-Step 'System info' {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $cs = Get-CimInstance Win32_ComputerSystem
        $selfHost = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\Applicability' -ErrorAction SilentlyContinue
        $license = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" |
            Select-Object -First 1
        # The full key is deliberately not written out; a firmware key survives a reinstall on its own.
        $firmwareKey = (Get-CimInstance SoftwareLicensingService).OA3xOriginalProductKey

        [ordered]@{
            computerName       = $env:COMPUTERNAME
            manufacturer       = $cs.Manufacturer
            model              = $cs.Model
            productName        = (Get-CimInstance Win32_OperatingSystem).Caption
            edition            = $cv.EditionID
            displayVersion     = $cv.DisplayVersion
            build              = '{0}.{1}' -f $cv.CurrentBuild, $cv.UBR
            architecture       = $env:PROCESSOR_ARCHITECTURE
            insiderBranch      = $selfHost.BranchName
            licenseDescription = $license.Description
            licenseStatus      = $license.LicenseStatus
            partialProductKey  = $license.PartialProductKey
            firmwareKeyPresent = [bool]$firmwareKey
        } | ConvertTo-Json | Out-File (Join-Path $bundleDir 'system-info.json') -Encoding utf8
    }

    Invoke-Step 'BitLocker status' -NeedsAdmin {
        $volume = Get-BitLockerVolume -MountPoint $env:SystemDrive
        $volume | Select-Object MountPoint, VolumeStatus, ProtectionStatus, EncryptionPercentage |
            ConvertTo-Json | Out-File (Join-Path $bundleDir 'bitlocker.json') -Encoding utf8
        if ($volume.ProtectionStatus -eq 'On') {
            Write-Warning 'The system drive is encrypted. Confirm your recovery key is saved at https://account.microsoft.com/devices/recoverykey. It is not copied into this bundle.'
        }
    }

    if ($config.include -contains 'Drivers') {
        Invoke-Step 'Driver export' -NeedsAdmin {
            $driverDir = Join-Path $bundleDir 'drivers'
            New-Item -ItemType Directory -Path $driverDir -Force | Out-Null
            Export-WindowsDriver -Online -Destination $driverDir | Out-Null
        }
    }

    if ($config.include -contains 'Apps') {
        Invoke-Step 'App list' {
            & winget export -o (Join-Path $bundleDir 'apps.json') --disable-interactivity | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "winget exited with code $LASTEXITCODE" }
        }
    }

    if ($config.include -contains 'Wifi') {
        Invoke-Step 'Wi-Fi profiles' {
            $wifiDir = Join-Path $bundleDir 'wifi'
            New-Item -ItemType Directory -Path $wifiDir -Force | Out-Null
            $netshArgs = @('wlan', 'export', 'profile', "folder=$wifiDir")
            if ($config.exportWifiPasswords) { $netshArgs += 'key=clear' }
            & netsh @netshArgs | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "netsh exited with code $LASTEXITCODE" }
        }
    }

    $items = @(Get-BackupItems)
    $targets = @($config.destinations | Where-Object { $_ } | ForEach-Object { '{0}/{1}' -f $_.TrimEnd('\', '/'), $env:COMPUTERNAME })

    # Travels with the bundle so a fresh install only needs this one folder to restore.
    Copy-Item -LiteralPath $scriptPath -Destination $bundleDir
    $writeManifest = {
        [ordered]@{
            computerName = $env:COMPUTERNAME
            created      = (Get-Date -Format 'o')
            destinations = $targets
            items        = $items
            steps        = $script:steps
        } | ConvertTo-Json -Depth 5 | Out-File (Join-Path $bundleDir 'manifest.json') -Encoding utf8
    }
    & $writeManifest

    if ($NoUpload) {
        # Nothing to send.
    } elseif (-not $targets) {
        Write-Warning 'No destinations configured, nothing uploaded. Pick some with -Action Choose.'
    } else {
        foreach ($target in $targets) {
            $problem = Get-DestinationProblem $target
            if ($problem) {
                Write-Warning "$target skipped: $problem"
                $script:steps[$target] = "skipped: $problem"
                continue
            }
            foreach ($item in $items) {
                Invoke-Step "$target <- $($item.name)" { Invoke-Rclone $item.source "$target/userdata/$($item.remoteDir)" }
            }
            Invoke-Step "$target <- bundle" { Invoke-Rclone $bundleDir "$target/system" }
        }
    }

    # Rewritten so the local copy also records how the uploads went.
    & $writeManifest

    Write-Host ''
    Write-Host "Bundle: $bundleDir"
    if (Test-Path -LiteralPath $logFile) { Write-Host "Upload log: $logFile" }
    $script:steps.GetEnumerator() | ForEach-Object { Write-Host ('  {0,-40} {1}' -f $_.Key, $_.Value) }
}

function Invoke-Restore {
    $bundle = $BundlePath
    if (-not $bundle) { $bundle = $scriptDir }
    $manifestPath = Join-Path $bundle 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "No manifest.json in $bundle. Run the copy of this script inside a downloaded bundle, or pass -BundlePath."
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

    $driverDir = Join-Path $bundle 'drivers'
    if (Test-Path -LiteralPath $driverDir) {
        if ($isAdmin) {
            Write-Host '==> Drivers'
            & pnputil /add-driver "$driverDir\*.inf" /subdirs /install
            # 259 = nothing newer to install, 3010 = installed, reboot needed.
            if ($LASTEXITCODE -notin 0, 259, 3010) { Write-Warning "pnputil exited with code $LASTEXITCODE" }
        } else {
            Write-Warning 'Drivers skipped: needs an elevated PowerShell.'
        }
    }

    $appList = Join-Path $bundle 'apps.json'
    if (Test-Path -LiteralPath $appList) {
        Write-Host '==> Apps'
        $wingetArgs = @('import', '-i', $appList, '--ignore-unavailable')
        if ($AcceptAgreements) { $wingetArgs += '--accept-package-agreements', '--accept-source-agreements' }
        & winget @wingetArgs
        if ($LASTEXITCODE -ne 0) { Write-Warning "winget exited with code $LASTEXITCODE (some apps may need a manual install)" }
    }

    $wifiDir = Join-Path $bundle 'wifi'
    if (Test-Path -LiteralPath $wifiDir) {
        Write-Host '==> Wi-Fi profiles'
        foreach ($wifiProfile in Get-ChildItem -LiteralPath $wifiDir -Filter '*.xml') {
            & netsh wlan add profile "filename=$($wifiProfile.FullName)" user=current | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Warning "Could not import $($wifiProfile.Name)" }
        }
    }

    if (-not $RestoreUserData) { return }
    $source = @($manifest.destinations | Where-Object { -not (Get-DestinationProblem $_) }) | Select-Object -First 1
    if (-not $source) {
        Write-Warning "None of the backup destinations is reachable: $($manifest.destinations -join ', '). Install rclone and recreate the remote under the same name, then rerun."
        return
    }
    foreach ($item in $manifest.items) {
        $target = Resolve-UserPath $item.name
        $from = "$source/userdata/$($item.remoteDir)"
        if ($item.isFile) {
            $from = "$from/$(Split-Path $item.source -Leaf)"
            $target = Split-Path $target -Parent
        }
        Write-Host "==> $from -> $target"
        & rclone copy $from $target --progress
        if ($LASTEXITCODE -ne 0) { Write-Warning "rclone exited with code $LASTEXITCODE for $($item.name)" }
    }
}

function Show-Report {
    $drive = $env:SystemDrive
    $paths = [ordered]@{
        'Windows.old (rollback)'   = "$drive\Windows.old"
        'Upgrade staging'          = "$drive\`$WINDOWS.~BT"
        'Setup staging'            = "$drive\`$WINDOWS.~WS"
        'Windows Update downloads' = "$env:SystemRoot\SoftwareDistribution\Download"
    }
    foreach ($entry in $paths.GetEnumerator()) {
        $size = 'not present'
        if (Test-Path -LiteralPath $entry.Value) {
            $sum = (Get-ChildItem -LiteralPath $entry.Value -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum).Sum
            $size = '{0:N2} GB' -f ($sum / 1GB)
        }
        Write-Host ('  {0,-26} {1}' -f $entry.Key, $size)
    }
    if (-not $isAdmin) { Write-Warning 'Not elevated: sizes only count files this account can read.' }
}

function Set-RollbackWindow {
    Assert-Admin
    # Fails with "element not found" until a build upgrade has created Windows.old.
    & dism /Online /Set-OSUninstallWindow /Value:$RollbackDays
    if ($LASTEXITCODE -ne 0) { Write-Warning "DISM exited with code $LASTEXITCODE (is there a previous build to roll back to?)" }
}

function Invoke-Cleanup {
    Assert-Admin
    & dism /Online /Cleanup-Image /StartComponentCleanup
    Delete-DeliveryOptimizationCache -Force
}

function Remove-Rollback {
    Assert-Admin
    if ($PSCmdlet.ShouldProcess('Windows.old', 'Delete rollback files; you will not be able to go back to the previous build')) {
        & dism /Online /Remove-OSUninstall
        if ($LASTEXITCODE -ne 0) { Write-Warning "DISM exited with code $LASTEXITCODE" }
    }
}

function Invoke-Action {
    param([string]$Name)
    switch ($Name) {
        'Choose' { Invoke-Choose }
        'Backup' { Invoke-Backup }
        'Restore' { Invoke-Restore }
        'Report' { Show-Report }
        'ExtendRollback' { Set-RollbackWindow }
        'Cleanup' { Invoke-Cleanup }
        'RemoveRollback' { Remove-Rollback }
    }
}

if ($Action -ne 'Menu') {
    Invoke-Action $Action
    return
}

$menu = [ordered]@{
    '1' = @('Choose what to back up and where', 'Choose')
    '2' = @('Back up now', 'Backup')
    '3' = @('Back up, dry run (uploads nothing)', 'DryRun')
    '4' = @('Restore from this bundle (drivers, apps, Wi-Fi, files)', 'Restore')
    '5' = @('Show space used by upgrade leftovers', 'Report')
    '6' = @("Extend the rollback window to $RollbackDays days", 'ExtendRollback')
    '7' = @('Clean up update caches', 'Cleanup')
    '8' = @('Delete Windows.old (no going back)', 'RemoveRollback')
}
while ($true) {
    Write-Host ''
    Write-Host 'Insider Safety Net'
    if (-not $isAdmin) { Write-Host '  (not elevated: drivers, BitLocker status and options 6-8 are unavailable)' }
    Write-Host "  Back up:  $(@($config.include) + @($config.folders) -join ', ')"
    Write-Host "  Upload to: $(@($config.destinations) -join ', ')"
    foreach ($entry in $menu.GetEnumerator()) { Write-Host ('  {0}. {1}' -f $entry.Key, $entry.Value[0]) }
    Write-Host '  0. Exit'
    $choice = "$(Read-Host 'Choose')".Trim()
    if ($choice -eq '0' -or -not $choice) { break }
    if (-not $menu.Contains($choice)) { continue }

    $selected = $menu[$choice][1]
    try {
        if ($selected -eq 'DryRun') {
            $DryRun = $true
            Invoke-Backup
            $DryRun = $false
        } elseif ($selected -eq 'Restore') {
            # From the menu, restore everything; winget still asks about agreements itself.
            $RestoreUserData = $true
            Invoke-Restore
        } else {
            Invoke-Action $selected
        }
    } catch {
        $DryRun = $false
        Write-Warning $_.Exception.Message
    }
}
