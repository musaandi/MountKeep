import SwiftUI
import AppKit

private struct ScrollContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CapacityBarView: View {
    let fraction: Double
    let severity: UsageSeverity
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(fraction, 0), 1)
            let fillWidth = clamped > 0 ? max(height, geo.size.width * clamped) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(barColor)
                    .frame(width: min(fillWidth, geo.size.width))
            }
        }
        .frame(height: height)
    }

    private var barColor: Color {
        switch severity {
        case .normal: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

public struct PopoverView: View {
    @ObservedObject var manager: MountManager
    let onOpenSettings: () -> Void
    let onOpenUpdate: ((AppReleaseInfo) -> Void)?
    let onQuit: () -> Void

    @State private var measuredContentHeight: CGFloat = 0

    public init(
        manager: MountManager,
        onOpenSettings: @escaping () -> Void,
        onOpenUpdate: ((AppReleaseInfo) -> Void)? = nil,
        onQuit: @escaping () -> Void
    ) {
        self.manager = manager
        self.onOpenSettings = onOpenSettings
        self.onOpenUpdate = onOpenUpdate
        self.onQuit = onQuit
    }

    private var unitStyle: StorageUnitStyle {
        manager.config.storageUnitStyle
    }

    private var maxScrollHeight: CGFloat {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
        return min(620, max(360, floor(visibleHeight * 0.50)))
    }

    private var estimatedScrollHeight: CGFloat {
        let activeServers = manager.config.servers.filter { $0.shares.contains(where: \.enabled) }
        var total: CGFloat = 20
        for (idx, srv) in activeServers.enumerated() {
            if idx > 0 { total += 10 }
            total += 24
            for share in srv.shares where share.enabled {
                let hasCap = manager.shareStates[share.id]?.isMounted == true && manager.shareCapacities[share.id] != nil
                total += (hasCap ? 48 : 38) + 4
            }
        }
        return max(120, total)
    }

    private var scrollViewHeight: CGFloat {
        let desired = measuredContentHeight > 0 ? ceil(measuredContentHeight) : estimatedScrollHeight
        return min(desired, maxScrollHeight)
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            if let banner = manager.statusBanner {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text(banner)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        manager.dismissBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.12))
                Divider()
            }

            if let overall = manager.overallCapacity {
                overallStorageSummary(overall)
                Divider()
            }

            if manager.enabledShareCount == 0 {
                emptyStateView
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(manager.config.servers) { server in
                            let activeShares = server.shares.filter(\.enabled)
                            if !activeShares.isEmpty {
                                serverSection(server: server, shares: activeShares)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ScrollContentHeightKey.self, value: geo.size.height)
                        }
                    )
                }
                .frame(height: scrollViewHeight)
                .onPreferenceChange(ScrollContentHeightKey.self) { newHeight in
                    if newHeight > 0 && abs(newHeight - measuredContentHeight) > 1 {
                        measuredContentHeight = newHeight
                    }
                }
            }

            Divider()
            finderQuickTogglesView
            Divider()
            footerView
        }
        .frame(width: 408)
        .onAppear {
            manager.refreshFinderPreferences()
            Task { await manager.checkForUpdates(manual: false) }
        }
    }

    private func overallStorageSummary(_ overall: VolumeCapacity) -> some View {
        let driveCount = manager.overallCapacityDriveCount
        let enabledCount = manager.enabledShareCount
        let driveLabel: String
        if driveCount == enabledCount {
            driveLabel = "\(driveCount) mounted \(driveCount == 1 ? "drive" : "drives")"
        } else {
            driveLabel = "\(driveCount) of \(enabledCount) drives mounted"
        }

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Total Storage")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(overall.formattedUsedOfTotal(style: unitStyle))
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())

                Text(overall.usedPercentText)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(severityColor(overall.severity).opacity(0.16))
                    .foregroundStyle(severityColor(overall.severity))
                    .clipShape(Capsule())
            }

            CapacityBarView(
                fraction: overall.usedFraction,
                severity: overall.severity,
                height: 5
            )

            HStack {
                Text(overall.formattedFree(style: unitStyle))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(driveLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.025))
    }

    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: headerSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(headerColor)

            VStack(alignment: .leading, spacing: 1) {
                Text("MountKeep")
                    .font(.system(size: 13, weight: .semibold))
                Text(statusSummaryText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let update = manager.availableUpdate {
                Button {
                    if let onOpenUpdate {
                        onOpenUpdate(update)
                    } else {
                        manager.openAvailableUpdate()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Update v\(update.version)")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.blue.opacity(0.16)))
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help("Open MountKeep v\(update.version) on GitHub")
            }

            Button {
                manager.syncNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .rotationEffect(.degrees(manager.isChecking ? 360 : 0))
                    .animation(
                        manager.isChecking
                            ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                            : .default,
                        value: manager.isChecking
                    )
            }
            .buttonStyle(.borderless)
            .help("Check & Sync Now")
            .disabled(manager.isChecking)

            Button {
                manager.togglePause()
            } label: {
                Image(systemName: manager.config.paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(manager.config.paused ? "Resume Auto-Mount" : "Pause Auto-Mount")

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Manage Shares & Preferences")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("No shares enabled")
                .font(.headline)
            Text("Open Manage Shares to enable or add network drives.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Manage Shares…", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private func serverSection(server: ServerConfig, shares: [ShareConfig]) -> some View {
        let hostState = manager.hostStates[server.id] ?? .unknown
        let serverAway = manager.isServerAway(server)
        let mountedCount = shares.filter { manager.shareStates[$0.id]?.isMounted == true }.count
        let anyUnmounted = mountedCount < shares.count
        let serverCap = manager.capacityForServer(server.id)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(hostDotColor(hostState))
                    .frame(width: 7, height: 7)

                Text(server.host)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                if case .online(let ip) = hostState, let ip, ip != server.host {
                    Text(ip)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else if case .waking = hostState {
                    Text("waking…")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                } else if case .shuttingDown = hostState {
                    Text("shutting down…")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if case .awayFromHome = hostState {
                    Text("away")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if case .offline = hostState {
                    Text("offline")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if server.autoSyncAllShares {
                    Text("auto")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.14))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                        .fixedSize(horizontal: true, vertical: false)
                        .help("Automatically discovers & mounts new non-hidden shares")
                }

                Spacer(minLength: 4)

                if let serverCap {
                    Text(serverCap.formattedUsedOfTotal(style: unitStyle))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .help("\(server.host) combined: \(serverCap.formattedUsedOfTotal(style: unitStyle)) (\(serverCap.usedPercentText), \(serverCap.formattedFree(style: unitStyle)))")
                }

                // Per-server Wake-on-LAN, Remote Shut Down, or bulk mount/unmount actions
                if !serverAway {
                    if case .waking = hostState {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                    } else if case .shuttingDown = hostState {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                    } else if case .offline = hostState, let mac = server.macAddress {
                        Button {
                            manager.wakeServer(serverID: server.id)
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 9.5))
                                Text("Wake")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.14))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.borderless)
                        .help("Send Wake-on-LAN packet to \(server.host) (\(mac))")
                    } else if hostState.isOnline && server.canRemoteShutdown && manager.sshReadiness[server.id] == .ready {
                        Button {
                            confirmShutdown(server: server)
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "power")
                                    .font(.system(size: 9.5, weight: .semibold))
                                Text("Off")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.13))
                            .foregroundStyle(.red)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.borderless)
                        .help("Unmount all shares and shut down \(server.host) via SSH")
                    }

                    if hostState.isOnline && anyUnmounted {
                        Button {
                            manager.mountAllForServer(serverID: server.id)
                        } label: {
                            Image(systemName: "play.circle")
                                .font(.system(size: 11.5))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Mount all enabled shares on \(server.host)")
                    }

                    if mountedCount > 0 {
                        Button {
                            manager.unmountAllForServer(serverID: server.id)
                        } label: {
                            Image(systemName: "eject")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Unmount all shares on \(server.host)")
                    }
                }
            }
            .padding(.horizontal, 4)

            VStack(spacing: 4) {
                ForEach(shares) { share in
                    shareRow(server: server, share: share, serverAway: serverAway)
                }
            }
        }
    }

    private func shareRow(server: ServerConfig, share: ShareConfig, serverAway: Bool) -> some View {
        let state = manager.shareStates[share.id] ?? .unknown
        let capacity = manager.shareCapacities[share.id]

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                statusIndicator(for: state)
                    .frame(width: 14, height: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(share.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)

                    if case .mounted = state, capacity != nil {
                        // Capacity metrics render neatly below the slim usage bar.
                    } else {
                        Text(shareSubtitle(for: state))
                            .font(.system(size: 10.5))
                            .foregroundStyle(subtitleColor(for: state))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 4)

                if case .mounted(let mountPoint) = state {
                    Button {
                        manager.openInFinder(mountPoint: mountPoint)
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.borderless)
                    .help("Open \(mountPoint) in Finder")

                    Button {
                        manager.unmountShare(serverID: server.id, shareID: share.id)
                    } label: {
                        Image(systemName: "eject")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.borderless)
                    .help("Unmount (pauses auto-mount for this share)")
                } else if case .mounting = state {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                } else if case .healing = state {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                } else if !serverAway {
                    Button {
                        manager.mountShare(serverID: server.id, shareID: share.id)
                    } label: {
                        Image(systemName: "play.circle")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                    .help("Mount Now")
                }
            }

            if case .mounted = state, let cap = capacity {
                VStack(alignment: .leading, spacing: 3) {
                    CapacityBarView(
                        fraction: cap.usedFraction,
                        severity: cap.severity,
                        height: 3.5
                    )

                    HStack(spacing: 4) {
                        Text(cap.formattedUsedOfTotal(style: unitStyle))
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text("\(cap.usedPercentText) • \(cap.formattedFree(style: unitStyle))")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(
                                cap.severity == .normal
                                    ? Color.secondary
                                    : severityColor(cap.severity)
                            )
                    }
                }
                .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .help(rowTooltip(state: state, capacity: capacity))
    }

    private func rowTooltip(state: ShareRuntimeState, capacity: VolumeCapacity?) -> String {
        switch state {
        case .mounted(let path):
            if let cap = capacity {
                return "\(path)\n\(cap.formattedUsedOfTotal(style: unitStyle)) (\(cap.usedPercentText) used, \(cap.formattedFree(style: unitStyle)))"
            }
            return path
        default:
            return shareSubtitle(for: state)
        }
    }

    private var footerView: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                if manager.hasHomePinningEnabled {
                    Image(systemName: manager.isOnHomeNetwork ? "house.fill" : "house.slash")
                        .font(.system(size: 9.5))
                        .foregroundStyle(manager.isOnHomeNetwork ? Color.secondary : Color.orange)
                }
                Text(manager.activePollCadence.label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .help(footerTooltip)

            Spacer()

            if !manager.allEnabledSharesAreAway && manager.mountedEnabledShareCount < manager.enabledShareCount {
                Button("Mount All") {
                    manager.mountAllNow()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }

            Button("Manage…", action: onOpenSettings)
                .buttonStyle(.link)
                .font(.system(size: 11))

            Button("Log") {
                manager.openLogFile()
            }
            .buttonStyle(.link)
            .font(.system(size: 11))

            Button("Quit", action: onQuit)
                .buttonStyle(.link)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var finderQuickTogglesView: some View {
        HStack(spacing: 8) {
            Text("Finder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

            finderTogglePill(
                title: "Hidden Files",
                systemImage: manager.showHiddenFiles ? "eye.fill" : "eye.slash",
                isOn: manager.showHiddenFiles
            ) {
                manager.setShowHiddenFiles(!manager.showHiddenFiles)
            }
            .help("Toggle Finder hidden files and folders (AppleShowAllFiles)")

            finderTogglePill(
                title: "Extensions",
                systemImage: manager.showFileExtensions ? "doc.text.fill" : "doc.text",
                isOn: manager.showFileExtensions
            ) {
                manager.setShowFileExtensions(!manager.showFileExtensions)
            }
            .help("Force-show all filename extensions system-wide (Finder & Spotlight) even on items marked 'Hide extension'")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func finderTogglePill(
        title: String,
        systemImage: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(isOn ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isOn ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 0.75)
            )
            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private var footerTooltip: String {
        let netInfo: String
        if let gw = manager.currentNetwork?.primaryGateway {
            netInfo = "Gateway \(gw.ipAddress)\(gw.macAddress.map { " (\($0))" } ?? "")"
        } else {
            netInfo = "No active network"
        }
        if let last = manager.lastCheckDate {
            let formatted = DateFormatter.localizedString(from: last, dateStyle: .none, timeStyle: .short)
            return "\(netInfo) • Last check \(formatted)"
        }
        return netInfo
    }

    private func severityColor(_ severity: UsageSeverity) -> Color {
        switch severity {
        case .normal: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }

    @ViewBuilder
    private func statusIndicator(for state: ShareRuntimeState) -> some View {
        switch state {
        case .mounted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .mounting, .healing:
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.blue)
        case .manuallyUnmounted:
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        case .awayFromHome:
            Image(systemName: "house.slash")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .hostOffline:
            Image(systemName: "wifi.slash")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
        case .unmounted, .unknown:
            Image(systemName: "circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func shareSubtitle(for state: ShareRuntimeState) -> String {
        switch state {
        case .mounted(let path):
            return path
        case .mounting:
            return "Mounting…"
        case .healing:
            return "Healing stale mount…"
        case .manuallyUnmounted:
            return "Unmounted (click ▶ to remount)"
        case .awayFromHome:
            return "Away from home network"
        case .hostOffline:
            return "Host unreachable"
        case .failed(let message, _, _):
            return message
        case .unmounted:
            return manager.config.paused ? "Not mounted (paused)" : "Not mounted"
        case .unknown:
            return "Checking…"
        }
    }

    private func subtitleColor(for state: ShareRuntimeState) -> Color {
        switch state {
        case .failed: return .red
        case .manuallyUnmounted: return .orange
        case .healing: return .blue
        default: return .secondary
        }
    }

    private func confirmShutdown(server: ServerConfig) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Shut down \(server.host)?"
        alert.informativeText = "MountKeep will cleanly unmount all mounted shares on \(server.host) and send a remote shutdown command via SSH. Shutdown is cancelled automatically if any files are still in use."
        alert.addButton(withTitle: "Shut Down")
        alert.addButton(withTitle: "Cancel")
        if let destructive = alert.buttons.first {
            destructive.hasDestructiveAction = true
        }

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            manager.shutdownServer(serverID: server.id)
        }
    }

    private func hostDotColor(_ state: HostReachabilityState) -> Color {
        switch state {
        case .online: return .green
        case .waking, .checking: return .blue
        case .shuttingDown: return .orange
        case .awayFromHome: return .secondary.opacity(0.6)
        case .offline: return .gray
        case .unknown: return .gray.opacity(0.5)
        }
    }

    private var headerSymbol: String {
        switch manager.overallStatus {
        case .allMounted: return "externaldrive.connected.to.line.below.fill"
        case .mounting: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle.fill"
        case .awayFromHome: return "house.slash"
        case .someFailed: return "exclamationmark.triangle.fill"
        case .someOffline: return "externaldrive.badge.exclamationmark"
        case .noEnabledShares: return "externaldrive"
        }
    }

    private var headerColor: Color {
        switch manager.overallStatus {
        case .allMounted: return .green
        case .mounting: return .blue
        case .paused: return .orange
        case .awayFromHome: return .secondary
        case .someFailed: return .red
        case .someOffline: return .orange
        case .noEnabledShares: return .secondary
        }
    }

    private var statusSummaryText: String {
        let total = manager.enabledShareCount
        let mounted = manager.mountedEnabledShareCount
        if manager.config.paused {
            return "Paused • \(mounted)/\(total) mounted"
        }
        if manager.overallStatus == .awayFromHome {
            return "Away from home • dormant"
        }
        if total == 0 {
            return "No active shares"
        }
        if mounted == total {
            return "All \(total) shares mounted"
        }
        return "\(mounted) of \(total) mounted"
    }
}
