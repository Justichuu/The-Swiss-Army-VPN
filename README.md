# Justichuu's Swiss Army VPN

A small Windows window for a VPN that Windows already knows how to run. It can lock the rest of the internet if that VPN drops.

![Swiss Army VPN remaining states](docs/media/vpn-working-demo/vpn-working-demo.gif)

Bring your own login. This is not a VPN shop. This is not NordVPN the company.

If you have never installed a tool from GitHub, start at [the pamphlet](docs/book/en/PAMPHLET.md) or [Start here](docs/book/en/START.md). Other languages live in [the short book](docs/book/README.md).

Green shut eye: hidden. Red open eye: watched. The lid moves; a hidden eye does not blink open.

## What it does

- Connects one Windows IKEv2 profile named Swiss Army VPN
- Can arm a whole-computer kill switch
- Can show tunnel traffic and a protected ping when you ask
- Lets you pick a Swiss server, another official NordVPN host, or any safe IKEv2 host you bring
- Checks release files by checksum
- Installs, uninstalls, and has Emergency Unlock

## Install

1. Open the [latest GitHub Release](https://github.com/Justichuu/The-Swiss-Army-VPN/releases/latest).
2. Download `Swiss Army VPN Distribution <VERSION>.zip`. Do not use the green **Code → Download ZIP** button. That zip is source, not the app.
3. Keep the matching source zip beside it if you share the app.
4. Extract the folder. Do not split the files.
5. Run `Install Swiss Army VPN.exe`.
6. Open the window. Choose **SET UP SIGN-IN**. Type the username and password for this VPN.

Installing or changing the lock needs administrator permission. Logins are never in the zip.

## Choose a server

The **SERVER** box lists the packaged Swiss pool. Pick one or type a host, then **APPLY**. The mode next to **CURRENT** is the check:

- **Swiss NordVPN** wants `ch<number>.nordvpn.com`
- **Any NordVPN** allows `us1234.nordvpn.com`
- **Bring your own** allows a safe IKEv2 hostname or IPv4 address

Bring-your-own still uses Windows IKEv2 and the login from **SET UP SIGN-IN**. WireGuard and OpenVPN are not driven by this window. Fresh installs start on the packaged Swiss server.

Disconnect and unlock before changing servers. The Start menu item **Choose Swiss VPN Server** can pick a quiet Swiss host by itself.

Private updates need GitHub CLI 2.96+ and `gh auth login` with a person who can read this repository. The app does not store that token.

## Build

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Release.ps1
```

Output goes to `artifacts\builds\<version>\`.

## Important

The kill switch can cut the whole computer off the internet. That is the point. **DISCONNECT + UNLOCK** gives the net back. If the window is gone, use Emergency Unlock.

Builds are unsigned. SmartScreen may complain. The verifier checks checksums. It does not sign the file.

![Swiss Army VPN roadmap](ROADMAP.png)

## Love

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

The Nord app is heavy. This is unofficial. Not affiliated. GPL-3.0-only.

Justichuu on GitHub: https://github.com/Justichuu
