# insider-safety-net

One script, `InsiderSafetyNet.ps1`, that backs up what a clean reinstall cannot give back, restores it, and reclaims disk space after a Windows Insider build installs.

## What it saves

| Item | Where | Needs admin |
| --- | --- | --- |
| OS edition, build, activation status | `system-info.json` | no |
| BitLocker status of the system drive | `bitlocker.json` | yes |
| Third-party drivers (optional) | `drivers/` | yes |
| Installed app list from winget (optional) | `apps.json` | no |
| Wi-Fi profiles (optional) | `wifi/` | no |
| The folders and files you pick | uploaded straight from disk | no |

Product keys and BitLocker recovery keys are never written to the bundle. Wi-Fi passwords are only included if you set `exportWifiPasswords` to `true` in `config.json`; they are then stored in plain text.

Windows install media is not backed up: Microsoft hosts the ISOs, and `system-info.json` records which edition and build you were on.

## Setup

1. Install rclone: `winget install Rclone.Rclone`
2. Create a remote for each cloud you want: `rclone config`

Any rclone remote works as a destination, and so does a local folder such as an external drive. For TeraBox, check that your rclone build has the backend with `rclone help backends`; if `terabox` is listed, create a remote named `terabox` and add `terabox:insider-safety-net` as a destination.

## Use

Run it with no arguments for a menu:

```powershell
powershell -File .\InsiderSafetyNet.ps1
```

Option 1 lets you tick what to capture (drivers, apps, Wi-Fi), which folders or files to back up (type a full path to add your own), and where to upload. Choices are saved to `config.json`.

Or skip the menu:

```powershell
powershell -File .\InsiderSafetyNet.ps1 -Action Backup -DryRun
powershell -File .\InsiderSafetyNet.ps1 -Action Backup
powershell -File .\InsiderSafetyNet.ps1 -Action Backup -Folders "Documents,D:\Projects" -Destinations "gdrive:backup,terabox:backup" -Skip Drivers
powershell -File .\InsiderSafetyNet.ps1 -Action Report
powershell -File .\InsiderSafetyNet.ps1 -Action ExtendRollback -RollbackDays 60
powershell -File .\InsiderSafetyNet.ps1 -Action Cleanup
powershell -File .\InsiderSafetyNet.ps1 -Action RemoveRollback
```

`-Folders`, `-Destinations` and `-Skip` apply to that run only. `RemoveRollback` deletes `Windows.old`; there is no going back to the previous build afterwards.

Each destination gets `<destination>/<COMPUTERNAME>/system` (the bundle) and `<destination>/<COMPUTERNAME>/userdata/...`. Reruns only upload what changed. Folders named in `exclude` (`.venv`, `node_modules`, `__pycache__` by default) are left out.

## Restore

After a clean install, install rclone, recreate the remote under the same name, download the bundle and run the copy of the script inside it from an elevated PowerShell:

```powershell
rclone copy gdrive:insider-safety-net/<COMPUTERNAME>/system C:\restore
powershell -File C:\restore\InsiderSafetyNet.ps1 -Action Restore -AcceptAgreements -RestoreUserData
```
