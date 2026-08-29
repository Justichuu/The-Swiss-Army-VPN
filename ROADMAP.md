# Swiss Army VPN — Feature Roadmap

- **Version:** 1.5.0.0
- **Status:** Book, polish, and open proposals
- **Last Updated:** 2026-08-29

---

## 📋 Overview

This document outlines the feature roadmap for The Swiss Army VPN, a privacy-focused VPN client emphasizing transparency, security, and Swiss theming. Features are categorized by priority and implementation status.

---

## 🚧 Phase 1: Core Enhancements (v1.2.0)

### Optional United States Installation
- **Description:** Offer country selection during installation with Swiss Army VPN as default
- **Guardrails:**
  - Single managed VPN profile per installation
  - Explicit country labeling in UI, diagnostics, and server validation
  - Separate vetted live-server filters and offline seed pools per country
  - Fail-closed kill-switch preserved across all connection changes
  - Country switching treated as deliberate reconfiguration (not automatic failover)
- **Status:** ✅ Planned for v1.2.0

---

## 🧪 Phase 2: Advanced Features (Post-v1.2.0)

### 🔐 Privacy & Security

| # | Feature | Description | Status |
|---|---------|-------------|--------|
| 1 | **Swiss Border Guard** | Real-time location verification showing virtual Swiss position vs. real IP on live map | 🚧 Planned |
| 2 | **Swiss Vault** | Encrypted local notes using NordVPN credentials; auto-delete on VPN disconnect | ❌ Not Planned |
| 3 | **Leak Detector** | One-click DNS/WebRTC scanner with visual leak risk meter and IPv6 tunneling detection | 🚧 Planned |
| 4 | **Anonymous Mode** | Browser profile integration (private/incognito launch, encrypted local storage) | ❌ Not Planned |

### 🧾 Release Quality (v1.3.3)

| # | Feature | Description | Status |
|---|---------|-------------|--------|
| 19 | Release verifier integration | Build-time validation of distribution and source artifacts with SHA256 checks and exact package layout | ✅ Committed |
| 20 | Distribution installation guidance | Clear user-facing instructions for extracting and running `Install Swiss Army VPN.exe` | ✅ Updated |

---

## 🎮 Performance & Gaming

| # | Feature | Description | Status |
|---|---------|-------------|--------|
| 5 | **Ping Radar** | Multi-server latency dashboard with real-time ping bars and color-coded game types | 🚧 Planned |
| 6 | **Jitter Watcher** | Connection stability monitor tracking jitter variance for video calls, gaming, streaming | ❌ Not Planned |

### 🌍 Swiss-Specific Features

| # | Feature | Description | Status |
|---|---------|-------------|--------|
| 7 | **Alpine Server Selector** | Geographic precision: city selection (Zurich/Geneva/Bern/Basel), region choice, time zone optimization | ❌ Not Planned |
| 8 | **Schengen Pass** | Regional access tracker showing unblocked streaming services and banking site accessibility | ❌ Not Planned |

### 🛡️ Advanced Security

| # | Feature | Description | Status |
|---|---------|-------------|--------|
| 9 | **Firewall Sentinel** | Visual network map displaying app usage, data flow direction, kill-switch status | ❌ Not Planned |
| 10 | **Certificate Inspector** | SSL/TLS verification with certificate validity, encryption strength, CA trust chain display | ❌ Not Planned |

### 📱 Cross-Device Features

| # | Feature | Description | Status |
|---|---------|-------------|--------|
| 11 | **Swiss Sync** | Multi-device status dashboard showing all connected devices and per-device bandwidth | ❌ Not Planned |
| 12 | **Emergency Beacon** | QR code generator for temporary access sharing with auto-expiry | ❌ Not Planned |

### 🎨 UI/UX Innovations

*Note: The short book in `docs/book/` is the current reading path. Colour key and symmetry stay in the widget.*

| # | Feature | Description | Status |
|---|---------|-------------|--------|
| 13 | **Swiss Flag Color Coding** | Dynamic tray icon colors: Red (disconnected), White (connected), Blue (DNS leak), Purple (switching) | ❌ Not Planned |
| 14 | **Mountain Range Progress Bar** | Connection progress visualized as mountain climbing with weather-based latency indicators | ❌ Not Planned |

### 🤖 Automation Features

| # | Feature | Description | Status |
|---|---------|-------------|--------|
| 15 | **Auto-Pilot Mode** | AI-powered server selection based on activity patterns, time of day, network congestion | ❌ Not Planned |
| 16 | **Schedule Switcher** | Time-based profiles for different Swiss cities (work/leisure/sleep schedules) | ❌ Not Planned |

### 💡 Utility Tools

| # | Feature | Description | Status |
|---|---------|-------------|--------|
| 17 | **Swiss Army Knife** | Context menu with IP checker, DNS leak test, port scanner, speed test, WHOIS lookup | 🚧 Planned |
| 18 | **Privacy Receipt** | Session logging report: duration, data transferred, servers accessed, leaks detected | ❌ Not Planned |

---

## 📊 Status Legend

- ✅ **Planned:** Scheduled for current or near-term release
- 🚧 **Planned (Future):** Considered but deferred to later phases
- ❌ **Not Planned:** Interesting idea but outside scope of product vision

---

## 🎯 Implementation Priorities

1. **Core Infrastructure** — Single-country profile management, country switching logic
2. **Security Features** — Leak detection, location verification
3. **User Experience** — Visual indicators, context menu utilities
4. **Advanced Automation** — AI server selection, scheduling (long-term)

---

*For questions or contributions, refer to the project repository.*