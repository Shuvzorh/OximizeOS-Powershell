# OximizeOS PowerShell

Windows 11 ISO optimizer with a WinForms GUI built in PowerShell.


![OximizeOS UI](image/OximizeOS.png)

## One-Command Run

Open PowerShell and run:

```powershell
irm "https://raw.githubusercontent.com/Shuvzorh/OximizeOS-Powershell/main/win.ps1" | iex
```

This downloads and launches the latest `OximizeOS.ps1` from the GitHub repo.

## Run Locally

1. Download or clone this repository.
2. Open the folder.
3. Run:

```powershell
.\Run Oximize OS.cmd
```

You can also run directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\OximizeOS.ps1
```

## Requirements

- Windows host.
- Administrator rights (script auto-elevates).
- Official Windows 11 ISO source.
- PowerShell 5.1 or newer.
- DISM tools available on Windows.
- `oscdimg.exe` for final ISO creation.

Notes:
- The script can attempt official Microsoft ADK bootstrap for `oscdimg` if missing.
- Keep enough free disk space (recommended at least 2x source ISO size).

## What OximizeOS Does

- Mounts source ISO and copies files to a dedicated temp build directory.
- Reads `install.wim` or converts `install.esd` to `install.wim`.
- Lets you select the target edition index.
- Applies selected debloat actions:
  - Appx package removal
  - Optional feature/capability state changes
  - Scheduled task configuration
  - Service startup mode configuration
  - Privacy, security, and advanced registry-backed tweaks
- Supports security presets:
  - `Balanced`
  - `Hardened`
  - `Maximum`
- Supports driver workflows:
  - Export drivers from current system
  - Inject `.inf` packages into `install.wim`
- Generates/merges unattended setup XML.
- Writes first-startup and setup scripts used by the customized image.
- Stages custom files into ISO payload:
  - `CustomUnattendXml`
  - `.reg` files
  - `.bat`/`.cmd` files
- Exports single-edition optimized WIM and rebuilds a bootable BIOS+UEFI ISO.
- Writes a session log file:
  - `OximizeOS_yyyyMMdd_HHmmss_fff.log`

## GUI Pages

- App Packages
- Features & Capabilities
- Driver Packages
- Security Baselines
- Security Hardening
- Privacy & Security
- Task Scheduler
- Windows Services
- Advanced Setup
- Logs (shown standalone while build runs)

## Configuration Profiles

The Settings menu supports:

- `Import` (`.ox`)
- `Export` (`.ox`)

Use this to reuse your tuning profile across multiple ISOs.

## Typical Build Flow

1. Select Source ISO, Output ISO path, and TempBuildDirectory.
2. Choose your debloat/security/privacy options.
3. Start build and monitor live logs.
4. Oximize performs mount -> modify -> commit -> rebuild.
5. Final ISO is written to your output path.

## Troubleshooting

`oscdimg.exe` missing:
- Install Windows ADK Deployment Tools, or place `oscdimg.exe` in:
  - `.\tools\oscdimg.exe`
  - or next to `OximizeOS.ps1`

Source ISO rejected:
- Use an official Windows 11 ISO.
- Windows 10 images are blocked by design.

Low disk space:
- Free more space or use a drive with higher free capacity.

Output ISO disappears:
- Do not place output path inside TempBuildDirectory.
- TempBuildDirectory is cleaned after successful runs.

WIM mount/unmount errors (`0xc1420117`, mount already in use, failed unmount):
- Run the recovery helper as Administrator:
  - `.\Fix-Stuck-WIM-Mount.cmd "C:\Path\To\Your\WIMMountFolder"`
- Legacy alias still works:
  - `.\wimremove.cmd "C:\Path\To\Your\WIMMountFolder"`
- If you run without an argument, the script will prompt for the mount folder path.
