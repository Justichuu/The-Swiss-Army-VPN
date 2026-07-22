# Justichuu's Swiss Army VPN

A lightweight Windows tray widget for a Switzerland IKEv2 VPN, backed by Windows' built-in VPN client.

This project is a learning experience more than anything: an experiment in mixing vibe coding with real technical knowledge. It has already come a long way, and the goal is to keep learning how to build apps that work reliably, scale cleanly, and reach users with no known bugs.

![Switzerland VPN connecting and reporting protected latency](docs/media/vpn-working-demo/vpn-working-demo.gif)

## What it does

- Connects a managed Switzerland VPN profile.
- Arms a whole-computer, fail-closed Windows Firewall kill switch.
- Shows live tunnel traffic and protected latency on demand.
- Includes an optional Swiss server pool and a safe best-server switcher.
- Verifies exact assets from immutable private releases.
- Includes install, uninstall, emergency unlock, and PowerShell backup tools.

## Install

1. Open the [latest GitHub Release](https://github.com/Justichuu/The-Swiss-Army-VPN/releases/latest).
2. Download `Switzerland VPN Distribution <VERSION>.zip`. Do not use the green **Code → Download ZIP** option; that archive contains source code, not the compiled application.
3. Keep the matching `Switzerland VPN Source <VERSION>.zip` beside it when sharing the application.
4. Extract the distribution ZIP and run `Install Switzerland VPN.exe`.
5. Open the widget and choose **SET UP SIGN-IN**.

Release engineering incidents and their corrective actions are documented in
[`docs/incidents`](docs/incidents/).

Credentials are never included. Use valid NordVPN manual-service credentials. Installing or changing protection requires administrator approval.

## Backup Swiss servers

The install keeps one Windows VPN profile so credentials and kill-switch ownership stay unambiguous. If its server stops working, disconnect and unlock first, then open **Choose Swiss VPN Server** from the Start menu. It requests administrator approval, fetches NordVPN's current online Swiss IKEv2 list, chooses the lowest-load server that resolves, and updates the managed profile and installation record together. Advanced users can run `Switch Switzerland VPN Server.ps1 -List` to inspect candidates or add `-Server ch123.nordvpn.com` to select one explicitly. `VPN Servers.txt` is a seed pool used only when the live service is unavailable.

The first release containing a new package file may require one manual install because older exact-allowlist updaters reject unfamiliar files. Run `Install Switzerland VPN.exe`; subsequent compatible releases can update normally. The `.cmd` launcher remains available only as a troubleshooting fallback.

Private updates require system-wide GitHub CLI 2.96+ and `gh auth login` with an account that can read this repository. The account approving the update must have access too. No GitHub token is stored in the app.

## Build

From Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Release.ps1
```

Build output goes to `artifacts\`. The build validates PowerShell syntax, package checksums, executable metadata, and the installer payload.

## Important

The kill switch affects the whole computer while armed. The app may disconnect other active Windows RAS VPN sessions during a controlled connection change. Use **DISCONNECT + UNLOCK** to restore normal internet.

Current builds are unsigned, so Windows SmartScreen may show a warning.

## Woah

```text
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⢻⣿⡗⢶⣤⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣠⣄
⠀⢻⣇⠀⠈⠙⠳⣦⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣤⠶⠛⠋⣹⣿⡿
⠀⠀⠹⣆⠀⠀⠀⠀⠙⢷⣄⣀⣀⣀⣤⣤⣤⣄⣀⣴⠞⠋⠉⠀⠀⠀⢀⣿⡟⠁
⠀⠀⠀⠙⢷⡀⠀⠀⠀⠀⠉⠉⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣠⡾⠋⠀⠀
⠀⠀⠀⠀⠈⠻⡶⠂⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢠⣠⡾⠋⠀⠀⠀⠀
⠀⠀⠀⠀⠀⣼⠃⠀⢠⠒⣆⠀⠀⠀⠀⠀⠀⢠⢲⣄⠀⠀⠀⢻⣆⠀⠀⠀⠀⠀
⠀⠀⠀⠀⢰⡏⠀⠀⠈⠛⠋⠀⢀⣀⡀⠀⠀⠘⠛⠃⠀⠀⠀⠈⣿⡀⠀⠀⠀⠀
⠀⠀⠀⠀⣾⡟⠛⢳⠀⠀⠀⠀⠀⣉⣀⠀⠀⠀⠀⣰⢛⠙⣶⠀⢹⣇⠀⠀⠀⠀
⠀⠀⠀⠀⢿⡗⠛⠋⠀⠀⠀⠀⣾⠋⠀⢱⠀⠀⠀⠘⠲⠗⠋⠀⠈⣿⠀⠀⠀⠀
⠀⠀⠀⠀⠘⢷⡀⠀⠀⠀⠀⠀⠈⠓⠒⠋⠀⠀⠀⠀⠀⠀⠀⠀⠀⢻⡇⠀⠀⠀
⠀⠀⠀⠀⠀⠈⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⣧⠀⠀⠀
⠀⠀⠀⠀⠀⠈⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠁⠀⠀⠀
```

This is an unofficial project cuz Nord app be hefty. It is not affiliated with or endorsed by NordVPN. Licensed under GPL-3.0-only.
