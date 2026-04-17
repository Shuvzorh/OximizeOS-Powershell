<div align="center">

<img src="image/OximizeOS.png" alt="OximizeOS Logo" width="160"/>

# OximizeOS PowerShell

**A PowerShell + WinForms tool for building customized, bootable Windows 11 ISOs.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows-0078d4?logo=windows)](https://www.microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell)](https://github.com/PowerShell/PowerShell)

</div>

---

## Overview

OximizeOS takes an official Windows 11 ISO and lets you customize it end-to-end — removing bloat, hardening security, injecting drivers, and baking in unattended setup — then rebuilds it into a clean, bootable BIOS+UEFI ISO ready to flash or deploy.

---

## Features

| Category | What You Can Do |
|---|---|
| **Debloat** | Remove inbox app packages selectively |
| **Features & Capabilities** | Toggle optional Windows features and capabilities |
| **Privacy** | Apply privacy-focused registry and policy settings |
| **Security Baselines** | Choose from `Balanced`, `Hardened`, or `Maximum` security presets |
| **Security Hardening** | Fine-tune additional hardening tweaks |
| **Services** | Disable or configure Windows services |
| **Task Scheduler** | Manage scheduled tasks |
| **Drivers** | Export drivers from the host machine or inject `.inf` packages into the image |
| **Unattend XML** | Merge or replace the setup unattend configuration |
| **Custom Payloads** | Inject `.reg`, `.bat`, and `.cmd` scripts into the setup pipeline |
| **Configuration Profiles** | Save and reuse your full selection as a `.ox` profile file |

---

## Quick Start

### ▶ One-command launcher (online)

```powershell
irm "https://raw.githubusercontent.com/Shuvzorh/OximizeOS-Powershell/main/win.ps1" | iex
```

The bootstrapper downloads the latest `OximizeOS.ps1`, validates its syntax, and launches the GUI automatically.

### ▶ Run from a local clone

```powershell
& ".\Run Oximize OS.cmd"
```

Or launch directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\OximizeOS.ps1
```

---

## Requirements

- **OS:** Windows (host machine)
- **Privileges:** Administrator rights *(script auto-elevates if needed)*
- **PowerShell:** 5.1 or later
- **Source:** Official Windows 11 ISO
- **DISM:** Standard on all modern Windows installs
- **`oscdimg.exe`:** Required for final ISO creation — see below

### Getting `oscdimg.exe`

OximizeOS checks the following locations in order:

1. `./tools/oscdimg.exe` *(recommended — drop it here)*
2. Same directory as `OximizeOS.ps1`
3. ADK Deployment Tools install path *(auto-detected)*

If none are found, install the **Windows ADK Deployment Tools**:
👉 https://learn.microsoft.com/windows-hardware/get-started/adk-install

---

## Build Workflow

```
Source ISO  ──►  Mount  ──►  Apply Customizations  ──►  Commit  ──►  Export WIM  ──►  Rebuild ISO
```

1. **Select** your source ISO, output path, and temp build directory.
2. **Configure** packages, features, services, tasks, security, and privacy options.
3. *(Optional)* Add a custom unattend XML, `.reg` patches, and setup scripts.
4. **Start Build** and follow the live log output.
5. Collect your finished bootable ISO from the output path.

---

## GUI Tabs

- **App Packages** — Select inbox apps to remove
- **Features & Capabilities** — Toggle Windows optional features
- **Driver Packages** — Export or inject hardware drivers
- **Security Baselines** — Apply a security preset (Balanced / Hardened / Maximum)
- **Security Hardening** — Additional hardening controls
- **Privacy & Security** — Registry and policy privacy tweaks
- **Task Scheduler** — Enable or disable scheduled tasks
- **Windows Services** — Configure service startup behavior
- **Advanced Setup** — Unattend XML, custom scripts, and payload injection
- **Logs** — Real-time build log viewer

---

## Configuration Profiles

Save your entire selection to a reusable profile:

- **Export:** `Settings → Export Profile` → saves a `.ox` file
- **Import:** `Settings → Import Profile` → loads a `.ox` file

---

## Logging

Session logs are written automatically:

```
OximizeOS_yyyyMMdd_HHmmss_fff.log
```

| Run Mode | Log Location |
|---|---|
| Local clone | Script directory |
| Bootstrap (`irm \| iex`) | `%USERPROFILE%\Documents\OximizeOS\Logs` |

---

## Troubleshooting

### `oscdimg.exe` not found

Place `oscdimg.exe` in `./tools/oscdimg.exe` next to the script, or install the [Windows ADK Deployment Tools](https://learn.microsoft.com/windows-hardware/get-started/adk-install).

### Source ISO rejected

Only **Windows 11** ISOs are supported. Windows 10 sources are intentionally blocked.

### Low disk space / failed WIM export

- Keep at least **2× the source ISO size** free on your temp build drive.
- Set the output ISO path to a **different drive** from your temp directory.

### Stuck WIM mount / unmount errors (`0xc1420117`)

Run as Administrator:

```powershell
.\Fix-Stuck-WIM-Mount.cmd "C:\Path\To\Your\WIMMountFolder"
```

Legacy alias (if present):

```powershell
.\wimremove.cmd "C:\Path\To\Your\WIMMountFolder"
```

---

## Repository Files

| File | Purpose |
|---|---|
| `OximizeOS.ps1` | Main GUI and build pipeline |
| `win.ps1` | Online bootstrap / launcher |
| `Run Oximize OS.cmd` | Local launch helper |
| `Fix-Stuck-WIM-Mount.cmd` | Recovery tool for stuck DISM mounts |

---

## License

This project is licensed under the **MIT License** — see [LICENSE](LICENSE) for details.
