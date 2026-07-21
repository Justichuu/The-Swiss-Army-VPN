# Jaye's Swiss Army VPN

A lightweight Windows tray widget for a Switzerland IKEv2 VPN, backed by Windows' built-in VPN client.

![Switzerland VPN widget](docs/widget.png)

## What it does

- Connects a managed Switzerland VPN profile.
- Arms a whole-computer, fail-closed Windows Firewall kill switch.
- Shows live tunnel traffic and protected latency on demand.
- Includes install, uninstall, emergency unlock, and PowerShell backup tools.

## Install

1. Download both ZIP files from the latest GitHub Release.
2. Keep the source ZIP with the application ZIP when sharing it.
3. Extract the application ZIP and run `Install Switzerland VPN.cmd`.
4. Open the widget and choose **SET UP SIGN-IN**.

Credentials are never included. Use valid NordVPN manual-service credentials. Installing or changing protection requires administrator approval.

## Build

From Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Release.ps1
```

Build output goes to `artifacts\`. The build validates PowerShell syntax, package checksums, executable metadata, and the installer payload.

## Important

The kill switch affects the whole computer while armed. The app may disconnect other active Windows RAS VPN sessions during a controlled connection change. Use **DISCONNECT + UNLOCK** to restore normal internet.

Current builds are unsigned, so Windows SmartScreen may show a warning.

This is an unofficial project and is not affiliated with or endorsed by NordVPN. Licensed under GPL-3.0-only.
