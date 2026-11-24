# Changelog

All notable changes to MountKeep are documented in this file.

## [1.5.2] - 2026-11-23

### Fixed
- **Live SSH Readiness Verification:** MountKeep now verifies both the local SSH key and remote TCP port `22` reachability before enabling the **`Off`** button in the menu bar popover. PCs without OpenSSH Server running on port `22` no longer show a broken **`Off`** button.
- **Clearer Remote Power Badges:** Replaced the counterintuitive red **`SSH Off`** badge in Settings with live status pills (**`Remote Power`** in green when ready, **`SSH Port 22 Closed`** or **`Missing SSH Key`** in orange when setup is incomplete) plus a **`Re-check`** button.
- **Popover IP Wrapping:** Widened the menu bar popover slightly (`408pt`) and prevented server IP addresses from wrapping onto two lines.

## [1.5.1] - 2026-11-23

### Fixed
- **Live Filename Extensions Toggle (LaunchServices):** Switched `showFileExtensions` to call macOS's native LaunchServices preference API (`_LSGetShowAllExtensionsPreference` / `_LSSetShowAllExtensionsPreference`, the same API Finder Settings calls) so toggling extensions updates Finder, Spotlight (`lsd`), and running apps live without needing `killall Finder`.

### Improved
- **Remote Shut Down Discoverability:** Added a dedicated **Remote Shut Down (SSH)** section directly in **Settings → Network & System** showing SSH key status, a prominent **Setup Guide…** button, and per-server enable checkboxes.

## [1.5.0] - 2026-11-23

### Added
- **Hybrid 1-Click In-App Updater:** Update prompts in both the release notes window and **Settings → Network & System** now offer **View on GitHub / View Page** *and* **Install Update**. Downloads prebuilt `.app.zip` GitHub Release assets (fast swap + automatic local dev-cert re-sign when available + relaunch) with a source tarball build fallback if no zip asset is attached.
- **Release Packaging Script:** Added `scripts/package-release.sh` to produce ad-hoc signed `MountKeep-vX.Y.Z.zip` release archives with no personal certificate metadata.

### Fixed
- **Spotlight Extension Refresh:** Toggling `Extensions` now also restarts Spotlight (`com.apple.Spotlight`) alongside Finder so toggling global extensions back off clears `.app` suffixes in Spotlight immediately.

## [1.4.0] - 2026-11-23

### Added
- **Remote Shut Down (SSH):** Added an optional **`Off`** button next to online servers (the counterpart to Wake-on-LAN **`Wake`**) using macOS's built-in `/usr/bin/ssh` with zero external dependencies.
- **Safe Unmount-Before-Shutdown:** Clicking **`Off`** asks for confirmation, cleanly unmounts all mounted shares on that server first (preventing Finder disconnect popups and data loss), and cancels automatically if any files are still busy.
- **In-App SSH Setup Guide:** Added **Edit Server → Setup Guide…** with one-click dedicated shutdown key generation (`~/.ssh/mountkeep_power`) and a ready-to-copy Windows Admin PowerShell script using a restricted forced-command key (`command="shutdown /s /t 5"`).

## [1.3.2] - 2026-11-23

### Fixed
- **File Extensions Toggle Reliability:** Fixed Global Domain (`NSGlobalDomain`) preference reads via `CFPreferencesCopyValue`, cleared any stale per-app Finder override, broadcast `com.apple.LaunchServices.ShowAllExtensionsChanged` (Distributed + Darwin notifications), and subscribed `MountManager` to external Finder Settings changes.
- **Serialized Finder Restarts:** Debounced and serialized Finder restarts (`SIGTERM` + wait for old PID exit and respawn) so rapid toggle clicks no longer overlap or race with `cfprefsd`.
- **Hidden Files in Open/Save Dialogs:** `Hidden Files` toggle now writes `AppleShowAllFiles` to both `com.apple.finder` and `NSGlobalDomain` so dotfiles on local and SMB volumes also appear in app Open/Save panels.

## [1.3.1] - 2026-11-23

### Added
- **In-App Update Release Notes:** Clicking **`Update vX.Y.Z`** in the popover opens an in-app release notes window with the GitHub Release changelog and an **Open on GitHub** action.
- **"What's New" Popup:** Automatically displays a one-time **What's New** window on first launch after updating to a new version using the bundled `CHANGELOG.md`.

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
