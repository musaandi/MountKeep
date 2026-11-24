import Foundation
import SystemConfiguration

public struct ARPEntry: Equatable, Sendable {
    public let ipAddress: String
    public let macAddress: String
    public let interfaceName: String

    public init(ipAddress: String, macAddress: String, interfaceName: String) {
        self.ipAddress = ipAddress
        self.macAddress = macAddress
        self.interfaceName = interfaceName
    }
}

public struct ActiveGateway: Equatable, Sendable {
    public let ipAddress: String
    public let macAddress: String?
    public let interfaceName: String?
    public let isPrimary: Bool

    public init(ipAddress: String, macAddress: String?, interfaceName: String?, isPrimary: Bool) {
        self.ipAddress = ipAddress
        self.macAddress = macAddress
        self.interfaceName = interfaceName
        self.isPrimary = isPrimary
    }
}

public struct NetworkSnapshot: Equatable, Sendable {
    public let gateways: [ActiveGateway]
    public let arpByIP: [String: ARPEntry]

    public init(gateways: [ActiveGateway], arpByIP: [String: ARPEntry]) {
        self.gateways = gateways
        self.arpByIP = arpByIP
    }

    public var primaryGateway: ActiveGateway? {
        gateways.first(where: \.isPrimary) ?? gateways.first
    }

    public var hasAnyNetwork: Bool {
        !gateways.isEmpty
    }
}

public enum ARPParser {
    /// Parses `/usr/sbin/arp -an` output into normalized IP -> ARPEntry map.
    /// Example line: `? (192.168.1.1) at 2:11:22:33:44:55 on en0 ifscope [ethernet]`
    public static func parse(_ output: String) -> [String: ARPEntry] {
        let pattern = try? NSRegularExpression(
            pattern: #"\(([\d\.]+)\)\s+at\s+([0-9a-fA-F:]+)\s+on\s+([^\s]+)"#,
            options: []
        )
        var entries: [String: ARPEntry] = [:]

        for line in output.components(separatedBy: .newlines) {
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            guard let match = pattern?.firstMatch(in: line, range: range),
                  match.numberOfRanges >= 4 else {
                continue
            }

            let ip = nsLine.substring(with: match.range(at: 1))
            let rawMAC = nsLine.substring(with: match.range(at: 2))
            let iface = nsLine.substring(with: match.range(at: 3))

            guard let normalizedMAC = MACAddress.normalize(rawMAC) else { continue }
            entries[ip] = ARPEntry(ipAddress: ip, macAddress: normalizedMAC, interfaceName: iface)
        }
        return entries
    }

    /// Extracts `IPv4.RouterHardwareAddress=<mac>` from a macOS `SCDynamicStore` `NetworkSignature` string.
    public static func parseRouterMAC(fromNetworkSignature signature: String) -> String? {
        for part in signature.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            if kv[0].trimmingCharacters(in: .whitespaces) == "IPv4.RouterHardwareAddress" {
                return MACAddress.normalize(String(kv[1]))
            }
        }
        return nil
    }
}

public enum HomeNetworkDetector {
    private static let queue = DispatchQueue(label: "com.mountkeep.homenet", qos: .utility)

    /// Captures all active IPv4 service gateways + router hardware MAC addresses natively via `SCDynamicStore`.
    /// Requires zero Location Services permissions, spawns no subprocesses, and works over Wi-Fi, Ethernet, and active VPNs.
    public static func captureSnapshot() async -> NetworkSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                let snapshot = captureSnapshotSync()
                continuation.resume(returning: snapshot)
            }
        }
    }

    public static func captureSnapshotSync() -> NetworkSnapshot {
        guard let store = SCDynamicStoreCreate(nil, "com.mountkeep.homenet" as CFString, nil, nil) else {
            return NetworkSnapshot(gateways: [], arpByIP: [:])
        }

        let globalDict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let primaryServiceID = globalDict?["PrimaryService"] as? String
        let globalRouter = globalDict?["Router"] as? String
        let globalInterface = globalDict?["PrimaryInterface"] as? String

        var gateways: [ActiveGateway] = []
        var arpByIP: [String: ARPEntry] = [:]
        var seenIPs = Set<String>()

        // Read every active IPv4 service first because per-service dicts carry `ARPResolvedHardwareAddress`
        // and `NetworkSignature` directly from macOS's IPMonitor/configd.
        if let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv4" as CFString) as? [String] {
            // Evaluate PrimaryService first so it takes precedence.
            let sortedKeys = keys.sorted { lhs, rhs in
                let lhsPrimary = primaryServiceID.map { lhs.contains($0) } ?? false
                let rhsPrimary = primaryServiceID.map { rhs.contains($0) } ?? false
                if lhsPrimary != rhsPrimary { return lhsPrimary }
                return lhs < rhs
            }

            for key in sortedKeys {
                guard let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                      let router = dict["Router"] as? String, !router.isEmpty else {
                    continue
                }

                let iface = (dict["InterfaceName"] as? String) ?? (dict["ConfirmedInterfaceName"] as? String)
                let isPrimary = primaryServiceID.map { key.contains($0) }
                    ?? (router == globalRouter && (globalInterface == nil || iface == globalInterface))

                let resolvedMAC: String? = {
                    if let raw = dict["ARPResolvedHardwareAddress"] as? String,
                       let norm = MACAddress.normalize(raw) {
                        return norm
                    }
                    if let sig = dict["NetworkSignature"] as? String,
                       let norm = ARPParser.parseRouterMAC(fromNetworkSignature: sig) {
                        return norm
                    }
                    return nil
                }()

                if let mac = resolvedMAC {
                    arpByIP[router] = ARPEntry(ipAddress: router, macAddress: mac, interfaceName: iface ?? "")
                }

                if seenIPs.insert(router).inserted {
                    gateways.append(
                        ActiveGateway(
                            ipAddress: router,
                            macAddress: resolvedMAC,
                            interfaceName: iface,
                            isPrimary: isPrimary
                        )
                    )
                }
            }
        }

        // Fallback if Global/IPv4 has a router not listed under any Service key.
        if let router = globalRouter, !router.isEmpty, seenIPs.insert(router).inserted {
            gateways.insert(
                ActiveGateway(
                    ipAddress: router,
                    macAddress: arpByIP[router]?.macAddress,
                    interfaceName: globalInterface,
                    isPrimary: true
                ),
                at: 0
            )
        }

        return NetworkSnapshot(gateways: gateways, arpByIP: arpByIP)
    }

    /// Evaluates whether the current network snapshot matches any configured home network fingerprint.
    /// If `allowedNetworks` is empty, returns `true` (unrestricted).
    public static func matches(
        snapshot: NetworkSnapshot,
        allowedNetworks: [NetworkFingerprint]
    ) -> Bool {
        guard !allowedNetworks.isEmpty else { return true }
        guard !snapshot.gateways.isEmpty else { return false }

        for allowed in allowedNetworks {
            for gw in snapshot.gateways {
                guard gw.ipAddress == allowed.gatewayIP else { continue }
                if let expectedMAC = allowed.gatewayMAC {
                    if gw.macAddress == expectedMAC {
                        return true
                    }
                } else {
                    return true
                }
            }
        }
        return false
    }

    /// Builds a `NetworkFingerprint` from the best active physical gateway in `snapshot`.
    public static func makeFingerprint(from snapshot: NetworkSnapshot) -> NetworkFingerprint? {
        guard let gw = snapshot.gateways.first(where: { $0.isPrimary && $0.macAddress != nil })
            ?? snapshot.gateways.first(where: { $0.macAddress != nil })
            ?? snapshot.primaryGateway else {
            return nil
        }
        return NetworkFingerprint(
            name: "Home (\(gw.ipAddress))",
            gatewayIP: gw.ipAddress,
            gatewayMAC: gw.macAddress
        )
    }

    /// Resolves the LAN MAC address for a specific IPv4 host via `/usr/sbin/arp -n <ip>`.
    /// Only invoked on-demand when a server is online and lacks a saved Wake-on-LAN MAC.
    public static func resolveMACAddress(forIP ip: String) -> String? {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-n", trimmed]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else {
                return nil
            }
            return ARPParser.parse(output)[trimmed]?.macAddress
        } catch {
            return nil
        }
    }
}
