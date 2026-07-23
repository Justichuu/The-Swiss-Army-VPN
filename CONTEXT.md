# The-Swiss-Army-VPN - Context & State

## Project Overview
Switzerland VPN project with executable installer and emergency unlock support. Built as a learning experience ("vibe coding experiment") with Justichuu branding.

**What it does:**
- Connects a managed Switzerland IKEv2 VPN profile (NordVPN credentials)
- Arms a whole-computer, fail-closed Windows Firewall kill switch
- Shows live tunnel traffic and protected latency on demand
- Includes optional Swiss server pool and safe best-server switcher
- Verifies exact assets from immutable private releases
- Provides install, uninstall, emergency unlock, and PowerShell backup tools

**Important:** The kill switch affects the whole computer while armed. The app may disconnect other active Windows RAS VPN sessions during a controlled connection change. Use **DISCONNECT + UNLOCK** to restore normal internet.

## Current Status (as of 2026-07-23)
- **Latest Version**: v1.3.3 ✅ (live upgrade verification recorded, all issues resolved)
- **Active Development**: Release verifier integration and SHA256 checksum validation
- **Recent Focus**: 
  - ✅ Verifier executable created: `Verify Switzerland VPN Release 1.3.3.exe`
  - ✅ Manual SHA256 verification PASSED for v1.3.3 distribution & source ZIPs
  - ✅ All v1.3.1/v1.3.2 release failures resolved in v1.3.3
  - ✅ Installer runtime path fix applied in `src/SwitzerlandVPN.Installer.cs` to handle both source and release package layouts
  - ✅ Installation documentation updated for clearer packaged-release extraction guidance

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
artifacts/     - Build outputs (NOT in git due to .gitignore)
.github/       - CI/CD configuration
```

## Current Task: Release Verifier Integration
**Status**: ✅ Committed to `main-with-verifier`, ⏳ Needs PR creation for review

### What was done:
- Created `Verify Switzerland VPN Release 1.3.3.exe` in `artifacts/verifier-integration-test/`
- Verified v1.3.3 distribution and source ZIPs match expected SHA256 checksums (PASS)
- Applied installer runtime path fallback fix in `src/SwitzerlandVPN.Installer.cs`
- Committed via Git LFS to avoid bloating repo

### What needs to be done:
1. **Create Pull Request** from `main-with-verifier` → `original-main`
   - Allows review of verifier addition
   - People can choose to merge or keep branches separate

2. **Update CI workflow** to run verifier automatically on releases (optional)

3. **Document usage** in README.md (optional)

---

## Build Instructions
From Windows PowerShell:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Release.ps1
```

Build output goes to `artifacts/`. The build validates:
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