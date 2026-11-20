import Foundation

public enum MACAddress {
    /// Normalizes MAC addresses like `2:11:22:33:44:55` or `AA-BB-CC-DD-EE-FF` into `02:11:22:33:44:55`.
    /// Returns nil for invalid, incomplete, zero, or broadcast MAC addresses.
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed != "(incomplete)" else { return nil }

        let parts = trimmed.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(6)
        for part in parts {
            guard part.count >= 1, part.count <= 2, let byte = UInt8(part, radix: 16) else {
                return nil
            }
            bytes.append(byte)
        }

        // Reject all-zero or broadcast MACs
        if bytes.allSatisfy({ $0 == 0x00 }) || bytes.allSatisfy({ $0 == 0xFF }) {
            return nil
        }

        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    public static func parseBytes(_ raw: String) -> [UInt8]? {
        guard let normalized = normalize(raw) else { return nil }
        return normalized.split(separator: ":").compactMap { UInt8($0, radix: 16) }
    }
}

public struct NetworkFingerprint: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var gatewayIP: String
    public var gatewayMAC: String?

    public init(
        id: UUID = UUID(),
        name: String,
        gatewayIP: String,
        gatewayMAC: String?
    ) {
        self.id = id
        self.name = name
        self.gatewayIP = gatewayIP.trimmingCharacters(in: .whitespacesAndNewlines)
        self.gatewayMAC = gatewayMAC.flatMap(MACAddress.normalize)
    }
}

public struct ShareConfig: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.enabled = enabled
    }
}

public struct ServerConfig: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var host: String
    public var username: String
    public var autoSyncAllShares: Bool
    public var requireHomeNetwork: Bool
    public var macAddress: String?
    public var shares: [ShareConfig]

    public init(
        id: UUID = UUID(),
        host: String,
        username: String = "",
        autoSyncAllShares: Bool = false,
        requireHomeNetwork: Bool = true,
        macAddress: String? = nil,
        shares: [ShareConfig] = []
    ) {
        self.id = id
        self.host = host
        self.username = username
        self.autoSyncAllShares = autoSyncAllShares
        self.requireHomeNetwork = requireHomeNetwork
        self.macAddress = macAddress.flatMap(MACAddress.normalize)
        self.shares = shares
    }

    enum CodingKeys: String, CodingKey {
        case id, host, username, autoSyncAllShares, requireHomeNetwork, macAddress, shares
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.host = try container.decode(String.self, forKey: .host)
        self.username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        self.autoSyncAllShares = try container.decodeIfPresent(Bool.self, forKey: .autoSyncAllShares) ?? false
        self.requireHomeNetwork = try container.decodeIfPresent(Bool.self, forKey: .requireHomeNetwork) ?? true
        let rawMac = try container.decodeIfPresent(String.self, forKey: .macAddress)
        self.macAddress = rawMac.flatMap(MACAddress.normalize)
        self.shares = try container.decodeIfPresent([ShareConfig].self, forKey: .shares) ?? []
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var pollIntervalSeconds: Int
    public var idlePollIntervalSeconds: Int
    public var mountTimeoutSeconds: Int
    public var paused: Bool
    public var cleanupStaleMountsOnAway: Bool
    public var healZombieMounts: Bool
    public var notifyOnAuthFailure: Bool
    public var storageUnitStyle: StorageUnitStyle
    public var homeNetworks: [NetworkFingerprint]
    public var servers: [ServerConfig]

    public init(
        version: Int = AppConfig.currentVersion,
        pollIntervalSeconds: Int = 30,
        idlePollIntervalSeconds: Int = 120,
        mountTimeoutSeconds: Int = 15,
        paused: Bool = false,
        cleanupStaleMountsOnAway: Bool = true,
        healZombieMounts: Bool = true,
        notifyOnAuthFailure: Bool = true,
        storageUnitStyle: StorageUnitStyle = .binaryHuman,
        homeNetworks: [NetworkFingerprint] = [],
        servers: [ServerConfig]
    ) {
        self.version = version
        self.pollIntervalSeconds = min(max(pollIntervalSeconds, 10), 600)
        self.idlePollIntervalSeconds = min(max(idlePollIntervalSeconds, 30), 600)
        self.mountTimeoutSeconds = min(max(mountTimeoutSeconds, 5), 60)
        self.paused = paused
        self.cleanupStaleMountsOnAway = cleanupStaleMountsOnAway
        self.healZombieMounts = healZombieMounts
        self.notifyOnAuthFailure = notifyOnAuthFailure
        self.storageUnitStyle = storageUnitStyle
        self.homeNetworks = homeNetworks
        self.servers = servers
    }

    enum CodingKeys: String, CodingKey {
        case version
        case pollIntervalSeconds
        case idlePollIntervalSeconds
        case mountTimeoutSeconds
        case paused
        case cleanupStaleMountsOnAway
        case healZombieMounts
        case notifyOnAuthFailure
        case storageUnitStyle
        case homeNetworks
        case servers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ver = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let poll = try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 30
        let idle = try container.decodeIfPresent(Int.self, forKey: .idlePollIntervalSeconds) ?? 120
        let timeout = try container.decodeIfPresent(Int.self, forKey: .mountTimeoutSeconds) ?? 15
        let paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        let cleanup = try container.decodeIfPresent(Bool.self, forKey: .cleanupStaleMountsOnAway) ?? true
        let heal = try container.decodeIfPresent(Bool.self, forKey: .healZombieMounts) ?? true
        let notify = try container.decodeIfPresent(Bool.self, forKey: .notifyOnAuthFailure) ?? true
        let unitStyle = try container.decodeIfPresent(StorageUnitStyle.self, forKey: .storageUnitStyle) ?? .binaryHuman
        let homeNets = try container.decodeIfPresent([NetworkFingerprint].self, forKey: .homeNetworks) ?? []
        let servers = try container.decodeIfPresent([ServerConfig].self, forKey: .servers) ?? []

        self.init(
            version: ver,
            pollIntervalSeconds: poll,
            idlePollIntervalSeconds: idle,
            mountTimeoutSeconds: timeout,
            paused: paused,
            cleanupStaleMountsOnAway: cleanup,
            healZombieMounts: heal,
            notifyOnAuthFailure: notify,
            storageUnitStyle: unitStyle,
            homeNetworks: homeNets,
            servers: servers
        )
    }

    /// Clean initial configuration for first launch (add servers via Manage Shares or config.json).
    public static func defaultConfig() -> AppConfig {
        AppConfig(
            version: AppConfig.currentVersion,
            pollIntervalSeconds: 30,
            idlePollIntervalSeconds: 120,
            mountTimeoutSeconds: 15,
            paused: false,
            cleanupStaleMountsOnAway: true,
            healZombieMounts: true,
            notifyOnAuthFailure: true,
            storageUnitStyle: .binaryHuman,
            homeNetworks: [],
            servers: []
        )
    }
}

public enum HostReachabilityState: Equatable, Sendable {
    case unknown
    case checking
    case online(ipAddress: String?)
    case offline
    case awayFromHome
    case waking

    public var isOnline: Bool {
        if case .online = self { return true }
        return false
    }
}

public enum ShareRuntimeState: Equatable, Sendable {
    case unknown
    case mounted(mountPoint: String)
    case mounting
    case healing
    case unmounted
    case manuallyUnmounted
    case hostOffline
    case awayFromHome
    case failed(message: String, retryAt: Date?, isAuthError: Bool = false)

    public var isMounted: Bool {
        if case .mounted = self { return true }
        return false
    }

    public var mountPoint: String? {
        if case .mounted(let path) = self { return path }
        return nil
    }
}

public enum BackoffPolicy {
    /// Computes exponential retry backoff: 30s, 60s, 180s, 300s (capped).
    public static func delaySeconds(forFailureCount count: Int) -> TimeInterval {
        switch count {
        case ...0: return 0
        case 1: return 30
        case 2: return 60
        case 3: return 180
        default: return 300
        }
    }
}

public struct ParsedSMBAddress: Equatable, Sendable {
    public let host: String
    public let username: String?
    public let shareName: String?

    public init(host: String, username: String?, shareName: String?) {
        self.host = host
        self.username = username
        self.shareName = shareName
    }
}

public enum SMBURLParser {
    /// Parses `smb://[user@]host[/share]` or `//[user@]host[/share]` into components.
    /// Any embedded password component is deliberately ignored and never stored.
    public static func parse(_ raw: String) -> ParsedSMBAddress? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var normalized = trimmed
        if normalized.hasPrefix("//") {
            normalized = "smb:" + normalized
        } else if !normalized.contains("://") {
            normalized = "smb://" + normalized
        }

        let safeForParsing = normalized.replacingOccurrences(of: " ", with: "%20")
        guard let components = URLComponents(string: safeForParsing),
              let scheme = components.scheme?.lowercased(),
              scheme == "smb" || scheme == "cifs",
              let host = components.host, !host.isEmpty else {
            return nil
        }

        let user = components.user?.isEmpty == true ? nil : components.user
        let rawPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let firstSegment = rawPath.split(separator: "/", maxSplits: 1).first.map(String.init)
        let share = (firstSegment?.isEmpty == false) ? firstSegment : nil

        return ParsedSMBAddress(host: host, username: user, shareName: share)
    }
}

public final class ConfigStore: @unchecked Sendable {
    public let configURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(configURL: URL? = nil) {
        if let customURL = configURL {
            self.configURL = customURL
        } else {
            let appSupport = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/MountKeep", isDirectory: true)
            self.configURL = appSupport.appendingPathComponent("config.json")
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc
        self.decoder = JSONDecoder()
    }

    public func load() -> AppConfig {
        let fm = FileManager.default
        if fm.fileExists(atPath: configURL.path),
           let data = try? Data(contentsOf: configURL),
           var loaded = try? decoder.decode(AppConfig.self, from: data) {
            loaded.pollIntervalSeconds = min(max(loaded.pollIntervalSeconds, 10), 600)
            loaded.idlePollIntervalSeconds = min(max(loaded.idlePollIntervalSeconds, 30), 600)
            loaded.mountTimeoutSeconds = min(max(loaded.mountTimeoutSeconds, 5), 60)
            return loaded
        }

        let defaults = AppConfig.defaultConfig()
        try? save(defaults)
        return defaults
    }

    public func save(_ config: AppConfig) throws {
        let fm = FileManager.default
        let dir = configURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var sanitized = config
        sanitized.pollIntervalSeconds = min(max(config.pollIntervalSeconds, 10), 600)
        sanitized.idlePollIntervalSeconds = min(max(config.idlePollIntervalSeconds, 30), 600)
        sanitized.mountTimeoutSeconds = min(max(config.mountTimeoutSeconds, 5), 60)
        let data = try encoder.encode(sanitized)
        try data.write(to: configURL, options: .atomic)
    }
}
