# Changelog

All notable changes to MountKeep are documented in this file.

## [1.5.6] - 2026-11-23

### Fixed
- **Single-Share Timeout Blocking Other Shares:** Fixed a regression from v1.5.3 where a timeout on the first share of a server (e.g. a wedged `/Volumes/<share>` mountpoint) skipped mounting all remaining healthy shares on that server. Remaining shares are now only skipped on authentication errors or `EHOSTUNREACH`.
- **Concurrent Double-Mount Guard:** Added per-share `inFlightMountShareIDs` tracking so clicking Mount / Wake while a background poll is already mounting the same share can never start two overlapping `NetFSMountURLAsync` calls.
- **Concurrent NetFS Callback Queue:** Switched `NetFSMounter.netfsQueue` to a concurrent queue so one slow or timed-out mount callback can never block other mounts.

## [1.5.5] - 2026-11-23

### Fixed
- **Blank Changelog Popup Body:** Fixed a SwiftUI `ScrollView` height collapse inside `ReleaseNotesView` (giving the changelog body an explicit minimum/flexible height, multi-line wrapping, and a resizable `480×380` window) so release notes and What's New bullet points render cleanly instead of collapsing between the dividers.

## [1.5.4] - 2026-11-23

### Fixed
- **Visible "What's New" Changelog Popup After Updating:** Deferred the post-update **What's New** window slightly after launch (`0.75s`), presented it on the active Space as a floating frontmost window (fixing macOS menu-bar `.accessory` apps opening windows silently behind other apps), and only marked the version seen once the user dismisses it.
- **Release Notes & What's New in Settings:** Added a **Release Notes** button (when an update is available) and a **What's New** button (anytime) directly in **Settings → Network & System → Updates**.

## [1.5.3] - 2026-11-23

### Fixed
- **Cold SMB Reconnect Timeout:** Raised default `mountTimeoutSeconds` from `15s` to `30s` and guaranteed at least `30s` for the first share mounted on a server (cold SMB session / spun-down archive drives over Wi-Fi), eliminating premature 15s mount cancellations.
- **Sleep/Wake False Zombie Strikes:** Reset `healthFailureCounts` on macOS sleep & wake (`willSleepNotification` / `didWakeNotification`) and increased post-wake grace delay from `2.5s` to `6s` so laptop sleep/wake cycles stop falsely force-unmounting healthy drives and creating `-1` volume suffixes.
- **Server-Wide Failure Short-Circuit:** If the first share on an unmounted server hits an auth failure, `EHOSTUNREACH`, or timeout, MountKeep immediately backs off remaining shares on that server instead of looping sequentially through every share.
- **Wake-on-LAN Cold-Boot Cadence:** Extended WoL follow-up polling (`10s, 10s, 12s, 15s, 15s` over ~62s) to better accommodate full S5 desktop boots.

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
