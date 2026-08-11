# The-Swiss-Army-VPN - Context & State

## Project Overview

Swiss Army VPN project with executable installer and emergency unlock support. Built as a learning experience ("vibe coding experiment") with Justichuu branding.

**What it does:**

- Connects a managed Swiss Army VPN IKEv2 VPN profile (NordVPN credentials)
- Arms a whole-computer, fail-closed Windows Firewall kill switch
- Shows live tunnel traffic and protected latency on demand
- Includes optional Swiss server pool and safe best-server switcher
- Verifies exact assets from immutable private releases
- Provides install, uninstall, emergency unlock, and PowerShell backup tools

**Important:** The kill switch affects the whole computer while armed. The app may disconnect other active Windows RAS VPN sessions during a controlled connection change. Use **DISCONNECT + UNLOCK** to restore normal internet.

## Current Status (as of 2026-07-23)

### v1.4.5.0 - IPv6 transition tunnel guidance (2026-08-11)

- **Reported:** SET UP SIGN-IN, CONNECT, ARM and CONNECT + ARM all failed with
  "The kill switch cannot safely classify this active internet adapter ... Teredo
  Tunneling Pseudo-Interface (type 131)". Every one of those buttons routes through
  `ArmKillSwitchAndVerify()`, which calls `NetworkSafety.AssertSupportedEgress()`.
- **Not a false positive.** The reporting machine's Teredo interface held a qualified
  global address (`2001:0:...`) and a live `::/0` IPv6 default route. Windows Firewall
  rules can only be scoped to `Lan`, `Wireless`, `RemoteAccess`, or `All`; the managed
  rules use `Lan`/`Wireless` so the VPN's own tunnel adapter stays unblocked, which
  leaves a type-131 tunnel genuinely outside the block rules. Refusing to arm is correct.
- **Fixed the message, not the check.** `AssertSupportedEgress()` now recognises Teredo,
  ISATAP, and 6to4 and reports the exact `netsh interface <name> set state disabled`
  command plus how to reverse it. The old text said "Disconnect it", which is impossible
  for a pseudo-interface. No classification was relaxed - the arm still fails.
- Verified by invoking the real method on the affected machine: blocked with the new
  message while Teredo was qualified, passed once Teredo was set to disabled.
- **Copyable command dialog.** `CommandRequiredException` carries the bare command alongside
  the message, and `CommandFailureDialog` shows it with a `Copy Command` button. The command
  goes to the clipboard automatically in `OnShown`; a failed copy says so rather than claiming
  a copy that did not happen. `RunAction` routes only this exception type to the new dialog -
  every other failure keeps the plain message box.
- v1.4.5.0 permits managed upgrades from v1.4.4 and v1.4.5. v1.4.4 shipped the new message
  but not the copyable dialog, and was installed before the dialog existed - hence the extra
  bump. The installer rejects same-version replacement, so every rebuild that reaches an
  installed machine needs its own version.

### Four-part versions from 1.4.5.0 (2026-08-11)

Because same-version replacement is rejected, one fix can burn several patch numbers. The
product version now carries a fourth segment - `1.4.5.0`, `1.4.5.1` - so rebuilds increment
that instead. Release tags follow: `v1.4.5.0`.

- **Produced** versions are strict four-part: `ValidatePattern('^\d+\.\d+\.\d+\.\d+$')` in
  both build scripts. `$expectedAssemblyVersion` is now the version itself, not `$Version + '.0'`.
- **Observed** versions stay permissive, `^\d+\.\d+\.\d+(\.\d+)?$`, everywhere the code reads
  a version it did not produce: install state, ownership markers, the update journal, and
  release tags. Installs recorded before this change hold three-part versions and must keep
  upgrading. `Get-ExpectedFileVersion` pads a three-part version to four for file-version
  comparisons; four-part versions pass through.
- Legacy `v1.2.3` tags now normalise to `1.2.3.0` when parsed. This also removes a latent
  comparison bug: a three-part `System.Version` has `Revision = -1`, so `1.4.5` sorts *below*
  `1.4.5.0`, and an update check comparing a three-part tag against a four-part current
  version would have misread "already current". Both sides are four-part now.
- Left alone deliberately: `Update Swiss Army VPN.ps1:567` matches the **GitHub CLI's**
  version, not ours. It stays three-part.

**Watch out:** a managed upgrade also validates the *existing* folder. The 1.4.3 install at
`F:\Program Files\Swiss Army VPN` was missing `Swiss Army VPN.png`, which nothing in the app
reads (only `Swiss Army VPN Background.png` is loaded at runtime), so it went unnoticed until
the layout check counted 11 files instead of 12. Cause of the loss is unknown - both the
fresh-install and upgrade paths do copy it. The validator was left strict on purpose.

### Active v1.4.3 test branch update (2026-08-02)

- **Branch:** `codex/vpn-server-selector`
- **Candidate version:** v1.4.3 (local test build; not yet released or committed)
- Added an editable Swiss server dropdown, optional official non-Swiss NordVPN hostname mode, and transactional server switching.
- Added a separate `CURRENT: <hostname>` indicator so editing the selector cannot obscure the active saved server.
- Confirmed a live manual switch from `ch334.nordvpn.com` to `ch380.nordvpn.com`.
- Server changes intentionally require the VPN to be disconnected and the kill switch unlocked.
- Fixed the v1.3.3-to-v1.4.0 upgrade shortcut check to recognize the managed `Emergency Unlock.exe` shortcut.
- Bumped the refreshed UI package to v1.4.1 because the installer correctly rejects same-version v1.4.0 replacement; v1.4.1 explicitly permits managed upgrades from v1.4.0.
- Fixed a tray-restore UI defect by removing the form-wide tooltip, clearing tooltip state across hide/show, and forcing a clean repaint; v1.4.2 permits managed upgrades from v1.4.1.
- Corrected the v1.4.2 tray restore regression by restoring the required WinForms `Show()` then `WindowState = Normal` ordering; v1.4.3 permits managed upgrades from v1.4.2.
- Full v1.4.3 manual installation, UI, connection, kill-switch, rollback, and recovery testing remains pending.

- **Latest Version**: v1.3.3 ✅ (live upgrade verification recorded, all issues resolved)
- **Active Development**: Release verifier integration, distribution validation, and installer documentation
- **Recent Focus**:
  - ✅ Verifier executable created: `Verify Swiss Army VPN Release 1.3.3.exe`
  - ✅ Manual SHA256 verification PASSED for v1.3.3 distribution & source ZIPs
  - ✅ All v1.3.1/v1.3.2 release failures resolved in v1.3.3
  - ✅ Installer runtime path fallback fix applied in `src/SwissArmyVPN.Installer.cs`
  - ✅ Optional private directory server separated from the VPN repository
  - ✅ Installation documentation updated for clearer packaged-release extraction guidance
  - ✅ Readme and context documentation aligned with current distribution workflow

## Current Assistant

- **GitHub Copilot (Raptor mini)** — Applied the installer runtime path fallback fix, simplified installation documentation, and committed the updates.

## AI Collaboration History

Multiple AI assistants have worked on this project:

- **ChatGPT** - Previous work sessions
- **Qwen** - Previous work sessions (caused v1.3.1/v1.3.2 issues, see below)  
- **GitHub Copilot** - Current session

*Note: Context is not shared across different AI sessions. This file serves as the single source of truth.*

## Branch Structure

| Branch | Purpose | Has Verifier? | Status |
|--------|---------|---------------|--------|
| `main-with-verifier` | Your version with release verifier | ✅ Yes | Active (current) |
| `original-main` | Original version (no verifier) | ❌ No | Preserved for comparison |
| `main` | Default production branch | ⚠️ Outdated | Legacy reference |

## Known Issues / Patterns & Resolution History

### v1.3.1 Release Failure - RESOLVED in v1.3.3

**Problem:** The `v1.3.1` tag pointed to a commit whose application metadata was still `1.3.0`. GitHub Actions found the mismatch and failed the tagged build, preventing intended v1.3.1 artifacts from being produced.

**Root Cause:** Tag created before repository's version metadata was consistently updated. Qwen-generated changes renamed PowerShell variables that collided with automatic `$PROFILE` variable; three stale `$profile` references remained in preserved-profile state sanitizer.

**Resolution (v1.3.3):**

- One function now defines exact managed-install files for a given version
- Existing-install and staged-install validation use same definition
- Build creates staged managed installation and verifies exact names, item types, reparse-point status, publisher, and file version
- Build continues to reject disagreement among tag, assembly, manifest, runtime, installer, and build-script versions

### v1.3.2 Upgrade Failure - RESOLVED in v1.3.3

**Problem:** The immutable `v1.3.2` package built correctly and passed checksum validation, but its live managed-upgrade path rejected a correctly staged 12-file installation because one validator still required exactly 10 files.

**User Impact:** Upgrading existing managed v1.1.2 installation failed with:
> The staged upgrade failed its publisher, version, or file-layout check. The previous installation was restored.

No VPN/firewall configuration was lost - rollback path preserved everything (VPN profile, connection state, sign-in, certificate, firewall rules, server choice, and v1.1.2 application files).

**Resolution (v1.3.3):**

- Unified file-layout validation across all upgrade paths
- First authoritative end-to-end upgrade test added after publication
- Multiple related changes now properly coordinated

### Other Patterns Fixed

- **Directory naming**: Spaces renamed to underscores for compatibility (#14)
- **PowerShell variables**: Fixed `$profile` → `$vpnProfile` mapping (#13)
- **Release automation**: Improved validation to catch version mismatches early

## Recent Changes Summary

| Version | Key Changes | Status |
|---------|-------------|--------|
| v1.3.3 | Release verifier, SHA256 validation, all v1.3.1/v1.3.2 issues resolved | ✅ Verified (manual SHA256) |
| v1.3.2 | Installer upgrade fixes, PowerShell script updates | ⚠️ Upgrade failures documented |
| v1.3.1 | ManualBackup path fix, version bump from 1.3.0 | ❌ Release failed (tag/version mismatch) |

## File Structure

```
src/           - Source code (.cs files for C# Windows Forms app)
installer/     - Installers and scripts (PowerShell, .exe launchers)
docs/          - Documentation (incidents, media, guides)
scripts/       - Automation scripts (Build-Release.ps1, etc.)
assets/        - Project assets
artifacts/     - Build outputs, one folder per version: artifacts/builds/<version>/
               (NOT in git due to .gitignore)
.github/       - CI/CD configuration
```

## Current Task: Release Verifier Integration

**Status**: ✅ Committed to `main-with-verifier`, ⏳ Needs PR creation for review

### What was done

- Created `Verify Swiss Army VPN Release 1.3.3.exe` in `artifacts/verifier-integration-test/`
- Verified v1.3.3 distribution and source ZIPs match expected SHA256 checksums (PASS)
- Applied installer runtime path fallback fix in `src/SwissArmyVPN.Installer.cs`
- Committed via Git LFS to avoid bloating repo

### What needs to be done

1. **Create Pull Request** from `main-with-verifier` → `original-main`
   - Allows review of verifier addition
   - People can choose to merge or keep branches separate

2. **Update CI workflow** to run verifier automatically on releases

3. **Keep release documentation current** so non-technical users can extract and install packages correctly

---

## Build Instructions

From Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Release.ps1
```

Build output goes to `artifacts/builds/<version>/` - one folder per version, never a shared
flat directory. `-OutputDirectory` still works and gets the same `builds/<version>` nesting
underneath it. The build validates:

- PowerShell syntax
- Package checksums
- Executable metadata
- Installer payload

## Important Notes for New Sessions

### Credentials & Security

- Use valid NordVPN manual-service credentials (never included in code)
- Installing/changing protection requires administrator approval
- No GitHub token stored in the app
- Private updates require system-wide GitHub CLI 2.96+ and `gh auth login` with account access to this repository

### Release Engineering

- Download from [latest GitHub Release](https://github.com/Justichuu/The-Swiss-Army-VPN/releases/latest)
- Do NOT use "Code → Download ZIP" - that contains source code, not compiled app
- Keep matching distribution and source ZIPs together when sharing
- First release with new package file may require manual install (older updaters reject unfamiliar files)

### Incident Documentation

All release incidents are documented in `docs/incidents/`. Review these before making changes to:

- Release automation workflows
- Installer validation logic
- Upgrade paths between versions

---
*Last updated: 2026-07-23 | Total commits: ~19 | Verifier status: VERIFIED ✅ | Branches ready for PR review*
<EOF>
