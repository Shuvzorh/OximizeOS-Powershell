# OximizeOS PowerShell

OximizeOS is a PowerShell + WinForms tool that customizes **official Windows 11 ISOs** and rebuilds a bootable BIOS+UEFI ISO.

![OximizeOS GUI](image/OximizeOS.png)

## What It Does

- Mounts a Windows 11 ISO and stages build files in a temporary workspace.
- Reads `install.wim` (or converts `install.esd` to `install.wim` when needed).
- Lets you choose the target Windows edition index.
- Applies debloat, privacy, service, task, feature, capability, and hardening selections.
- Supports security presets: `Balanced`, `Hardened`, `Maximum`.
- Supports driver workflows:
  - Export drivers from the current machine.
  - Inject `.inf` driver packages into `install.wim`.
- Merges or uses custom unattended setup XML.
- Stages custom `.reg`, `.bat`, and `.cmd` payloads.
- Exports a single-index optimized WIM and builds a bootable ISO.

## Quick Start

### One-command online launcher

```powershell
irm "https://raw.githubusercontent.com/Shuvzorh/OximizeOS-Powershell/main/win.ps1" | iex
```

This bootstrapper downloads the latest `OximizeOS.ps1`, validates syntax, and launches the GUI.

### Run from local clone

```powershell
& ".\Run Oximize OS.cmd"
```

Or run directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\OximizeOS.ps1
```

## Requirements

- Windows host.
- Administrator rights (the script auto-elevates if needed).
- PowerShell 5.1+.
- Official Windows 11 ISO source.
- DISM tooling available (standard on Windows).
- `oscdimg.exe` for final ISO creation.

### About `oscdimg.exe`

OximizeOS first checks local paths (including `./tools/oscdimg.exe`). If missing, it attempts an official Microsoft ADK bootstrap path. If provisioning still fails, install ADK Deployment Tools manually:

https://learn.microsoft.com/windows-hardware/get-started/adk-install

## Build Flow

1. Choose **Source ISO**, **Output ISO**, and **Temp Build Directory**.
2. Select app packages, features/capabilities, task/service settings, and security/privacy options.
3. (Optional) add custom unattend XML, `.reg`, and setup scripts.
4. Start the build and monitor live logs.
5. OximizeOS performs mount -> modify -> commit -> export -> ISO rebuild.

## GUI Areas

- App Packages
- Features & Capabilities
- Driver Packages
- Security Baselines
- Security Hardening
- Privacy & Security
- Task Scheduler
- Windows Services
- Advanced Setup
- Logs

## Configuration Profiles

Use **Settings -> Import/Export** to save and reuse profile files:

- Import: `*.ox`
- Export: `*.ox`

## Logging

Session logs are named:

`OximizeOS_yyyyMMdd_HHmmss_fff.log`

Default log location:

- Normal local run: script directory.
- Bootstrap/temp run (including `irm ... | iex`):
  `%USERPROFILE%\Documents\OximizeOS\Logs`

## Troubleshooting

### `oscdimg.exe` not found

- Install ADK Deployment Tools, or
- Place `oscdimg.exe` in one of these locations:
  - `./tools/oscdimg.exe`
  - next to `OximizeOS.ps1`

### Source ISO rejected

- Only Windows 11 ISOs are supported.
- Windows 10 sources are blocked by design.

### Low disk space / failed export

- Keep free space well above source ISO size (2x minimum recommended).
- Keep output ISO path outside your temp build directory.

### Stuck WIM mount / unmount errors (`0xc1420117`, mount already in use)

Run as Administrator:

```powershell
.\Fix-Stuck-WIM-Mount.cmd "C:\Path\To\Your\WIMMountFolder"
```

Legacy alias (if present in your setup):

```powershell
.\wimremove.cmd "C:\Path\To\Your\WIMMountFolder"
```

## Repository Files

- `OximizeOS.ps1` - main GUI and build pipeline.
- `win.ps1` - online bootstrap launcher.
- `Run Oximize OS.cmd` - local launcher helper.
- `Fix-Stuck-WIM-Mount.cmd` - recovery helper for stuck DISM mounts.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
