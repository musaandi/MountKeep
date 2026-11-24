import AppKit
import SwiftUI
import Combine

@MainActor
public final class MountKeepAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var releaseNotesWindow: NSWindow?
    private var eventMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    public let manager: MountManager

    public init(manager: MountManager? = nil) {
        self.manager = manager ?? MountManager()
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure menu-bar-only (accessory) behavior even if launched outside the .app bundle.
        NSApp.setActivationPolicy(.accessory)

        if CommandLine.arguments.contains("--enable-login-item") {
            manager.setLaunchAtLogin(true)
        }

        setupStatusItem()
        setupPopover()
        observeStatusChanges()

        manager.start()

        if let whatsNew = UpdateChecker.consumeWhatsNewNotes() {
            openReleaseNotesWindow(mode: .whatsNew(version: whatsNew.version, notes: whatsNew.notes))
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        stopEventMonitor()
        manager.stop()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Status Item & Popover

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(handleStatusBarClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = item
        updateStatusIcon()
    }

    private func setupPopover() {
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self

        let contentView = PopoverView(
            manager: manager,
            onOpenSettings: { [weak self] in
                self?.closePopover()
                self?.openSettingsWindow()
            },
            onOpenUpdate: { [weak self] release in
                self?.closePopover()
                self?.openReleaseNotesWindow(mode: .updateAvailable(release))
            },
            onQuit: { [weak self] in
                self?.quitApp()
            }
        )
        let hosting = NSHostingController(rootView: contentView)
        hosting.sizingOptions = [.preferredContentSize]
        pop.contentViewController = hosting
        self.popover = pop
    }

    private func observeStatusChanges() {
        Publishers.MergeMany(
            manager.$shareStates.map { _ in () }.eraseToAnyPublisher(),
            manager.$shareCapacities.map { _ in () }.eraseToAnyPublisher(),
            manager.$config.map { _ in () }.eraseToAnyPublisher(),
            manager.$isChecking.map { _ in () }.eraseToAnyPublisher(),
            manager.$isOnHomeNetwork.map { _ in () }.eraseToAnyPublisher(),
            manager.$activePollCadence.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.updateStatusIcon()
        }
        .store(in: &cancellables)
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        switch manager.overallStatus {
        case .allMounted:
            symbolName = "externaldrive.connected.to.line.below.fill"
        case .mounting:
            symbolName = "arrow.triangle.2.circlepath"
        case .paused:
            symbolName = "externaldrive.badge.minus"
        case .awayFromHome:
            symbolName = "house.slash"
        case .someOffline, .someFailed:
            symbolName = "externaldrive.badge.exclamationmark"
        case .noEnabledShares:
            symbolName = "externaldrive"
        }

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "MountKeep")?
            .withSymbolConfiguration(config) {
            image.isTemplate = true
            button.image = image
        }

        let mounted = manager.mountedEnabledShareCount
        let total = manager.enabledShareCount
        let style = manager.config.storageUnitStyle
        let storageSuffix: String
        if let cap = manager.overallCapacity {
            storageSuffix = " • \(cap.formattedUsedOfTotal(style: style)) (\(cap.usedPercentText))"
        } else {
            storageSuffix = ""
        }

        if manager.config.paused {
            button.toolTip = "MountKeep (Paused) — \(mounted)/\(total) mounted\(storageSuffix)"
        } else if manager.overallStatus == .awayFromHome {
            button.toolTip = "MountKeep — Away from home network (dormant)"
        } else {
            button.toolTip = "MountKeep — \(mounted)/\(total) mounted\(storageSuffix)"
        }
    }

    @objc private func handleStatusBarClick(_ sender: AnyObject?) {
        guard let event = NSApp.currentEvent, let button = statusItem?.button else {
            togglePopover()
            return
        }

        if event.type == .rightMouseUp || (event.type == .leftMouseUp && event.modifierFlags.contains(.control)) {
            closePopover()
            let menu = buildContextMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else {
            togglePopover()
        }
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let syncItem = NSMenuItem(title: "Sync Now", action: #selector(menuSyncNow), keyEquivalent: "r")
        syncItem.target = self
        menu.addItem(syncItem)

        let mountAllItem = NSMenuItem(title: "Mount All Enabled", action: #selector(menuMountAll), keyEquivalent: "m")
        mountAllItem.target = self
        menu.addItem(mountAllItem)

        let pauseTitle = manager.config.paused ? "Resume Auto-Mount" : "Pause Auto-Mount"
        let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(menuTogglePause), keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Manage Shares & Preferences…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let configItem = NSMenuItem(title: "Open config.json", action: #selector(menuOpenConfig), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)

        let logItem = NSMenuItem(title: "Open Log", action: #selector(menuOpenLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit MountKeep", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func menuSyncNow() { manager.syncNow() }
    @objc private func menuMountAll() { manager.mountAllNow() }
    @objc private func menuTogglePause() { manager.togglePause() }
    @objc private func menuOpenSettings() { openSettingsWindow() }
    @objc private func menuOpenConfig() { manager.openConfigFile() }
    @objc private func menuOpenLog() { manager.openLogFile() }
    @objc private func menuQuit() { quitApp() }

    private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            manager.refreshMountedSnapshotOnly()
            Task { await manager.refreshCapacities(force: false) }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startEventMonitor()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
        stopEventMonitor()
    }

    public func popoverDidClose(_ notification: Notification) {
        stopEventMonitor()
    }

    private func startEventMonitor() {
        stopEventMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover()
            }
        }
    }

    private func stopEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Settings Window

    public func openSettingsWindow() {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: SettingsView(manager: manager))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MountKeep — Manage Shares"
        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func openReleaseNotesWindow(mode: ReleaseNotesMode) {
        releaseNotesWindow?.close()

        let view = ReleaseNotesView(
            mode: mode,
            onOpenGitHub: { url in
                NSWorkspace.shared.open(url)
            },
            onDismiss: { [weak self] in
                self?.releaseNotesWindow?.close()
            }
        )
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        switch mode {
        case .updateAvailable(let release):
            window.title = "MountKeep Update — v\(release.version)"
        case .whatsNew(let version, _):
            window.title = "What's New in MountKeep v\(version)"
        }
        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.releaseNotesWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        // Keep the background menu bar app running.
    }

    private func quitApp() {
        NSApp.terminate(nil)
    }
}
