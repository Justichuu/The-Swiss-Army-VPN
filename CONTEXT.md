# Swiss Army VPN — working notes

For people changing the code. For people using the app, start at [the short book](docs/book/README.md).

## What this is

A Windows tray window around one IKEv2 profile named Swiss Army VPN, plus a fail-closed kill switch. Justichuu's project. Unofficial. Not NordVPN the company.

The lock can cut the whole computer off the internet. **DISCONNECT + UNLOCK** or Emergency Unlock gives it back.

## Version

Source on `main` is `1.5.0.0`. The installer refuses to replace the same version, so a new package needs a new fourth number (`1.5.0.0`, `1.5.0.1`). Tags look like `v1.5.0.0`.

Produced versions are four-part. Old installs may still show three-part. Readers of old records stay loose: `^\d+\.\d+\.\d+(\.\d+)?$`.

A managed upgrade also checks the existing folder. Keep the file list exact. Do not add an install file without updating that list and the version.

## Things that bit people

**Teredo / ISATAP / 6to4.** The lock cannot cover those tunnels. Arming refuses. The message now gives the `netsh` line to turn the tunnel off, and how to turn it back on. Do not relax the check.

**v1.3.1 / v1.3.2.** Tag and version got out of step. An upgrade validator still wanted an old file count. Fixed in v1.3.3. The write-up is in `docs/incidents/`.

**Same-version replace.** One fix can burn more than one package number. That is why the fourth segment exists.

## Tree

```
src/         Windows app, installer, unlock
installer/   scripts and seed servers
docs/        book, incidents, demo film
scripts/     build and scrubber
assets/      icon and art
artifacts/   build output, not in git
tests/       witnesses
```

## Build

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Release.ps1
```

Output: `artifacts/builds/<version>/`.

## Safety

- No login in the repo
- No GitHub token in the app
- Private updates need GitHub CLI 2.96+ and a signed-in person who can read this repository
- Share a scrubbed dump, not `install-state.json`
- Report a hole in GitHub security advisories

## People

Justichuu. https://github.com/Justichuu

This file does not keep a list of drafting tools.
