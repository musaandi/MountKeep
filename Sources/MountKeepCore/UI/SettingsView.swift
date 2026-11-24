import SwiftUI

public enum SettingsTab: Hashable, Sendable {
    case servers
    case network
}

public struct SettingsView: View {
    @ObservedObject var manager: MountManager

    @State private var selectedTab: SettingsTab
    @State private var quickURLText = ""
    @State private var quickURLError: String?
    @State private var newServerHost = ""
    @State private var newServerUser = ""
    @State private var newServerAutoSync = false
    @State private var newServerRequireHome = true
    @State private var newShareDrafts: [UUID: String] = [:]
    @State private var scanMessages: [UUID: String] = [:]
    @State private var scanningServerIDs: Set<UUID> = []

    // Inline server edit state
    @State private var editingServerID: UUID?
    @State private var editHost = ""
    @State private var editUsername = ""
    @State private var editMAC = ""
    @State private var editRequireHome = true
    @State private var editSSHShutdown = false
    @State private var editSSHUsername = ""
    @State private var editSSHKeyPath = ""
    @State private var showPowerSetupSheet = false
    @State private var powerSetupHost = ""
    @State private var powerSetupUser = ""
    @State private var powerSetupKeyPath = ""
    @State private var hasDefaultShutdownKey = RemotePower.hasPrivateKey()
    @State private var editError: String?

    // Home network pin status
    @State private var pinMessage: String?

    private let activeIntervalOptions: [(String, Int)] = [
        ("15 seconds", 15),
        ("30 seconds", 30),
        ("1 minute", 60),
        ("2 minutes", 120)
    ]

    private let idleIntervalOptions: [(String, Int)] = [
        ("1 minute", 60),
        ("2 minutes", 120),
        ("5 minutes", 300),
        ("10 minutes", 600)
    ]

    public init(manager: MountManager, initialTab: SettingsTab = .servers) {
        self.manager = manager
        self._selectedTab = State(initialValue: initialTab)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Servers & Shares").tag(SettingsTab.servers)
                Text("Network & System").tag(SettingsTab.network)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 300)
            .padding(.vertical, 10)

            Divider()

            switch selectedTab {
            case .servers:
                serversTab
            case .network:
                networkAndSystemTab
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .sheet(isPresented: $showPowerSetupSheet, onDismiss: {
            hasDefaultShutdownKey = RemotePower.hasPrivateKey()
        }) {
            RemotePowerSetupView(
                serverHost: powerSetupHost,
                sshUsername: powerSetupUser,
                keyPath: powerSetupKeyPath,
                onDismiss: { showPowerSetupSheet = false }
            )
        }
    }

    // MARK: - Tab 1: Servers & Shares

    private var serversTab: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Quick Add SMB Share")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("smb://user@host/Share Name", text: $quickURLText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submitQuickURL() }
                    Button("Add") {
                        submitQuickURL()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(quickURLText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let err = quickURLError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(manager.config.servers) { server in
                        serverCard(server)
                    }

                    addServerCard
                }
                .padding(14)
            }
        }
    }

    private func submitQuickURL() {
        quickURLError = manager.addFromSMBURL(quickURLText)
        if quickURLError == nil {
            quickURLText = ""
        }
    }

    private func startEditing(_ server: ServerConfig) {
        editingServerID = server.id
        editHost = server.host
        editUsername = server.username
        editMAC = server.macAddress ?? ""
        editRequireHome = server.requireHomeNetwork
        editSSHShutdown = server.sshShutdownEnabled
        editSSHUsername = server.sshUsername ?? ""
        editSSHKeyPath = server.sshKeyPath ?? ""
        editError = nil
    }

    private func saveEdit(for serverID: UUID) {
        editError = manager.updateServer(
            serverID: serverID,
            host: editHost,
            username: editUsername,
            macAddress: editMAC,
            requireHomeNetwork: editRequireHome,
            sshShutdownEnabled: editSSHShutdown,
            sshUsername: editSSHUsername,
            sshKeyPath: editSSHKeyPath
        )
        if editError == nil {
            editingServerID = nil
        }
    }

    private func serverCard(_ server: ServerConfig) -> some View {
        let hostState = manager.hostStates[server.id] ?? .unknown
        let isScanning = scanningServerIDs.contains(server.id)
        let isEditing = editingServerID == server.id

        return VStack(alignment: .leading, spacing: 10) {
            if isEditing {
                inlineServerEditor(server)
            } else {
                HStack(spacing: 8) {
                    Circle()
                        .fill(hostState.isOnline ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(server.host)
                                .font(.headline)
                            if !server.username.isEmpty {
                                Text("(\(server.username))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            if server.requireHomeNetwork {
                                Text("Home only")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15))
                                    .foregroundStyle(.secondary)
                                    .clipShape(Capsule())
                            }
                            if server.canRemoteShutdown {
                                Text("SSH Off")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.red.opacity(0.12))
                                    .foregroundStyle(.red)
                                    .clipShape(Capsule())
                                    .help("Remote Shut Down enabled via SSH (\(server.effectiveSSHUsername)@\(server.host))")
                            }
                        }

                        HStack(spacing: 8) {
                            if case .online(let ip) = hostState, let ip {
                                Text("Online • \(ip)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if case .awayFromHome = hostState {
                                Text("Away from home network")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if case .offline = hostState {
                                Text("Offline / Port 445 unreachable")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            if let mac = server.macAddress {
                                Text("WoL: \(mac)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    Spacer()

                    Toggle("Auto-sync", isOn: Binding(
                        get: { server.autoSyncAllShares },
                        set: { manager.setServerAutoSync(serverID: server.id, enabled: $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Automatically discover & mount new non-hidden disk shares on this server")

                    Button {
                        Task {
                            scanningServerIDs.insert(server.id)
                            let msg = await manager.scanShares(forServerID: server.id)
                            scanMessages[server.id] = msg
                            scanningServerIDs.remove(server.id)
                        }
                    } label: {
                        if isScanning {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Scan", systemImage: "magnifyingglass")
                        }
                    }
                    .controlSize(.small)
                    .disabled(isScanning)

                    Button {
                        startEditing(server)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Edit Host, Username, WoL MAC & Network Scope")

                    Button(role: .destructive) {
                        manager.removeServer(serverID: server.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove Server")
                }
            }

            if let scanMsg = scanMessages[server.id] {
                Text(scanMsg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if server.shares.isEmpty {
                Text("No shares configured yet. Add one below or click Scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 4) {
                    ForEach(server.shares) { share in
                        shareRow(server: server, share: share)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField(
                    "Add share name on \(server.host)…",
                    text: Binding(
                        get: { newShareDrafts[server.id] ?? "" },
                        set: { newShareDrafts[server.id] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit { addShare(for: server) }

                Button("Add Share") {
                    addShare(for: server)
                }
                .controlSize(.small)
                .disabled((newShareDrafts[server.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func inlineServerEditor(_ server: ServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Edit Server")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Host or IP", text: $editHost)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                TextField("Username", text: $editUsername)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 130)
                TextField("WoL MAC (optional)", text: $editMAC)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 155)
            }

            HStack(spacing: 10) {
                Toggle("Require Home Network (dormant when away)", isOn: $editRequireHome)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Spacer()
            }

            Divider()

            HStack(spacing: 8) {
                Toggle("Enable Remote Shut Down (SSH)", isOn: $editSSHShutdown)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Spacer()

                Button {
                    powerSetupHost = editHost
                    powerSetupUser = editSSHUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? editUsername : editSSHUsername
                    powerSetupKeyPath = editSSHKeyPath
                    showPowerSetupSheet = true
                } label: {
                    Label("Setup Guide…", systemImage: "questionmark.circle")
                        .font(.caption)
                }
                .controlSize(.small)
                .help("View step-by-step Windows OpenSSH & restricted shutdown key setup instructions")
            }

            if editSSHShutdown {
                HStack(spacing: 8) {
                    TextField(
                        "SSH User (default: \(editUsername.isEmpty ? "SMB user" : editUsername))",
                        text: $editSSHUsername
                    )
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 200)

                    TextField(
                        "SSH Key (default: \(RemotePower.defaultKeyPath))",
                        text: $editSSHKeyPath
                    )
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 10) {
                Spacer()

                Button("Cancel") {
                    editingServerID = nil
                    editError = nil
                }
                .controlSize(.small)

                Button("Save") {
                    saveEdit(for: server.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if let editError {
                Text(editError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        )
    }

    private func shareRow(server: ServerConfig, share: ShareConfig) -> some View {
        let state = manager.shareStates[share.id] ?? .unknown
        let cap = manager.shareCapacities[share.id]

        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { share.enabled },
                set: { manager.toggleShareEnabled(serverID: server.id, shareID: share.id, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            Text(share.name)
                .font(.system(size: 12.5))
                .foregroundStyle(share.enabled ? .primary : .secondary)

            Spacer()

            if case .mounted = state, let cap {
                Text("\(cap.formattedUsedOfTotal(style: manager.config.storageUnitStyle)) (\(cap.usedPercentText))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            statusPill(for: state, enabled: share.enabled)

            Button {
                manager.removeShare(serverID: server.id, shareID: share.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Delete Share")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    @ViewBuilder
    private func statusPill(for state: ShareRuntimeState, enabled: Bool) -> some View {
        if case .mounted = state {
            Text("Mounted")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        } else if !enabled {
            Text("Disabled")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else if case .awayFromHome = state {
            Text("Away")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if case .failed(let msg, _, _) = state {
            Text(msg)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(1)
        } else if case .hostOffline = state {
            Text("Offline")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if case .mounting = state {
            Text("Mounting…")
                .font(.caption2)
                .foregroundStyle(.blue)
        } else if case .healing = state {
            Text("Healing…")
                .font(.caption2)
                .foregroundStyle(.blue)
        } else if case .manuallyUnmounted = state {
            Text("Unmounted")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private var addServerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add Server")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Hostname or IP (e.g. nas.local)", text: $newServerHost)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                TextField("Username", text: $newServerUser)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 120)
                Toggle("Home only", isOn: $newServerRequireHome)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Toggle("Auto-sync", isOn: $newServerAutoSync)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Button("Add") {
                    manager.addServer(
                        host: newServerHost,
                        username: newServerUser,
                        autoSyncAllShares: newServerAutoSync,
                        requireHomeNetwork: newServerRequireHome
                    )
                    newServerHost = ""
                    newServerUser = ""
                    newServerAutoSync = false
                    newServerRequireHome = true
                }
                .controlSize(.small)
                .disabled(newServerHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                .foregroundStyle(Color.primary.opacity(0.15))
        )
    }

    // MARK: - Tab 2: Network & System

    private var networkAndSystemTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                homeNetworkSection
                remotePowerSection
                reliabilitySection
                pollingAndStartupSection
            }
            .padding(14)
        }
    }

    private var homeNetworkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Home Network Pinning")
                        .font(.headline)
                    Text("Servers marked \"Home only\" suspend polling completely when you leave these routers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task {
                        pinMessage = await manager.addCurrentHomeNetwork()
                    }
                } label: {
                    Label("Pin Current Network", systemImage: "plus.circle")
                }
                .controlSize(.small)
            }

            if let gw = manager.currentNetwork?.primaryGateway {
                HStack(spacing: 8) {
                    Image(systemName: manager.isOnHomeNetwork ? "house.fill" : "house.slash")
                        .foregroundStyle(manager.isOnHomeNetwork ? .green : .orange)
                    Text("Current:")
                        .font(.caption.weight(.semibold))
                    Text("\(gw.ipAddress)\(gw.macAddress.map { "  •  \($0)" } ?? "")\(gw.interfaceName.map { " (\($0))" } ?? "")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(manager.isOnHomeNetwork ? "Matched" : "Away")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((manager.isOnHomeNetwork ? Color.green : Color.orange).opacity(0.15))
                        .foregroundStyle(manager.isOnHomeNetwork ? .green : .orange)
                        .clipShape(Capsule())
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
            }

            if let pinMessage {
                Text(pinMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if manager.config.homeNetworks.isEmpty {
                Text("No home networks pinned — all servers are checked on any network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(manager.config.homeNetworks) { net in
                        HStack(spacing: 8) {
                            Image(systemName: "wifi.router")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(net.name)
                                    .font(.system(size: 12.5, weight: .medium))
                                Text("Gateway \(net.gatewayIP) • MAC \(net.gatewayMAC ?? "any")")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                manager.removeHomeNetwork(id: net.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Unpin Network")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.03))
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var remotePowerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remote Shut Down (SSH)")
                        .font(.headline)
                    Text("Adds a confirmed \"Off\" button next to online PCs. Unmounts all shares first and uses a shutdown-only SSH key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    powerSetupHost = manager.config.servers.first?.host ?? ""
                    powerSetupUser = manager.config.servers.first?.effectiveSSHUsername ?? ""
                    powerSetupKeyPath = RemotePower.defaultKeyPath
                    showPowerSetupSheet = true
                } label: {
                    Label("Setup Guide…", systemImage: "terminal")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 8) {
                Image(systemName: hasDefaultShutdownKey ? "checkmark.circle.fill" : "key")
                    .foregroundStyle(hasDefaultShutdownKey ? .green : .secondary)
                Text(hasDefaultShutdownKey ? "Shutdown key ready:" : "SSH key not generated yet:")
                    .font(.caption.weight(.semibold))
                Text(RemotePower.defaultKeyPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(hasDefaultShutdownKey ? "Ready" : "Setup needed")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((hasDefaultShutdownKey ? Color.green : Color.orange).opacity(0.15))
                    .foregroundStyle(hasDefaultShutdownKey ? .green : .orange)
                    .clipShape(Capsule())
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )

            if !manager.config.servers.isEmpty {
                VStack(spacing: 5) {
                    ForEach(manager.config.servers) { server in
                        HStack(spacing: 8) {
                            Toggle(isOn: Binding(
                                get: { server.sshShutdownEnabled },
                                set: { manager.setServerSSHShutdown(serverID: server.id, enabled: $0) }
                            )) {
                                HStack(spacing: 6) {
                                    Text(server.host)
                                        .font(.system(size: 12.5, weight: .medium))
                                    Text("(\(server.effectiveSSHUsername.isEmpty ? "no user" : server.effectiveSSHUsername))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)

                            Spacer()

                            Button("Guide…") {
                                powerSetupHost = server.host
                                powerSetupUser = server.effectiveSSHUsername
                                powerSetupKeyPath = server.effectiveSSHKeyPath
                                showPowerSetupSheet = true
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.03))
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var reliabilitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reliability & macOS Integration")
                .font(.headline)

            Toggle(
                "Clean up stale home mounts when away from home",
                isOn: Binding(
                    get: { manager.config.cleanupStaleMountsOnAway },
                    set: { manager.setCleanupStaleMountsOnAway($0) }
                )
            )
            .font(.system(size: 12.5))
            Text("Force-unmounts dead home SMB shares after a 4s grace check when you join another network, preventing Finder beachballs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 18)

            Toggle(
                "Self-heal zombie / unresponsive mounts",
                isOn: Binding(
                    get: { manager.config.healZombieMounts },
                    set: { manager.setHealZombieMounts($0) }
                )
            )
            .font(.system(size: 12.5))
            Text("Detects hung SMB mounts after a Windows reboot/sleep, force-unmounts the dead mount, and remounts cleanly.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 18)

            Toggle(
                "Notify on Keychain authentication failures",
                isOn: Binding(
                    get: { manager.config.notifyOnAuthFailure },
                    set: { manager.setNotifyOnAuthFailure($0) }
                )
            )
            .font(.system(size: 12.5))
            Text("Sends a single macOS alert (max once per 30m per server) if a saved Windows password stops working.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 18)

            Divider()

            Toggle(
                "Prevent Finder from writing .DS_Store files on network shares",
                isOn: Binding(
                    get: { manager.dontWriteNetworkDSStore },
                    set: { manager.setDontWriteNetworkDSStore($0) }
                )
            )
            .font(.system(size: 12.5))
            Text("Sets macOS's com.apple.desktopservices DSDontWriteNetworkStores preference (applies to new Finder sessions).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 18)

            Toggle(
                "Show hidden files and folders in Finder",
                isOn: Binding(
                    get: { manager.showHiddenFiles },
                    set: { manager.setShowHiddenFiles($0) }
                )
            )
            .font(.system(size: 12.5))

            Toggle(
                "Show all filename extensions in Finder",
                isOn: Binding(
                    get: { manager.showFileExtensions },
                    set: { manager.setShowFileExtensions($0) }
                )
            )
            .font(.system(size: 12.5))

            Text("Hidden files restarts Finder to refresh windows; extensions updates Finder and Spotlight live via LaunchServices.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 18)

            Divider()

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Storage capacity units")
                        .font(.system(size: 12.5))
                    Text("Base-2 (1024, GB/TB) matches Windows Explorer; Decimal (1000) matches macOS Finder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: Binding(
                    get: { manager.config.storageUnitStyle },
                    set: { manager.setStorageUnitStyle($0) }
                )) {
                    ForEach(StorageUnitStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 230)
            }

            Divider()

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Updates (v\(UpdateChecker.currentAppVersion()))")
                        .font(.system(size: 12.5))
                    if let status = manager.updateCheckStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(manager.availableUpdate != nil ? .blue : .secondary)
                    } else {
                        Text("Checks GitHub Releases (musaandi/MountKeep) for new versions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let update = manager.availableUpdate {
                    Button("View Page") {
                        manager.openAvailableUpdate()
                    }
                    .controlSize(.small)
                    .disabled(manager.updateInstallProgress.isBusy)

                    if update.canInstallInApp {
                        Button(manager.updateInstallProgress.isBusy ? "Installing…" : "Install v\(update.version)") {
                            manager.installAvailableUpdate()
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(manager.updateInstallProgress.isBusy)
                    }
                }
                Button(manager.isCheckingForUpdates ? "Checking…" : "Check Now") {
                    Task { await manager.checkForUpdates(manual: true) }
                }
                .controlSize(.small)
                .disabled(manager.isCheckingForUpdates || manager.updateInstallProgress.isBusy)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var pollingAndStartupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Adaptive Polling & Startup")
                .font(.headline)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("While waiting for offline PCs:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { manager.config.pollIntervalSeconds },
                        set: { manager.updatePollInterval($0) }
                    )) {
                        ForEach(activeIntervalOptions, id: \.1) { label, value in
                            Text(label).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("When all shares are mounted:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { manager.config.idlePollIntervalSeconds },
                        set: { manager.updateIdlePollInterval($0) }
                    )) {
                        ForEach(idleIntervalOptions, id: \.1) { label, value in
                            Text(label).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                Spacer()

                Toggle("Launch at Login", isOn: Binding(
                    get: { manager.launchAtLogin },
                    set: { manager.setLaunchAtLogin($0) }
                ))
                .font(.system(size: 12.5))
            }

            Divider()

            HStack(spacing: 10) {
                Text("Current cadence: \(manager.activePollCadence.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Open config.json") {
                    manager.openConfigFile()
                }
                .controlSize(.small)

                Button("Reload Config") {
                    manager.reloadConfigFromDisk()
                }
                .controlSize(.small)

                Button("Open Log") {
                    manager.openLogFile()
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func addShare(for server: ServerConfig) {
        let draft = newShareDrafts[server.id] ?? ""
        manager.addShare(serverID: server.id, shareName: draft, enabled: true)
        newShareDrafts[server.id] = ""
    }
}
