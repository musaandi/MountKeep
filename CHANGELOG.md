# Changelog

All notable changes to MountKeep are documented in this file.

## [1.3.0] - 2026-11-23

### Added
- **Finder Quick Toggles:** Added **Hidden Files** (`AppleShowAllFiles`) and **Extensions** (`AppleShowAllExtensions`) toggle pills directly in the menu bar popover and Settings → Network & System.
- **GitHub Update Checker:** Added `UpdateChecker` using the GitHub Releases API (`musaandi/MountKeep`) with automatic 24-hour checks, a manual **Check Now** button in Settings, and an **Update vX.Y.Z** pill in the menu bar popover when a newer release is published.

## [1.2.1] - 2026-11-23

### Added
- On-demand LAN MAC address resolution (`HomeNetworkDetector.resolveMACAddress(forIP:)`) via `/usr/sbin/arp -n <ip>` when a server is online and lacks a saved Wake-on-LAN MAC.
- Wired automatic Wake-on-LAN MAC learning into both manual share scans (`scanShares`) and periodic health checks (`checkAll`).

## [1.2.0] - 2026-11-20

### Added
- Initial public release of MountKeep: silent `NetFS` + Login Keychain SMB auto-mounting, home-network pinning via `SCDynamicStore`, zombie mount self-healing, Wake-on-LAN for offline servers, live storage capacity bars, and Settings UI.
