import Foundation
import AppKit
import Combine

@MainActor
public final class MountManager: ObservableObject {
    public enum OverallStatus: Equatable {
        case allMounted
        case mounting
        case paused
        case awayFromHome
        case someOffline
        case someFailed
        case noEnabledShares
    }

    public enum PollCadence: Equatable {
        case dormant
        case idle(seconds: Int)
        case active(seconds: Int)

        public var label: String {
            switch self {
            case .dormant: return "Dormant"
            case .idle(let s): return s >= 60 ? "Every \(s / 60)m" : "Every \(s)s"
            case .active(let s): return s >= 60 ? "Every \(s / 60)m" : "Every \(s)s"
            }
        }
    }

    @Published public private(set) var config: AppConfig
    @Published public private(set) var hostStates: [UUID: HostReachabilityState] = [:]
    @Published public private(set) var sshReadiness: [UUID: SSHReadinessState] = [:]
    @Published public private(set) var shareStates: [UUID: ShareRuntimeState] = [:]
    @Published public private(set) var shareCapacities: [UUID: VolumeCapacity] = [:]
    @Published public private(set) var isChecking: Bool = false
    @Published public private(set) var lastCheckDate: Date?
    @Published public private(set) var launchAtLogin: Bool
    @Published public private(set) var statusBanner: String?
    @Published public private(set) var currentNetwork: NetworkSnapshot?
    @Published public private(set) var isOnHomeNetwork: Bool = true
    @Published public private(set) var activePollCadence: PollCadence = .active(seconds: 30)
    @Published public private(set) var dontWriteNetworkDSStore: Bool
    @Published public private(set) var showHiddenFiles: Bool
    @Published public private(set) var showFileExtensions: Bool
    @Published public private(set) var availableUpdate: AppReleaseInfo?
    @Published public private(set) var isCheckingForUpdates: Bool = false
    @Published public private(set) var updateCheckStatus: String?
    @Published public private(set) var updateInstallProgress: UpdateInstallProgress = .idle

    public let configStore: ConfigStore
    private let logger: MountLogger
    private let authNotifier: AuthNotifier

    private var hostIPCache: [UUID: Set<String>] = [:]
    private var hostOfflineStrikes: [UUID: Int] = [:]
    private var failureCounts: [UUID: Int] = [:]
    private var retryDates: [UUID: Date] = [:]
    private var healthFailureCounts: [UUID: Int] = [:]
    private var inFlightHealthChecks: Set<UUID> = []
    private var inFlightMountShareIDs: Set<UUID> = []
    private var inFlightMountServerIDs: Set<UUID> = []
    private var consecutiveNetFSTimeouts: Int = 0
    private var lastNetAuthRecoveryDate: Date?
    private var manuallyUnmountedShareIDs: Set<UUID> = []
    private var lastAutoDiscovery: [UUID: Date] = [:]
    private var lastCapacityRefreshDate: Date?
    private var isRefreshingCapacities = false
    private var lastUpdateCheckDate: Date?
    private var lastHostSyncDate: [UUID: Date] = [:]

    private var pollTimer: Timer?
    private var debouncedCheckTask: Task<Void, Never>?
    private var awayCleanupTask: Task<Void, Never>?
    private var wakePollTasks: [UUID: Task<Void, Never>] = [:]
    private var shutdownPollTasks: [UUID: Task<Void, Never>] = [:]
    private var hostSyncTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingRecheck = false
    private var pendingForceRetry = false
    private var networkObserver: NetworkPathObserver?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    public init(configStore: ConfigStore = ConfigStore(), logger: MountLogger = .shared) {
        self.configStore = configStore
        self.logger = logger
        self.authNotifier = AuthNotifier(logger: logger)
        self.config = configStore.load()
        self.launchAtLogin = LaunchAgentManager.isEnabled()
        self.dontWriteNetworkDSStore = FinderPreferences.dontWriteNetworkDSStore
        self.showHiddenFiles = FinderPreferences.showHiddenFiles
        self.showFileExtensions = FinderPreferences.showFileExtensions
    }

    // MARK: - Computed Status

    public var enabledShares: [(server: ServerConfig, share: ShareConfig)] {
        config.servers.flatMap { server in
            server.shares.filter(\.enabled).map { (server, $0) }
        }
    }

    public var enabledShareCount: Int { enabledShares.count }

    public var mountedEnabledShareCount: Int {
        enabledShares.filter { shareStates[$0.share.id]?.isMounted == true }.count
    }

    /// Combined storage capacity across all currently mounted enabled shares.
    public var overallCapacity: VolumeCapacity? {
        let caps = enabledShares.compactMap { (_, share) -> VolumeCapacity? in
            guard shareStates[share.id]?.isMounted == true else { return nil }
            return shareCapacities[share.id]
        }
        return VolumeCapacity.combine(caps)
    }

    public var overallCapacityDriveCount: Int {
        enabledShares.filter { (_, share) in
            shareStates[share.id]?.isMounted == true && shareCapacities[share.id] != nil
        }.count
    }

    /// Combined storage capacity across all currently mounted enabled shares on a single server.
    public func capacityForServer(_ serverID: UUID) -> VolumeCapacity? {
        guard let server = config.servers.first(where: { $0.id == serverID }) else { return nil }
        let caps = server.shares.filter(\.enabled).compactMap { share -> VolumeCapacity? in
            guard shareStates[share.id]?.isMounted == true else { return nil }
            return shareCapacities[share.id]
        }
        return VolumeCapacity.combine(caps)
    }

    public var hasHomePinningEnabled: Bool {
        !config.homeNetworks.isEmpty && config.servers.contains(where: \.requireHomeNetwork)
    }

    public var allEnabledSharesAreAway: Bool {
        let enabled = enabledShares
        guard !enabled.isEmpty else { return false }
        return enabled.allSatisfy { isServerAway($0.server) }
    }

    public func isServerAway(_ server: ServerConfig) -> Bool {
        server.requireHomeNetwork && !config.homeNetworks.isEmpty && !isOnHomeNetwork
    }

    public var overallStatus: OverallStatus {
        let enabled = enabledShares
        if enabled.isEmpty { return .noEnabledShares }
        if config.paused { return .paused }
        if allEnabledSharesAreAway { return .awayFromHome }

        var anyMounting = false
        var anyFailed = false
        var anyOfflineOrUnmounted = false

        for (server, share) in enabled {
            if isServerAway(server) { continue }
            switch shareStates[share.id] ?? .unknown {
            case .mounted:
                break
            case .mounting, .healing:
                anyMounting = true
            case .failed:
                anyFailed = true
            case .hostOffline, .unmounted, .manuallyUnmounted, .unknown, .awayFromHome:
                anyOfflineOrUnmounted = true
            }
        }

        if anyMounting { return .mounting }
        if anyFailed { return .someFailed }
        if anyOfflineOrUnmounted { return .someOffline }
        return .allMounted
    }

    // MARK: - Lifecycle

    public func start() {
        logger.info("MountKeep starting (active=\(config.pollIntervalSeconds)s, idle=\(config.idlePollIntervalSeconds)s, servers=\(config.servers.count), homeNets=\(config.homeNetworks.count))")
        installObservers()
        refreshMountedSnapshotOnly()

        Task {
            await checkAll(forceRetry: true)
            await checkForUpdates(manual: false)
        }
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        debouncedCheckTask?.cancel()
        awayCleanupTask?.cancel()
        for (_, task) in wakePollTasks { task.cancel() }
        wakePollTasks.removeAll()
        for (_, task) in shutdownPollTasks { task.cancel() }
        shutdownPollTasks.removeAll()
        for (_, task) in hostSyncTasks { task.cancel() }
        hostSyncTasks.removeAll()
        networkObserver?.stop()
        networkObserver = nil
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            center.removeObserver(token)
        }
        workspaceObservers.removeAll()
        let distCenter = DistributedNotificationCenter.default()
        for token in distributedObservers {
            distCenter.removeObserver(token)
        }
        distributedObservers.removeAll()
        logger.info("MountKeep stopped")
    }

    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter

        let sleepToken = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.healthFailureCounts.removeAll()
                self?.hostOfflineStrikes.removeAll()
                self?.lastHostSyncDate.removeAll()
            }
        }

        let wakeToken = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.logger.info("System woke from sleep — scheduling network & mount check")
                self.healthFailureCounts.removeAll()
                self.hostOfflineStrikes.removeAll()
                self.lastHostSyncDate.removeAll()
                self.clearBackoffs()
                self.scheduleDebouncedCheck(delay: 6.0, forceRetry: true)
            }
        }

        let mountToken = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let mountedURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor in
                self?.handleDidMountNotification(volumeURL: mountedURL)
            }
        }

        let unmountToken = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshMountedSnapshotOnly()
                self.recomputePollTimer()
                if !self.config.paused && !self.allEnabledSharesAreAway {
                    self.scheduleDebouncedCheck(delay: 3.0, forceRetry: false)
                }
            }
        }

        workspaceObservers = [sleepToken, wakeToken, mountToken, unmountToken]

        let extToken = DistributedNotificationCenter.default().addObserver(
            forName: FinderPreferences.showAllExtensionsChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshFinderPreferences()
            }
        }
        distributedObservers = [extToken]

        let observer = NetworkPathObserver { [weak self] satisfied in
            Task { @MainActor in
                guard let self else { return }
                self.logger.info("Network path changed (satisfied=\(satisfied)) — scheduling check")
                self.clearBackoffs()
                self.scheduleDebouncedCheck(delay: 2.0, forceRetry: true)
            }
        }
        observer.start()
        self.networkObserver = observer
    }

    private func recomputePollTimer() {
        let desired: PollCadence
        if config.paused {
            desired = .dormant
        } else {
            let activeServers = config.servers.filter { server in
                !isServerAway(server) && server.shares.contains(where: \.enabled)
            }
            if activeServers.isEmpty {
                desired = .dormant
            } else {
                let anyNeedsAttention = activeServers.contains { server in
                    let states = server.shares.filter(\.enabled).map { shareStates[$0.id] ?? .unknown }
                    return HostSyncPolicy.serverNeedsAttention(
                        enabledShareStates: states,
                        hostState: hostStates[server.id] ?? .unknown,
                        hasOfflineStrike: (hostOfflineStrikes[server.id] ?? 0) > 0
                    )
                }
                desired = anyNeedsAttention
                    ? .active(seconds: config.pollIntervalSeconds)
                    : .idle(seconds: config.idlePollIntervalSeconds)
            }
        }

        guard desired != activePollCadence || (desired != .dormant && pollTimer == nil) else {
            return
        }

        activePollCadence = desired
        pollTimer?.invalidate()
        pollTimer = nil

        switch desired {
        case .dormant:
            logger.info("Polling timer suspended (dormant)")
        case .idle(let seconds), .active(let seconds):
            pollTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.checkAll(forceRetry: false)
                }
            }
        }
    }

    private func scheduleDebouncedCheck(delay: TimeInterval, forceRetry: Bool) {
        debouncedCheckTask?.cancel()
        debouncedCheckTask = Task { [weak self] in
            let ns = UInt64(max(0.1, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            await self?.checkAll(forceRetry: forceRetry)
        }
    }

    private func clearBackoffs() {
        failureCounts.removeAll()
        retryDates.removeAll()
    }

    // MARK: - Core Reconciliation

    @discardableResult
    public func refreshMountedSnapshotOnly() -> Set<UUID> {
        let mounted = MountInspector.mountedSMBShares()
        return applyMountedSnapshot(mounted)
    }

    private func handleDidMountNotification(volumeURL: URL?) {
        let mounted = MountInspector.mountedSMBShares()
        var targetServerIDs = applyMountedSnapshot(mounted)

        // If no tracked share transitioned to mounted, check whether this event was an SMB mount
        // (ignoring local USB drives, DMGs, and APFS snapshots so they trigger zero network probes).
        if targetServerIDs.isEmpty,
           let volumePath = volumeURL?.standardizedFileURL.path,
           let smbShare = mounted.first(where: { $0.mountPoint == volumePath }) {
            let normMountHost = MountInspector.normalizeHost(smbShare.host)
            var matchedAny = false
            for server in config.servers {
                let ips = hostIPCache[server.id] ?? []
                if MountInspector.normalizeHost(server.host) == normMountHost || ips.contains(smbShare.host) {
                    targetServerIDs.insert(server.id)
                    matchedAny = true
                }
            }
            if !matchedAny {
                for server in config.servers where !isServerAway(server) {
                    let hasNoCachedIPs = hostIPCache[server.id]?.isEmpty ?? true
                    if hasNoCachedIPs && hostStates[server.id]?.isOnline != true {
                        targetServerIDs.insert(server.id)
                    }
                }
            }
        }

        for serverID in targetServerIDs {
            syncHostOnlineStateIfNeeded(forServerID: serverID, triggerFollowUpCheckIfUnmounted: true)
        }
        recomputePollTimer()
    }

    private func cachedPrimaryIP(forServerID serverID: UUID) -> String? {
        if case .online(let existingIP) = hostStates[serverID], let existingIP {
            return existingIP
        }
        return hostIPCache[serverID]?.sorted().first
    }

    /// Runs a single coalesced, lightweight wakefulness check (TCP :445 and/or SSH :22) for a server
    /// right after a drive mounts, ONLY if its host or SSH state is currently out of sync.
    private func syncHostOnlineStateIfNeeded(
        forServerID serverID: UUID,
        triggerFollowUpCheckIfUnmounted: Bool = false
    ) {
        guard let server = config.servers.first(where: { $0.id == serverID }) else { return }
        let currentHostState = hostStates[serverID] ?? .unknown
        let currentSSH = sshReadiness[serverID]
        let hasStrike = (hostOfflineStrikes[serverID] ?? 0) > 0

        guard HostSyncPolicy.needsOnlineSync(
            hostState: currentHostState,
            sshEnabled: server.canRemoteShutdown,
            sshReadiness: currentSSH,
            hasOfflineStrike: hasStrike,
            isAway: isServerAway(server)
        ) else {
            return
        }

        // Coalesce burst mount events (e.g. multiple shares mounting in quick succession).
        guard hostSyncTasks[serverID] == nil else { return }
        if let last = lastHostSyncDate[serverID], Date().timeIntervalSince(last) < 3.0 {
            return
        }

        hostSyncTasks[serverID] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.hostSyncTasks[serverID] = nil
                self.lastHostSyncDate[serverID] = Date()
            }

            guard let latestServer = self.config.servers.first(where: { $0.id == serverID }),
                  !self.isServerAway(latestServer),
                  self.hostStates[serverID] != .shuttingDown else {
                return
            }

            let stateAtStart = self.hostStates[serverID] ?? .unknown
            let needsHostProbe = !stateAtStart.isOnline || ((self.hostOfflineStrikes[serverID] ?? 0) > 0)

            // If host is already online with no offline strikes and only SSH readiness is stale,
            // skip the redundant TCP :445 handshake and check SSH :22 directly.
            if !needsHostProbe {
                if latestServer.canRemoteShutdown {
                    await self.refreshSSHReadiness(forServerID: serverID)
                }
                self.recomputePollTimer()
                return
            }

            let wasOffline = !stateAtStart.isOnline
            let probe = await NetworkReachability.probeSMBHost(latestServer.host, port: 445, timeout: 1.5)
            guard !Task.isCancelled else { return }

            let previousIPs = self.hostIPCache[serverID] ?? []
            if !probe.allIPs.isEmpty {
                self.hostIPCache[serverID] = probe.allIPs
            }

            var isOnlineNow = probe.isReachable
            if !isOnlineNow {
                let mountedPoints = latestServer.shares.compactMap { self.shareStates[$0.id]?.mountPoint }
                if !mountedPoints.isEmpty {
                    let healthResults = await self.probeMountedSharesHealth(mountPoints: mountedPoints, timeout: 2.0)
                    isOnlineNow = healthResults.values.contains(.healthy)
                }
            }

            guard !Task.isCancelled, self.hostStates[serverID] != .shuttingDown else { return }

            if isOnlineNow {
                let ip = probe.primaryIP ?? self.cachedPrimaryIP(forServerID: serverID)
                self.hostOfflineStrikes[serverID] = nil
                self.hostStates[serverID] = .online(ipAddress: ip)
                self.wakePollTasks[serverID]?.cancel()
                self.wakePollTasks[serverID] = nil

                if !probe.allIPs.isEmpty && probe.allIPs != previousIPs {
                    self.refreshMountedSnapshotOnly()
                }
                if self.learnMACIfMissing(serverID: serverID, ip: ip) {
                    self.saveConfig()
                }
                if latestServer.canRemoteShutdown {
                    await self.refreshSSHReadiness(forServerID: serverID)
                }
                self.logger.info("Synced \(latestServer.host) to online after drive mount\(ip.map { " (\($0))" } ?? "")")
                self.recomputePollTimer()

                if triggerFollowUpCheckIfUnmounted && wasOffline && !self.config.paused {
                    let hasWaitingShares = latestServer.shares.contains { share in
                        guard share.enabled, !self.manuallyUnmountedShareIDs.contains(share.id) else { return false }
                        return self.shareStates[share.id]?.isMounted != true
                    }
                    if hasWaitingShares {
                        self.scheduleDebouncedCheck(delay: 1.5, forceRetry: false)
                    }
                }
            }
        }
    }

    private func probeMountedSharesHealth(
        mountPoints: [String],
        timeout: TimeInterval
    ) async -> [String: MountHealth] {
        guard !mountPoints.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, MountHealth).self) { group in
            for mp in mountPoints {
                group.addTask {
                    let health = await NetFSMounter.checkMountHealth(mountPoint: mp, timeout: timeout)
                    return (mp, health)
                }
            }
            var results: [String: MountHealth] = [:]
            for await (mp, health) in group {
                results[mp] = health
            }
            return results
        }
    }

    /// Asynchronously refreshes live disk usage (`statfs`) for mounted shares on non-away servers.
    /// Throttled to at most once every 10 seconds unless `force == true`.
    public func refreshCapacities(force: Bool = false) async {
        guard !isRefreshingCapacities else { return }
        if !force, let last = lastCapacityRefreshDate, Date().timeIntervalSince(last) < 10 {
            return
        }

        var targets: [(shareID: UUID, mountPoint: String)] = []
        for server in config.servers where !isServerAway(server) {
            for share in server.shares where share.enabled {
                if case .mounted(let mp) = shareStates[share.id] {
                    targets.append((share.id, mp))
                }
            }
        }
        guard !targets.isEmpty else { return }

        isRefreshingCapacities = true
        defer {
            isRefreshingCapacities = false
            lastCapacityRefreshDate = Date()
        }

        let updated: [(UUID, VolumeCapacity?)] = await withTaskGroup(
            of: (UUID, VolumeCapacity?).self
        ) { group in
            for item in targets {
                group.addTask {
                    let cap = await MountInspector.fetchFreshCapacity(forMountPoint: item.mountPoint, timeout: 2.5)
                    return (item.shareID, cap)
                }
            }
            var out: [(UUID, VolumeCapacity?)] = []
            for await res in group { out.append(res) }
            return out
        }

        for (shareID, cap) in updated {
            if let cap, shareStates[shareID]?.isMounted == true {
                shareCapacities[shareID] = cap
            }
        }
    }

    @discardableResult
    private func applyMountedSnapshot(_ mounted: [MountedSMBShare]) -> Set<UUID> {
        var newlyMountedServerIDs: Set<UUID> = []
        for server in config.servers {
            let ips = hostIPCache[server.id] ?? []
            for share in server.shares {
                if let match = mounted.first(where: {
                    MountInspector.matches(
                        mounted: $0,
                        configuredHost: server.host,
                        configuredHostIPs: ips,
                        configuredShareName: share.name
                    )
                }) {
                    if case .healing = shareStates[share.id] { continue }
                    let wasMounted = shareStates[share.id]?.isMounted == true
                    shareStates[share.id] = .mounted(mountPoint: match.mountPoint)
                    if !wasMounted {
                        newlyMountedServerIDs.insert(server.id)
                    }
                    if let cap = match.capacity {
                        shareCapacities[share.id] = cap
                    }
                    failureCounts[share.id] = nil
                    retryDates[share.id] = nil
                    manuallyUnmountedShareIDs.remove(share.id)
                } else {
                    shareCapacities[share.id] = nil
                    if case .mounted = shareStates[share.id] {
                        if isServerAway(server) {
                            shareStates[share.id] = .awayFromHome
                        } else {
                            shareStates[share.id] = manuallyUnmountedShareIDs.contains(share.id)
                                ? .manuallyUnmounted
                                : .unmounted
                        }
                    } else if shareStates[share.id] == nil {
                        if isServerAway(server) {
                            shareStates[share.id] = .awayFromHome
                        } else {
                            shareStates[share.id] = manuallyUnmountedShareIDs.contains(share.id)
                                ? .manuallyUnmounted
                                : .unmounted
                        }
                    }
                }
            }
        }
        return newlyMountedServerIDs
    }

    public func checkAll(forceRetry: Bool = false) async {
        if isChecking {
            pendingRecheck = true
            pendingForceRetry = pendingForceRetry || forceRetry
            return
        }

        isChecking = true
        defer {
            isChecking = false
            lastCheckDate = Date()
            recomputePollTimer()
            if pendingRecheck {
                let nextForce = pendingForceRetry
                pendingRecheck = false
                pendingForceRetry = false
                Task { @MainActor in
                    await self.checkAll(forceRetry: nextForce)
                }
            }
        }

        // 1. Evaluate current network fingerprint (zero privacy prompts, ~5ms).
        let snapshot = await HomeNetworkDetector.captureSnapshot()
        currentNetwork = snapshot

        let initialMounted = MountInspector.mountedSMBShares()
        applyMountedSnapshot(initialMounted)

        // One-time v1 -> v2 migration: auto-capture current router as Home Network if home shares are active/reachable.
        if config.version < AppConfig.currentVersion {
            var migrated = false
            if config.homeNetworks.isEmpty, let fingerprint = HomeNetworkDetector.makeFingerprint(from: snapshot) {
                let anyMounted = !initialMounted.isEmpty
                var anyHomeServerReachable = anyMounted
                if !anyHomeServerReachable, let firstHome = config.servers.first(where: \.requireHomeNetwork) {
                    let probe = await NetworkReachability.probeSMBHost(firstHome.host, port: 445, timeout: 1.5)
                    anyHomeServerReachable = probe.isReachable
                }
                if anyHomeServerReachable {
                    config.homeNetworks = [fingerprint]
                    logger.info("Auto-pinned home network: \(fingerprint.name) (MAC: \(fingerprint.gatewayMAC ?? "any"))")
                    migrated = true
                }
            } else {
                migrated = true
            }
            if migrated {
                config.version = AppConfig.currentVersion
                saveConfig()
            }
        }

        let matchedHome = HomeNetworkDetector.matches(
            snapshot: snapshot,
            allowedNetworks: config.homeNetworks
        )
        if matchedHome != isOnHomeNetwork {
            logger.info(matchedHome ? "Returned to home network — activating home servers" : "Left home network — entering dormant mode for home servers")
        }
        isOnHomeNetwork = matchedHome

        let serversSnapshot = config.servers
        let mountTimeout = TimeInterval(config.mountTimeoutSeconds)

        // 2. Separate away-from-home servers (zero DNS/TCP probes!) from eligible servers.
        var eligibleServers: [ServerConfig] = []
        var staleAwayMountPoints: [(server: ServerConfig, share: ShareConfig, mountPoint: String)] = []

        for server in serversSnapshot {
            if isServerAway(server) {
                hostStates[server.id] = .awayFromHome
                for share in server.shares where share.enabled {
                    if let mountPoint = shareStates[share.id]?.mountPoint {
                        staleAwayMountPoints.append((server, share, mountPoint))
                    } else {
                        shareStates[share.id] = .awayFromHome
                    }
                }
            } else {
                eligibleServers.append(server)
            }
        }

        // Schedule stale-mount cleanup on away departure (with 4s confirmation grace against brief Wi-Fi roams).
        if !staleAwayMountPoints.isEmpty && config.cleanupStaleMountsOnAway {
            scheduleAwayStaleCleanup()
        } else if isOnHomeNetwork {
            awayCleanupTask?.cancel()
            awayCleanupTask = nil
        }

        guard !eligibleServers.isEmpty else {
            return
        }

        // 3. Probe only eligible hosts concurrently on port 445.
        for server in eligibleServers {
            if hostStates[server.id] == nil || hostStates[server.id] == .awayFromHome {
                hostStates[server.id] = .checking
            }
        }

        let probeResults: [(UUID, HostProbeResult)] = await withTaskGroup(
            of: (UUID, HostProbeResult).self
        ) { group in
            for server in eligibleServers {
                let serverID = server.id
                let host = server.host
                group.addTask {
                    let result = await NetworkReachability.probeSMBHost(host, port: 445, timeout: 1.5)
                    return (serverID, result)
                }
            }
            var collected: [(UUID, HostProbeResult)] = []
            for await item in group {
                collected.append(item)
            }
            return collected
        }

        var reachableByServer: [UUID: Bool] = [:]
        var precomputedHealthByMountPoint: [String: MountHealth] = [:]
        var learnedAnyMAC = false
        for (serverID, result) in probeResults {
            if !result.allIPs.isEmpty {
                hostIPCache[serverID] = result.allIPs
            }
            reachableByServer[serverID] = result.isReachable

            if result.isReachable {
                hostOfflineStrikes[serverID] = nil
                if hostStates[serverID] != .shuttingDown {
                    let ip = result.primaryIP ?? cachedPrimaryIP(forServerID: serverID)
                    hostStates[serverID] = .online(ipAddress: ip)
                    wakePollTasks[serverID]?.cancel()
                    wakePollTasks[serverID] = nil
                }

                // Auto-learn LAN MAC address for Wake-on-LAN if not already saved.
                if learnMACIfMissing(serverID: serverID, ip: result.primaryIP, snapshot: snapshot) {
                    learnedAnyMAC = true
                }
            } else {
                let previousState = hostStates[serverID] ?? .unknown
                let srv = config.servers.first(where: { $0.id == serverID })
                let mountedPoints = srv?.shares.compactMap { shareStates[$0.id]?.mountPoint } ?? []

                var anyMountedShareHealthy = false
                if previousState != .shuttingDown && previousState != .waking && !mountedPoints.isEmpty {
                    let healthByMount = await probeMountedSharesHealth(mountPoints: mountedPoints, timeout: 2.5)
                    for (mp, health) in healthByMount {
                        precomputedHealthByMountPoint[mp] = health
                    }
                    anyMountedShareHealthy = healthByMount.values.contains(.healthy)
                }

                let outcome = HostSyncPolicy.evaluateFailedHostProbe(
                    previousState: previousState,
                    mountedShareCount: mountedPoints.count,
                    anyMountedShareHealthy: anyMountedShareHealthy,
                    currentStrikes: hostOfflineStrikes[serverID] ?? 0,
                    primaryIP: result.primaryIP,
                    cachedIP: cachedPrimaryIP(forServerID: serverID)
                )

                reachableByServer[serverID] = outcome.treatedAsReachable
                hostStates[serverID] = outcome.nextHostState
                hostOfflineStrikes[serverID] = outcome.nextStrikes > 0 ? outcome.nextStrikes : nil

                if outcome.treatedAsReachable {
                    wakePollTasks[serverID]?.cancel()
                    wakePollTasks[serverID] = nil
                } else if outcome.nextStrikes > 0, let host = srv?.host {
                    logger.warn("Host probe failed for \(host) while \(mountedPoints.count) share(s) mounted (strike \(outcome.nextStrikes)/2) — holding online state for re-verification")
                } else if outcome.nextHostState == .offline {
                    shutdownPollTasks[serverID]?.cancel()
                    shutdownPollTasks[serverID] = nil
                }
            }
        }
        if learnedAnyMAC {
            saveConfig()
        }

        // Verify SSH port 22 + local key readiness for servers with Remote Shut Down enabled.
        await refreshSSHReadiness(reachableByServer: reachableByServer)

        // Re-apply snapshot now that IP addresses are cached.
        applyMountedSnapshot(MountInspector.mountedSMBShares())

        if config.paused {
            for server in eligibleServers {
                let isOnline = reachableByServer[server.id] ?? false
                for share in server.shares where share.enabled {
                    guard shareStates[share.id]?.isMounted != true else { continue }
                    if manuallyUnmountedShareIDs.contains(share.id) {
                        shareStates[share.id] = .manuallyUnmounted
                    } else {
                        shareStates[share.id] = isOnline ? .unmounted : .hostOffline
                    }
                }
            }
            await refreshCapacities(force: forceRetry)
            return
        }

        // 4. Zombie / Hung Mount Self-Healing for mounted shares on eligible servers.
        if config.healZombieMounts {
            await healStaleMountsIfNeeded(
                for: eligibleServers,
                reachableByServer: reachableByServer,
                precomputedHealthByMountPoint: precomputedHealthByMountPoint
            )
        }

        // 5. Mount per-server sequentially, with different servers running concurrently.
        await withTaskGroup(of: Void.self) { group in
            for server in eligibleServers {
                if hostStates[server.id] == .shuttingDown {
                    continue
                }
                let isOnline = reachableByServer[server.id] ?? false
                if !isOnline {
                    for share in server.shares where share.enabled {
                        if shareStates[share.id]?.isMounted != true && !manuallyUnmountedShareIDs.contains(share.id) {
                            shareStates[share.id] = .hostOffline
                        }
                    }
                    continue
                }

                let serverID = server.id
                group.addTask { [weak self] in
                    await self?.reconcileOnlineServer(
                        serverID: serverID,
                        forceRetry: forceRetry,
                        timeout: mountTimeout
                    )
                }
            }
        }

        applyMountedSnapshot(MountInspector.mountedSMBShares())
        await refreshCapacities(force: forceRetry)
    }

    // MARK: - Stale Cleanup & Zombie Healing

    private func scheduleAwayStaleCleanup() {
        guard awayCleanupTask == nil else { return }
        awayCleanupTask = Task { [weak self] in
            // 4-second grace period to avoid reacting to brief Wi-Fi channel roams at home.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.awayCleanupTask = nil

            let confirmSnap = await HomeNetworkDetector.captureSnapshot()
            let backHome = HomeNetworkDetector.matches(
                snapshot: confirmSnap,
                allowedNetworks: self.config.homeNetworks
            )
            guard !backHome, self.config.cleanupStaleMountsOnAway else { return }

            let live = MountInspector.mountedSMBShares()
            for server in self.config.servers where server.requireHomeNetwork {
                let ips = self.hostIPCache[server.id] ?? []
                for share in server.shares {
                    if let match = live.first(where: {
                        MountInspector.matches(
                            mounted: $0,
                            configuredHost: server.host,
                            configuredHostIPs: ips,
                            configuredShareName: share.name
                        )
                    }) {
                        self.logger.info("Away from home — force-unmounting stale share \(match.mountPoint)")
                        let res = await NetFSMounter.forceUnmount(mountPoint: match.mountPoint)
                        if case .failure(let err) = res {
                            self.logger.warn("Could not clean up \(match.mountPoint): \(err.localizedDescription)")
                        } else {
                            self.shareStates[share.id] = .awayFromHome
                        }
                    }
                }
            }
            self.refreshMountedSnapshotOnly()
        }
    }

    private func healStaleMountsIfNeeded(
        for servers: [ServerConfig],
        reachableByServer: [UUID: Bool],
        precomputedHealthByMountPoint: [String: MountHealth] = [:]
    ) async {
        var toProbe: [(server: ServerConfig, share: ShareConfig, mountPoint: String)] = []
        var alreadyMeasured: [(ServerConfig, ShareConfig, String, MountHealth)] = []
        for server in servers {
            for share in server.shares where share.enabled {
                if case .mounted(let mp) = shareStates[share.id], !inFlightHealthChecks.contains(share.id) {
                    if let cached = precomputedHealthByMountPoint[mp] {
                        alreadyMeasured.append((server, share, mp, cached))
                    } else {
                        toProbe.append((server, share, mp))
                    }
                }
            }
        }
        guard !toProbe.isEmpty || !alreadyMeasured.isEmpty else { return }

        for item in toProbe {
            inFlightHealthChecks.insert(item.share.id)
        }

        let probedResults: [(ServerConfig, ShareConfig, String, MountHealth)]
        if toProbe.isEmpty {
            probedResults = []
        } else {
            probedResults = await withTaskGroup(
                of: (ServerConfig, ShareConfig, String, MountHealth).self
            ) { group in
                for item in toProbe {
                    group.addTask {
                        let health = await NetFSMounter.checkMountHealth(mountPoint: item.mountPoint, timeout: 3.0)
                        return (item.server, item.share, item.mountPoint, health)
                    }
                }
                var out: [(ServerConfig, ShareConfig, String, MountHealth)] = []
                for await res in group { out.append(res) }
                return out
            }
        }

        let results = alreadyMeasured + probedResults

        var healedAny = false
        for (server, share, mountPoint, health) in results {
            inFlightHealthChecks.remove(share.id)
            switch health {
            case .healthy:
                healthFailureCounts[share.id] = nil

            case .stale(let reason):
                let count = (healthFailureCounts[share.id] ?? 0) + 1
                healthFailureCounts[share.id] = count
                let hostOnline = reachableByServer[server.id] ?? false
                // Immediately heal hard errors when host is reachable, or after 2 consecutive failures.
                if hostOnline || count >= 2 {
                    shareStates[share.id] = .healing
                    logger.warn("Detected stale mount at \(mountPoint) (\(reason)) — force-unmounting to heal")
                    _ = await NetFSMounter.forceUnmount(mountPoint: mountPoint)
                    healthFailureCounts[share.id] = nil
                    shareStates[share.id] = hostOnline ? .unmounted : .hostOffline
                    healedAny = true
                }

            case .timedOut:
                let count = (healthFailureCounts[share.id] ?? 0) + 1
                healthFailureCounts[share.id] = count
                logger.warn("Health probe timed out for \(mountPoint) (strike \(count)/2)")
                if count >= 2 {
                    shareStates[share.id] = .healing
                    logger.warn("Mount \(mountPoint) unresponsive across 2 checks — force-unmounting to heal")
                    _ = await NetFSMounter.forceUnmount(mountPoint: mountPoint)
                    healthFailureCounts[share.id] = nil
                    let hostOnline = reachableByServer[server.id] ?? false
                    shareStates[share.id] = hostOnline ? .unmounted : .hostOffline
                    healedAny = true
                }
            }
        }

        if healedAny {
            try? await Task.sleep(nanoseconds: 400_000_000)
            applyMountedSnapshot(MountInspector.mountedSMBShares())
        }
    }

    private enum ShareMountStepResult {
        case mounted
        case failedSingleShare
        case failedServerWide(message: String, isAuthError: Bool)
    }

    private func reconcileOnlineServer(serverID: UUID, forceRetry: Bool, timeout: TimeInterval) async {
        guard !inFlightMountServerIDs.contains(serverID),
              let server = config.servers.first(where: { $0.id == serverID }) else { return }
        inFlightMountServerIDs.insert(serverID)
        defer { inFlightMountServerIDs.remove(serverID) }

        for share in server.shares where share.enabled {
            guard !config.paused else { return }
            if hostStates[serverID] == .shuttingDown { return }
            if shareStates[share.id]?.isMounted == true { continue }
            if inFlightMountShareIDs.contains(share.id) { continue }
            if manuallyUnmountedShareIDs.contains(share.id) {
                shareStates[share.id] = .manuallyUnmounted
                continue
            }
            if !forceRetry, let nextRetry = retryDates[share.id], Date() < nextRetry {
                continue
            }

            // Cold SMB sessions (first share mounted on a newly woken/online server) can take 20-35s.
            // Giving the initial share at least 45s avoids premature NetFSMountURLCancel calls that can
            // leak stuck DCERPC threads inside macOS's NetAuthSysAgent.
            let anyMountedOnServer = server.shares.contains { shareStates[$0.id]?.isMounted == true }
            let effectiveTimeout = anyMountedOnServer ? timeout : max(timeout, 45.0)

            let step = await mountSingleShareInternal(server: server, share: share, timeout: effectiveTimeout)
            if case .failedServerWide(let message, let isAuthError) = step {
                // Short-circuit remaining unmounted shares on this server so we don't trigger cascading
                // NetFSMountURLCancel calls or orphan /Volumes/<Share> directories.
                let retryAt = retryDates[share.id]
                for remaining in server.shares where remaining.enabled && remaining.id != share.id {
                    guard shareStates[remaining.id]?.isMounted != true,
                          !manuallyUnmountedShareIDs.contains(remaining.id) else { continue }
                    if let retryAt {
                        retryDates[remaining.id] = retryAt
                    }
                    shareStates[remaining.id] = .failed(
                        message: message,
                        retryAt: retryAt,
                        isAuthError: isAuthError
                    )
                }
                break
            }
        }

        guard let updatedServer = config.servers.first(where: { $0.id == serverID }),
              updatedServer.autoSyncAllShares else {
            return
        }

        let hasMountedShareOnServer = updatedServer.shares.contains { shareStates[$0.id]?.isMounted == true }
        guard hasMountedShareOnServer else { return }

        let now = Date()
        let lastScan = lastAutoDiscovery[serverID]
        let shouldScan = forceRetry || lastScan == nil || now.timeIntervalSince(lastScan!) >= 300
        guard shouldScan else { return }

        lastAutoDiscovery[serverID] = now
        let discovery = await NetFSMounter.discoverShares(host: updatedServer.host, username: updatedServer.username)
        guard case .success(let discoveredNames) = discovery else { return }

        var newlyAdded: [ShareConfig] = []
        if let idx = config.servers.firstIndex(where: { $0.id == serverID }) {
            let existingLower = Set(config.servers[idx].shares.map { $0.name.lowercased() })
            for name in discoveredNames where !existingLower.contains(name.lowercased()) {
                let newShare = ShareConfig(name: name, enabled: true)
                config.servers[idx].shares.append(newShare)
                newlyAdded.append(newShare)
            }
            if !newlyAdded.isEmpty {
                saveConfig()
                logger.info("Auto-discovered \(newlyAdded.count) new share(s) on \(updatedServer.host): \(newlyAdded.map(\.name).joined(separator: ", "))")
                let refreshedServer = config.servers[idx]
                for newShare in newlyAdded {
                    await mountSingleShareInternal(server: refreshedServer, share: newShare, timeout: timeout)
                }
            }
        }
    }

    @discardableResult
    private func mountSingleShareInternal(
        server: ServerConfig,
        share: ShareConfig,
        timeout: TimeInterval
    ) async -> ShareMountStepResult {
        guard !inFlightMountShareIDs.contains(share.id) else {
            return .failedSingleShare
        }
        inFlightMountShareIDs.insert(share.id)
        defer { inFlightMountShareIDs.remove(share.id) }

        shareStates[share.id] = .mounting
        logger.info("Mounting smb://\(server.username.isEmpty ? "" : "\(server.username)@")\(server.host)/\(share.name)")

        let outcome = await NetFSMounter.mount(
            host: server.host,
            username: server.username,
            shareName: share.name,
            timeout: timeout
        )

        switch outcome {
        case .mounted(let mountPoint):
            consecutiveNetFSTimeouts = 0
            hostOfflineStrikes[server.id] = nil
            failureCounts[share.id] = nil
            retryDates[share.id] = nil
            healthFailureCounts[share.id] = nil
            manuallyUnmountedShareIDs.remove(share.id)
            shareStates[share.id] = .mounted(mountPoint: mountPoint)
            authNotifier.clearThrottle(forServerID: server.id)
            logger.info("Mounted \(server.host)/\(share.name) at \(mountPoint)")
            syncHostOnlineStateIfNeeded(forServerID: server.id)
            return .mounted

        case .failed(let code, let message, let isAuthError):
            let live = MountInspector.mountedSMBShares()
            let ips = hostIPCache[server.id] ?? []
            if let existing = live.first(where: {
                MountInspector.matches(
                    mounted: $0,
                    configuredHost: server.host,
                    configuredHostIPs: ips,
                    configuredShareName: share.name
                )
            }) {
                consecutiveNetFSTimeouts = 0
                hostOfflineStrikes[server.id] = nil
                failureCounts[share.id] = nil
                retryDates[share.id] = nil
                shareStates[share.id] = .mounted(mountPoint: existing.mountPoint)
                authNotifier.clearThrottle(forServerID: server.id)
                syncHostOnlineStateIfNeeded(forServerID: server.id)
                return .mounted
            }

            let count = (failureCounts[share.id] ?? 0) + 1
            failureCounts[share.id] = count
            let delay = BackoffPolicy.delaySeconds(forFailureCount: count)
            let retryAt = Date().addingTimeInterval(delay)
            retryDates[share.id] = retryAt
            shareStates[share.id] = .failed(message: message, retryAt: retryAt, isAuthError: isAuthError)
            logger.warn("Failed to mount \(server.host)/\(share.name) (attempt \(count), retry in \(Int(delay))s): \(message)")

            if isAuthError && config.notifyOnAuthFailure {
                authNotifier.notifyAuthFailure(
                    serverID: server.id,
                    host: server.host,
                    username: server.username,
                    shareName: share.name
                )
            }

            if code == ETIMEDOUT {
                consecutiveNetFSTimeouts += 1
                await recoverNetAuthSysAgentIfWedged(forServer: server)
            }

            let anyMountedOnServer = server.shares.contains { shareStates[$0.id]?.isMounted == true }
            // Short-circuit remaining shares on auth failure, EHOSTUNREACH, or a cold 45s ETIMEDOUT
            // when zero shares are mounted yet (avoids cascading NetFSMountURLCancel calls that can
            // wedge NetAuthSysAgent or create orphan /Volumes/<Share> stubs).
            let isServerWideFailure = isAuthError || (!anyMountedOnServer && (code == EHOSTUNREACH || code == ETIMEDOUT))
            if isServerWideFailure {
                return .failedServerWide(message: message, isAuthError: isAuthError)
            }
            return .failedSingleShare
        }
    }

    /// Detects a deadlocked macOS `NetAuthSysAgent` (TCP :445 reachable while NetFS times out twice)
    /// and restarts the user's `NetAuthSysAgent` daemon (throttled to at most once every 10 minutes).
    private func recoverNetAuthSysAgentIfWedged(forServer server: ServerConfig) async {
        guard consecutiveNetFSTimeouts >= 2 else { return }
        if let last = lastNetAuthRecoveryDate, Date().timeIntervalSince(last) < 600 {
            return
        }
        // Only act if no other share is actively mounting right now.
        let otherInFlight = inFlightMountShareIDs.count > 1
        guard !otherInFlight else { return }

        // Confirm the SMB server is genuinely alive right now on TCP :445.
        let liveProbe = await NetworkReachability.probeSMBHost(server.host, port: 445, timeout: 1.5)
        guard liveProbe.isReachable else { return }

        lastNetAuthRecoveryDate = Date()
        consecutiveNetFSTimeouts = 0
        logger.warn("Detected unresponsive macOS NetAuthSysAgent (TCP :445 reachable on \(server.host) while NetFS timed out twice) — restarting NetAuthSysAgent to recover")
        let restarted = await NetFSMounter.restartNetAuthSysAgent()
        if restarted {
            statusBanner = "Restarted unresponsive macOS NetAuthSysAgent — retrying mounts…"
            clearBackoffs()
            scheduleDebouncedCheck(delay: 1.5, forceRetry: true)
        }
    }

    public func restartNetAuthAgentNow() {
        Task {
            logger.info("User triggered manual NetAuthSysAgent restart")
            _ = await NetFSMounter.restartNetAuthSysAgent()
            consecutiveNetFSTimeouts = 0
            statusBanner = "Restarted macOS NetAuthSysAgent — re-checking mounts…"
            clearBackoffs()
            await checkAll(forceRetry: true)
        }
    }

    // MARK: - User Actions

    public func dismissBanner() {
        statusBanner = nil
    }

    public func syncNow() {
        clearBackoffs()
        Task {
            await checkAll(forceRetry: true)
            await checkForUpdates(manual: false)
        }
    }

    public func mountAllNow() {
        manuallyUnmountedShareIDs.removeAll()
        clearBackoffs()
        if config.paused {
            config.paused = false
            saveConfig()
        }
        Task {
            await checkAll(forceRetry: true)
            await checkForUpdates(manual: false)
        }
    }

    public func togglePause() {
        config.paused.toggle()
        saveConfig()
        logger.info(config.paused ? "Auto-mount paused by user" : "Auto-mount resumed by user")
        recomputePollTimer()
        if !config.paused {
            clearBackoffs()
            Task { await checkAll(forceRetry: true) }
        }
    }

    public func mountShare(serverID: UUID, shareID: UUID) {
        guard !inFlightMountShareIDs.contains(shareID),
              !inFlightMountServerIDs.contains(serverID),
              let server = config.servers.first(where: { $0.id == serverID }),
              let share = server.shares.first(where: { $0.id == shareID }) else { return }

        manuallyUnmountedShareIDs.remove(shareID)
        failureCounts[shareID] = nil
        retryDates[shareID] = nil

        let anyMounted = server.shares.contains { shareStates[$0.id]?.isMounted == true }
        let timeout = anyMounted ? TimeInterval(config.mountTimeoutSeconds) : max(TimeInterval(config.mountTimeoutSeconds), 45.0)
        Task {
            guard !inFlightMountServerIDs.contains(serverID) else { return }
            inFlightMountServerIDs.insert(serverID)
            defer { inFlightMountServerIDs.remove(serverID) }

            let probe = await NetworkReachability.probeSMBHost(server.host, port: 445, timeout: 1.5)
            if !probe.allIPs.isEmpty {
                hostIPCache[server.id] = probe.allIPs
            }
            if probe.isReachable {
                hostOfflineStrikes[server.id] = nil
                wakePollTasks[server.id]?.cancel()
                wakePollTasks[server.id] = nil
                hostStates[server.id] = .online(ipAddress: probe.primaryIP ?? cachedPrimaryIP(forServerID: server.id))
                syncHostOnlineStateIfNeeded(forServerID: server.id)
            } else {
                if !anyMounted {
                    hostStates[server.id] = .offline
                }
                shareStates[share.id] = .hostOffline
                return
            }
            await mountSingleShareInternal(server: server, share: share, timeout: timeout)
            recomputePollTimer()
        }
    }

    public func unmountShare(serverID: UUID, shareID: UUID) {
        guard let mountPoint = shareStates[shareID]?.mountPoint else { return }
        manuallyUnmountedShareIDs.insert(shareID)
        Task {
            let result = await NetFSMounter.unmount(mountPoint: mountPoint)
            switch result {
            case .success:
                logger.info("Unmounted \(mountPoint) (manually paused until remounted)")
                shareStates[shareID] = .manuallyUnmounted
            case .failure(let error):
                logger.warn("Failed to unmount \(mountPoint): \(error.localizedDescription)")
                statusBanner = "Could not unmount: \(error.localizedDescription)"
            }
            refreshMountedSnapshotOnly()
            recomputePollTimer()
        }
    }

    /// Bulk mount all enabled shares for a single server.
    public func mountAllForServer(serverID: UUID) {
        guard let server = config.servers.first(where: { $0.id == serverID }) else { return }
        for share in server.shares where share.enabled {
            manuallyUnmountedShareIDs.remove(share.id)
            failureCounts[share.id] = nil
            retryDates[share.id] = nil
        }
        let timeout = TimeInterval(config.mountTimeoutSeconds)
        Task {
            let probe = await NetworkReachability.probeSMBHost(server.host, port: 445, timeout: 1.5)
            if !probe.allIPs.isEmpty {
                hostIPCache[server.id] = probe.allIPs
            }
            let anyMounted = server.shares.contains { shareStates[$0.id]?.isMounted == true }
            if probe.isReachable {
                hostOfflineStrikes[server.id] = nil
                wakePollTasks[server.id]?.cancel()
                wakePollTasks[server.id] = nil
                hostStates[server.id] = .online(ipAddress: probe.primaryIP ?? cachedPrimaryIP(forServerID: server.id))
                syncHostOnlineStateIfNeeded(forServerID: server.id)
            } else {
                if !anyMounted {
                    hostStates[server.id] = .offline
                }
                for share in server.shares where share.enabled && shareStates[share.id]?.isMounted != true {
                    shareStates[share.id] = .hostOffline
                }
                return
            }
            await reconcileOnlineServer(serverID: serverID, forceRetry: true, timeout: timeout)
            refreshMountedSnapshotOnly()
            recomputePollTimer()
        }
    }

    /// Bulk unmount all mounted shares for a single server (pauses auto-mount for those shares until remounted).
    public func unmountAllForServer(serverID: UUID) {
        guard let server = config.servers.first(where: { $0.id == serverID }) else { return }
        let mountedShares = server.shares.compactMap { share -> (ShareConfig, String)? in
            guard let mp = shareStates[share.id]?.mountPoint else { return nil }
            return (share, mp)
        }
        guard !mountedShares.isEmpty else { return }

        for (share, _) in mountedShares {
            manuallyUnmountedShareIDs.insert(share.id)
        }

        Task {
            var failures: [String] = []
            for (share, mountPoint) in mountedShares {
                let res = await NetFSMounter.unmount(mountPoint: mountPoint)
                switch res {
                case .success:
                    shareStates[share.id] = .manuallyUnmounted
                    logger.info("Unmounted \(mountPoint) (bulk server eject)")
                case .failure(let err):
                    failures.append("\(share.name): \(err.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                statusBanner = "Some shares busy: \(failures.joined(separator: "; "))"
            }
            refreshMountedSnapshotOnly()
            recomputePollTimer()
        }
    }

    /// Sends a Wake-on-LAN magic packet to an offline PC and accelerates follow-up probes to mount as soon as it boots.
    public func wakeServer(serverID: UUID) {
        guard let server = config.servers.first(where: { $0.id == serverID }),
              let mac = server.macAddress else {
            statusBanner = "No MAC address configured for Wake-on-LAN."
            return
        }

        shutdownPollTasks[serverID]?.cancel()
        shutdownPollTasks[serverID] = nil
        hostOfflineStrikes[serverID] = nil
        hostStates[serverID] = .waking
        for share in server.shares {
            failureCounts[share.id] = nil
            retryDates[share.id] = nil
            manuallyUnmountedShareIDs.remove(share.id)
        }

        wakePollTasks[serverID]?.cancel()
        wakePollTasks[serverID] = Task { [weak self] in
            guard let self else { return }
            let result = await WakeOnLAN.wake(macAddress: mac)
            switch result {
            case .success(let count):
                self.logger.info("Sent Wake-on-LAN magic packet to \(server.host) (\(mac)) via \(count) broadcast target(s)")
            case .failure(let err):
                self.logger.warn("Wake-on-LAN failed for \(server.host): \(err.localizedDescription)")
                self.statusBanner = "Wake-on-LAN failed: \(err.localizedDescription)"
                self.hostStates[serverID] = .offline
                return
            }

            // Accelerated polling cadence while waiting for Windows to boot/wake up and bring SMB online.
            for delaySec in [10, 10, 12, 15, 15] {
                try? await Task.sleep(nanoseconds: UInt64(delaySec) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self.checkAll(forceRetry: true)
                if self.hostStates[serverID]?.isOnline == true {
                    return
                }
            }
            if self.hostStates[serverID] == .waking {
                self.hostStates[serverID] = .offline
            }
        }
    }

    /// Cleanly unmounts all shares on `serverID` and sends a remote shutdown command over SSH.
    /// Aborts if any mounted share is busy and refuses to unmount.
    public func shutdownServer(serverID: UUID) {
        guard let server = config.servers.first(where: { $0.id == serverID }),
              server.canRemoteShutdown else {
            statusBanner = "Remote shutdown is not configured for this server."
            return
        }

        wakePollTasks[serverID]?.cancel()
        wakePollTasks[serverID] = nil
        hostSyncTasks[serverID]?.cancel()
        hostSyncTasks[serverID] = nil
        hostOfflineStrikes[serverID] = nil
        shutdownPollTasks[serverID]?.cancel()

        hostStates[serverID] = .shuttingDown
        statusBanner = nil

        shutdownPollTasks[serverID] = Task { [weak self] in
            guard let self else { return }

            // 1. Cleanly unmount all mounted shares on this server first so open files aren't interrupted
            // and macOS doesn't display the "Server Disconnected" dialog.
            let mountedTargets: [(ShareConfig, String)] = server.shares.compactMap { share in
                guard let mp = self.shareStates[share.id]?.mountPoint else { return nil }
                return (share, mp)
            }

            var busyShares: [String] = []
            for (share, mountPoint) in mountedTargets {
                let unmountResult = await NetFSMounter.unmount(mountPoint: mountPoint)
                switch unmountResult {
                case .success:
                    self.shareStates[share.id] = .unmounted
                    self.logger.info("Unmounted \(mountPoint) before shutting down \(server.host)")
                case .failure(let err):
                    self.logger.warn("Aborting shutdown of \(server.host) — could not unmount \(mountPoint): \(err.localizedDescription)")
                    busyShares.append(share.name)
                }
            }

            self.refreshMountedSnapshotOnly()

            if !busyShares.isEmpty {
                self.statusBanner = "Shutdown cancelled for \(server.host): \(busyShares.joined(separator: ", ")) still in use."
                self.hostStates[serverID] = .unknown
                await self.checkAll(forceRetry: false)
                return
            }

            // 2. Send remote shutdown command via SSH.
            let sshResult = await RemotePower.shutdown(
                host: server.host,
                username: server.effectiveSSHUsername,
                keyPath: server.effectiveSSHKeyPath
            )

            switch sshResult {
            case .success:
                self.logger.info("Sent remote shutdown command to \(server.host) via SSH (\(server.effectiveSSHUsername)@\(server.host))")
            case .failure(let err):
                self.logger.warn("Remote shutdown failed for \(server.host): \(err.localizedDescription)")
                self.statusBanner = "Shutdown failed for \(server.host): \(err.localizedDescription)"
                self.hostStates[serverID] = .unknown
                await self.checkAll(forceRetry: false)
                return
            }

            // 3. Poll briefly until the PC drops off TCP :445 so the UI transitions cleanly to Offline.
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                let probe = await NetworkReachability.probeSMBHost(server.host, port: 445, timeout: 1.5)
                if !probe.isReachable {
                    self.hostStates[serverID] = .offline
                    for share in server.shares where share.enabled {
                        if self.shareStates[share.id]?.isMounted != true && !self.manuallyUnmountedShareIDs.contains(share.id) {
                            self.shareStates[share.id] = .hostOffline
                        }
                    }
                    self.recomputePollTimer()
                    return
                }
            }

            // Still reachable after 30s — refresh actual state instead of sticking in shuttingDown.
            self.hostStates[serverID] = .unknown
            await self.checkAll(forceRetry: false)
        }
    }

    public func openInFinder(mountPoint: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
    }

    public func openConfigFile() {
        if !FileManager.default.fileExists(atPath: configStore.configURL.path) {
            saveConfig()
        }
        NSWorkspace.shared.open(configStore.configURL)
    }

    public func openLogFile() {
        let url = logger.logFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            logger.info("Log file opened")
        }
        NSWorkspace.shared.open(url)
    }

    public func scanShares(forServerID serverID: UUID) async -> String {
        guard let idx = config.servers.firstIndex(where: { $0.id == serverID }) else {
            return "Server not found."
        }
        let server = config.servers[idx]
        let probe = await NetworkReachability.probeSMBHost(server.host, port: 445, timeout: 1.5)
        guard probe.isReachable else {
            return "\(server.host) is currently unreachable on port 445."
        }

        if learnMACIfMissing(serverID: serverID, ip: probe.primaryIP) {
            saveConfig()
        }

        var result = await NetFSMounter.discoverShares(host: server.host, username: server.username)
        if case .failure = result, let seedShare = server.shares.first {
            _ = await NetFSMounter.mount(
                host: server.host,
                username: server.username,
                shareName: seedShare.name,
                timeout: TimeInterval(config.mountTimeoutSeconds)
            )
            result = await NetFSMounter.discoverShares(host: server.host, username: server.username)
        }

        switch result {
        case .success(let discovered):
            guard let refreshedIdx = config.servers.firstIndex(where: { $0.id == serverID }) else {
                return "Server removed."
            }
            let existing = Set(config.servers[refreshedIdx].shares.map { $0.name.lowercased() })
            let enableNew = config.servers[refreshedIdx].autoSyncAllShares
            var addedCount = 0
            for name in discovered where !existing.contains(name.lowercased()) {
                config.servers[refreshedIdx].shares.append(ShareConfig(name: name, enabled: enableNew))
                addedCount += 1
            }
            if addedCount > 0 {
                saveConfig()
                if enableNew {
                    Task { await checkAll(forceRetry: true) }
                }
                return "Found \(discovered.count) shares; added \(addedCount) new share(s)."
            }
            return "Found \(discovered.count) shares; all already listed."

        case .failure(let error):
            return "Scan failed (mount at least one share on \(server.host) first): \(error.localizedDescription)"
        }
    }

    /// Learns and stores a server's LAN MAC address for Wake-on-LAN if it is currently missing.
    private func learnMACIfMissing(
        serverID: UUID,
        ip: String?,
        snapshot: NetworkSnapshot? = nil
    ) -> Bool {
        guard let ip,
              let idx = config.servers.firstIndex(where: { $0.id == serverID }),
              config.servers[idx].macAddress == nil else {
            return false
        }
        guard let mac = snapshot?.arpByIP[ip]?.macAddress
            ?? HomeNetworkDetector.resolveMACAddress(forIP: ip) else {
            return false
        }
        config.servers[idx].macAddress = mac
        logger.info("Learned WoL MAC for \(config.servers[idx].host) (\(ip)): \(mac)")
        return true
    }

    // MARK: - Home Network & System Preferences

    public func addCurrentHomeNetwork(customName: String? = nil) async -> String {
        let snap = await HomeNetworkDetector.captureSnapshot()
        currentNetwork = snap
        guard var fp = HomeNetworkDetector.makeFingerprint(from: snap) else {
            return "No active gateway detected on current network."
        }
        if let customName, !customName.trimmingCharacters(in: .whitespaces).isEmpty {
            fp.name = customName.trimmingCharacters(in: .whitespaces)
        }

        let alreadyExists = config.homeNetworks.contains { existing in
            existing.gatewayIP == fp.gatewayIP && existing.gatewayMAC == fp.gatewayMAC
        }
        if alreadyExists {
            return "Current network (\(fp.gatewayIP)) is already pinned."
        }

        config.homeNetworks.append(fp)
        config.version = AppConfig.currentVersion
        saveConfig()
        logger.info("Pinned home network: \(fp.name) (gateway=\(fp.gatewayIP), MAC=\(fp.gatewayMAC ?? "any"))")
        await checkAll(forceRetry: true)
        return "Pinned \(fp.name) (\(fp.gatewayMAC ?? "IP only"))."
    }

    public func removeHomeNetwork(id: UUID) {
        config.homeNetworks.removeAll { $0.id == id }
        config.version = AppConfig.currentVersion
        saveConfig()
        Task { await checkAll(forceRetry: true) }
    }

    public func setCleanupStaleMountsOnAway(_ enabled: Bool) {
        config.cleanupStaleMountsOnAway = enabled
        saveConfig()
    }

    public func setHealZombieMounts(_ enabled: Bool) {
        config.healZombieMounts = enabled
        saveConfig()
    }

    public func setNotifyOnAuthFailure(_ enabled: Bool) {
        config.notifyOnAuthFailure = enabled
        saveConfig()
    }

    public func setDontWriteNetworkDSStore(_ enabled: Bool) {
        FinderPreferences.dontWriteNetworkDSStore = enabled
        dontWriteNetworkDSStore = FinderPreferences.dontWriteNetworkDSStore
        logger.info("DSDontWriteNetworkStores set to \(dontWriteNetworkDSStore)")
    }

    public func setShowHiddenFiles(_ enabled: Bool) {
        FinderPreferences.showHiddenFiles = enabled
        showHiddenFiles = FinderPreferences.showHiddenFiles
        logger.info("AppleShowAllFiles set to \(showHiddenFiles)")
    }

    public func setShowFileExtensions(_ enabled: Bool) {
        FinderPreferences.showFileExtensions = enabled
        showFileExtensions = FinderPreferences.showFileExtensions
        logger.info("AppleShowAllExtensions set to \(showFileExtensions)")
    }

    public func refreshFinderPreferences() {
        dontWriteNetworkDSStore = FinderPreferences.dontWriteNetworkDSStore
        showHiddenFiles = FinderPreferences.showHiddenFiles
        showFileExtensions = FinderPreferences.showFileExtensions
    }

    // MARK: - App Updates

    public func checkForUpdates(manual: Bool = true) async {
        if isCheckingForUpdates { return }
        if !manual, let last = lastUpdateCheckDate, Date().timeIntervalSince(last) < 86_400 {
            return
        }

        isCheckingForUpdates = true
        if manual {
            updateCheckStatus = "Checking for updates…"
        }
        defer { isCheckingForUpdates = false }

        let outcome = await UpdateChecker.checkLatestRelease()
        lastUpdateCheckDate = Date()

        switch outcome {
        case .updateAvailable(let release):
            availableUpdate = release
            updateCheckStatus = "Update available: v\(release.version)"
            logger.info("Update available on GitHub: v\(release.version) (\(release.releaseURL.absoluteString))")
        case .upToDate(let current):
            availableUpdate = nil
            if manual {
                updateCheckStatus = "Up to date (v\(current))"
            }
        case .noReleasesPublished:
            availableUpdate = nil
            if manual {
                updateCheckStatus = "No published GitHub releases yet."
            }
        case .failed(let message):
            if manual {
                updateCheckStatus = "Update check failed: \(message)"
            }
        }
    }

    public func openAvailableUpdate() {
        guard let url = availableUpdate?.releaseURL else { return }
        NSWorkspace.shared.open(url)
    }

    public func installAvailableUpdate() {
        guard let release = availableUpdate, !updateInstallProgress.isBusy else { return }
        updateInstallProgress = .downloading("Starting update to v\(release.version)…")
        updateCheckStatus = "Downloading v\(release.version)…"

        Task { [weak self] in
            guard let self else { return }
            let result = await AppUpdater.install(release: release) { [weak self] progress in
                Task { @MainActor in
                    self?.updateInstallProgress = progress
                    if let msg = progress.message {
                        self?.updateCheckStatus = msg
                    }
                }
            }

            switch result {
            case .success(.terminateForSwap):
                self.logger.info("Staged MountKeep v\(release.version); terminating to complete swap and relaunch")
                try? await Task.sleep(nanoseconds: 250_000_000)
                NSApp.terminate(nil)
            case .success(.runningExternalInstaller):
                self.logger.info("Running source installer for MountKeep v\(release.version)")
            case .failure(let error):
                let message = error.localizedDescription
                self.logger.warn("In-app update failed: \(message)")
                self.updateInstallProgress = .failed(message)
                self.updateCheckStatus = "Install failed: \(message)"
            }
        }
    }

    public func setStorageUnitStyle(_ style: StorageUnitStyle) {
        config.storageUnitStyle = style
        saveConfig()
    }

    // MARK: - Config Editing

    public func reloadConfigFromDisk() {
        config = configStore.load()
        dontWriteNetworkDSStore = FinderPreferences.dontWriteNetworkDSStore
        refreshMountedSnapshotOnly()
        Task { await checkAll(forceRetry: true) }
    }

    public func updatePollInterval(_ seconds: Int) {
        config.pollIntervalSeconds = min(max(seconds, 10), 600)
        saveConfig()
        recomputePollTimer()
    }

    public func updateIdlePollInterval(_ seconds: Int) {
        config.idlePollIntervalSeconds = min(max(seconds, 30), 600)
        saveConfig()
        recomputePollTimer()
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAgentManager.setEnabled(enabled)
            launchAtLogin = LaunchAgentManager.isEnabled()
            logger.info("Launch at Login \(launchAtLogin ? "enabled" : "disabled")")
        } catch {
            logger.error("Failed to update Launch at Login: \(error.localizedDescription)")
            statusBanner = "Launch at Login error: \(error.localizedDescription)"
        }
    }

    public func toggleShareEnabled(serverID: UUID, shareID: UUID, enabled: Bool) {
        guard let sIdx = config.servers.firstIndex(where: { $0.id == serverID }),
              let shIdx = config.servers[sIdx].shares.firstIndex(where: { $0.id == shareID }) else {
            return
        }
        config.servers[sIdx].shares[shIdx].enabled = enabled
        saveConfig()
        if enabled {
            manuallyUnmountedShareIDs.remove(shareID)
            failureCounts[shareID] = nil
            retryDates[shareID] = nil
            Task { await checkAll(forceRetry: true) }
        } else {
            recomputePollTimer()
        }
    }

    public func setServerAutoSync(serverID: UUID, enabled: Bool) {
        guard let sIdx = config.servers.firstIndex(where: { $0.id == serverID }) else { return }
        config.servers[sIdx].autoSyncAllShares = enabled
        saveConfig()
        if enabled {
            lastAutoDiscovery[serverID] = nil
            Task { await checkAll(forceRetry: true) }
        }
    }

    public func setServerRequireHomeNetwork(serverID: UUID, enabled: Bool) {
        guard let sIdx = config.servers.firstIndex(where: { $0.id == serverID }) else { return }
        config.servers[sIdx].requireHomeNetwork = enabled
        saveConfig()
        Task { await checkAll(forceRetry: true) }
    }

    public func setServerSSHShutdown(serverID: UUID, enabled: Bool) {
        guard let sIdx = config.servers.firstIndex(where: { $0.id == serverID }) else { return }
        config.servers[sIdx].sshShutdownEnabled = enabled
        saveConfig()
        if enabled {
            sshReadiness[serverID] = .checking
            Task { await refreshSSHReadiness(forServerID: serverID) }
        } else {
            sshReadiness[serverID] = .disabled
        }
    }

    public func refreshAllSSHReadiness() {
        Task {
            var reachable: [UUID: Bool] = [:]
            for server in config.servers {
                reachable[server.id] = hostStates[server.id]?.isOnline ?? false
            }
            await refreshSSHReadiness(reachableByServer: reachable)
        }
    }

    private func refreshSSHReadiness(forServerID serverID: UUID) async {
        guard let server = config.servers.first(where: { $0.id == serverID }) else { return }
        guard server.canRemoteShutdown else {
            sshReadiness[serverID] = .disabled
            return
        }
        if !RemotePower.hasPrivateKey(at: server.effectiveSSHKeyPath) {
            sshReadiness[serverID] = .missingLocalKey
            return
        }
        if isServerAway(server) || hostStates[serverID]?.isOnline != true {
            sshReadiness[serverID] = .hostOffline
            return
        }
        let probe = await NetworkReachability.probeSMBHost(server.host, port: 22, timeout: 1.5)
        sshReadiness[serverID] = probe.isReachable ? .ready : .portClosed
    }

    private func refreshSSHReadiness(reachableByServer: [UUID: Bool]) async {
        var targetsToProbe: [(UUID, String)] = []
        for server in config.servers {
            guard server.canRemoteShutdown else {
                sshReadiness[server.id] = .disabled
                continue
            }
            if !RemotePower.hasPrivateKey(at: server.effectiveSSHKeyPath) {
                sshReadiness[server.id] = .missingLocalKey
                continue
            }
            let isOnline = reachableByServer[server.id] ?? (hostStates[server.id]?.isOnline ?? false)
            if isServerAway(server) || !isOnline {
                sshReadiness[server.id] = .hostOffline
                continue
            }
            targetsToProbe.append((server.id, server.host))
        }

        guard !targetsToProbe.isEmpty else { return }

        let results: [(UUID, Bool)] = await withTaskGroup(of: (UUID, Bool).self) { group in
            for (serverID, host) in targetsToProbe {
                group.addTask {
                    let probe = await NetworkReachability.probeSMBHost(host, port: 22, timeout: 1.5)
                    return (serverID, probe.isReachable)
                }
            }
            var collected: [(UUID, Bool)] = []
            for await item in group {
                collected.append(item)
            }
            return collected
        }

        for (serverID, portOpen) in results {
            sshReadiness[serverID] = portOpen ? .ready : .portClosed
        }
    }

    public func updateServer(
        serverID: UUID,
        host: String,
        username: String,
        macAddress: String,
        requireHomeNetwork: Bool,
        sshShutdownEnabled: Bool? = nil,
        sshUsername: String? = nil,
        sshKeyPath: String? = nil
    ) -> String? {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else { return "Hostname cannot be empty." }
        let trimmedMac = macAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMac: String?
        if trimmedMac.isEmpty {
            normalizedMac = nil
        } else if let valid = MACAddress.normalize(trimmedMac) {
            normalizedMac = valid
        } else {
            return "Invalid MAC address format (expected e.g. aa:bb:cc:dd:ee:ff)."
        }

        guard let sIdx = config.servers.firstIndex(where: { $0.id == serverID }) else {
            return "Server not found."
        }
        config.servers[sIdx].host = cleanHost
        config.servers[sIdx].username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        config.servers[sIdx].macAddress = normalizedMac
        config.servers[sIdx].requireHomeNetwork = requireHomeNetwork
        if let sshShutdownEnabled {
            config.servers[sIdx].sshShutdownEnabled = sshShutdownEnabled
        }
        if let sshUsername {
            let trimmed = sshUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            config.servers[sIdx].sshUsername = trimmed.isEmpty ? nil : trimmed
        }
        if let sshKeyPath {
            let trimmed = sshKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            config.servers[sIdx].sshKeyPath = trimmed.isEmpty ? nil : trimmed
        }
        saveConfig()
        clearBackoffs()
        Task { await checkAll(forceRetry: true) }
        return nil
    }

    public func addServer(
        host: String,
        username: String,
        autoSyncAllShares: Bool = false,
        requireHomeNetwork: Bool = true
    ) {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else { return }
        if config.servers.contains(where: {
            MountInspector.normalizeHost($0.host) == MountInspector.normalizeHost(cleanHost)
        }) {
            return
        }
        let server = ServerConfig(
            host: cleanHost,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            autoSyncAllShares: autoSyncAllShares,
            requireHomeNetwork: requireHomeNetwork,
            shares: []
        )
        config.servers.append(server)
        saveConfig()
    }

    public func removeServer(serverID: UUID) {
        wakePollTasks[serverID]?.cancel()
        wakePollTasks[serverID] = nil
        shutdownPollTasks[serverID]?.cancel()
        shutdownPollTasks[serverID] = nil
        hostSyncTasks[serverID]?.cancel()
        hostSyncTasks[serverID] = nil
        config.servers.removeAll { $0.id == serverID }
        hostStates[serverID] = nil
        hostIPCache[serverID] = nil
        hostOfflineStrikes[serverID] = nil
        lastHostSyncDate[serverID] = nil
        sshReadiness[serverID] = nil
        saveConfig()
        recomputePollTimer()
    }

    public func addShare(serverID: UUID, shareName: String, enabled: Bool = true) {
        let clean = shareName.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty,
              let sIdx = config.servers.firstIndex(where: { $0.id == serverID }) else { return }
        if config.servers[sIdx].shares.contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) {
            return
        }
        let share = ShareConfig(name: clean, enabled: enabled)
        config.servers[sIdx].shares.append(share)
        saveConfig()
        if enabled {
            Task { await checkAll(forceRetry: true) }
        }
    }

    public func removeShare(serverID: UUID, shareID: UUID) {
        guard let sIdx = config.servers.firstIndex(where: { $0.id == serverID }) else { return }
        config.servers[sIdx].shares.removeAll { $0.id == shareID }
        shareStates[shareID] = nil
        shareCapacities[shareID] = nil
        manuallyUnmountedShareIDs.remove(shareID)
        saveConfig()
        recomputePollTimer()
    }

    public func addFromSMBURL(_ rawURL: String) -> String? {
        guard let parsed = SMBURLParser.parse(rawURL) else {
            return "Invalid SMB URL. Expected format: smb://user@host/ShareName"
        }

        let normHost = MountInspector.normalizeHost(parsed.host)
        let serverIndex: Int
        if let existingIdx = config.servers.firstIndex(where: { MountInspector.normalizeHost($0.host) == normHost }) {
            serverIndex = existingIdx
            if let user = parsed.username, config.servers[existingIdx].username.isEmpty {
                config.servers[existingIdx].username = user
            }
        } else {
            let newServer = ServerConfig(
                host: parsed.host,
                username: parsed.username ?? "",
                autoSyncAllShares: false,
                requireHomeNetwork: true,
                shares: []
            )
            config.servers.append(newServer)
            serverIndex = config.servers.count - 1
        }

        if let shareName = parsed.shareName {
            let exists = config.servers[serverIndex].shares.contains {
                $0.name.caseInsensitiveCompare(shareName) == .orderedSame
            }
            if !exists {
                config.servers[serverIndex].shares.append(ShareConfig(name: shareName, enabled: true))
            }
        }

        saveConfig()
        Task { await checkAll(forceRetry: true) }
        return nil
    }

    private func saveConfig() {
        do {
            try configStore.save(config)
        } catch {
            logger.error("Failed to save config: \(error.localizedDescription)")
        }
    }

    /// Creates an in-memory demo `MountManager` populated with generic sample servers for SwiftUI previews/docs.
    public static func makePreviewDemo() -> MountManager {
        let tempConfig = FileManager.default.temporaryDirectory
            .appendingPathComponent("MountKeep-Preview-\(UUID().uuidString).json")
        let manager = MountManager(configStore: ConfigStore(configURL: tempConfig))

        let s1Share1 = ShareConfig(name: "Projects NVMe", enabled: true)
        let s1Share2 = ShareConfig(name: "Scratch SSD", enabled: true)
        let s1Share3 = ShareConfig(name: "Cold Archive", enabled: true)
        let workstation = ServerConfig(
            host: "workstation",
            username: "alex",
            autoSyncAllShares: true,
            requireHomeNetwork: true,
            macAddress: "02:aa:bb:cc:dd:01",
            shares: [s1Share1, s1Share2, s1Share3]
        )

        let s2Share1 = ShareConfig(name: "Media Vault", enabled: true)
        let s2Share2 = ShareConfig(name: "Time Machine", enabled: true)
        let s2Share3 = ShareConfig(name: "Photos", enabled: true)
        let s2Share4 = ShareConfig(name: "Backups", enabled: false)
        let nas = ServerConfig(
            host: "studio-nas",
            username: "media",
            autoSyncAllShares: false,
            requireHomeNetwork: true,
            macAddress: "02:aa:bb:cc:dd:02",
            shares: [s2Share1, s2Share2, s2Share3, s2Share4]
        )

        let homeNet = NetworkFingerprint(
            name: "Home (192.168.1.1)",
            gatewayIP: "192.168.1.1",
            gatewayMAC: "02:11:22:33:44:55"
        )

        manager.config = AppConfig(
            version: AppConfig.currentVersion,
            pollIntervalSeconds: 30,
            idlePollIntervalSeconds: 120,
            mountTimeoutSeconds: 15,
            paused: false,
            cleanupStaleMountsOnAway: true,
            healZombieMounts: true,
            notifyOnAuthFailure: true,
            storageUnitStyle: .binaryHuman,
            homeNetworks: [homeNet],
            servers: [workstation, nas]
        )
        manager.isOnHomeNetwork = true
        manager.activePollCadence = .idle(seconds: 120)
        manager.lastCheckDate = Date()
        manager.launchAtLogin = true
        manager.dontWriteNetworkDSStore = true
        manager.currentNetwork = NetworkSnapshot(
            gateways: [
                ActiveGateway(
                    ipAddress: "192.168.1.1",
                    macAddress: "02:11:22:33:44:55",
                    interfaceName: "en0",
                    isPrimary: true
                )
            ],
            arpByIP: [:]
        )

        manager.hostStates = [
            workstation.id: .online(ipAddress: "192.168.1.40"),
            nas.id: .online(ipAddress: "192.168.1.50")
        ]
        manager.shareStates = [
            s1Share1.id: .mounted(mountPoint: "/Volumes/Projects NVMe"),
            s1Share2.id: .mounted(mountPoint: "/Volumes/Scratch SSD"),
            s1Share3.id: .mounted(mountPoint: "/Volumes/Cold Archive"),
            s2Share1.id: .mounted(mountPoint: "/Volumes/Media Vault"),
            s2Share2.id: .mounted(mountPoint: "/Volumes/Time Machine"),
            s2Share3.id: .mounted(mountPoint: "/Volumes/Photos"),
            s2Share4.id: .unmounted
        ]
        let tib: UInt64 = 1024 * 1024 * 1024 * 1024
        let gib: UInt64 = 1024 * 1024 * 1024
        manager.shareCapacities = [
            s1Share1.id: VolumeCapacity(totalBytes: 3_999 * gib, availableBytes: 2_610 * gib),
            s1Share2.id: VolumeCapacity(totalBytes: 1_907 * gib, availableBytes: 1_745 * gib),
            s1Share3.id: VolumeCapacity(totalBytes: 7_452 * gib, availableBytes: 418 * gib),
            s2Share1.id: VolumeCapacity(totalBytes: 7_452 * gib, availableBytes: 1_620 * gib),
            s2Share2.id: VolumeCapacity(totalBytes: 3_726 * gib, availableBytes: 1_980 * gib),
            s2Share3.id: VolumeCapacity(totalBytes: 3_726 * gib, availableBytes: 2_890 * gib)
        ]
        _ = tib
        return manager
    }
}
