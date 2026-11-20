import Foundation
import AppKit
import MountKeepCore

let args = CommandLine.arguments.dropFirst()

if args.contains("--help") || args.contains("-h") {
    print("""
    MountKeep — macOS Network Drive Auto-Mounter

    Usage:
      MountKeep              Launch the menu bar app
      MountKeep --status     Print current network, storage, reachability & mount status
      MountKeep --mount-now  Perform one immediate mount pass for eligible enabled shares
      MountKeep --help       Show this help
    """)
    exit(0)
}

if args.contains("--unregister-login-item") {
    try? LaunchAgentManager.setEnabled(false)
    exit(0)
}

if args.contains("--status") || args.contains("--mount-now") {
    let doMount = args.contains("--mount-now")
    let semaphore = DispatchSemaphore(value: 0)

    Task {
        let store = ConfigStore()
        let config = store.load()
        let style = config.storageUnitStyle
        let snapshot = await HomeNetworkDetector.captureSnapshot()
        let onHome = HomeNetworkDetector.matches(snapshot: snapshot, allowedNetworks: config.homeNetworks)
        let mountedBefore = MountInspector.mountedSMBShares()

        if let gw = snapshot.primaryGateway {
            let mac = gw.macAddress ?? "unknown"
            let homeLabel = config.homeNetworks.isEmpty ? "unrestricted" : (onHome ? "HOME" : "AWAY")
            print("Network: \(gw.ipAddress) (\(mac)) [\(homeLabel)]")
        } else {
            print("Network: offline")
        }

        var allMountedCapacities: [VolumeCapacity] = []
        var serverOutputBlocks: [String] = []

        for server in config.servers {
            let away = server.requireHomeNetwork && !config.homeNetworks.isEmpty && !onHome
            if away {
                serverOutputBlocks.append("[\(server.host)] AWAY (home-only, dormant)")
                continue
            }

            let probe = await NetworkReachability.probeSMBHost(server.host, port: 445, timeout: 1.5)
            let hostTag = probe.isReachable
                ? "ONLINE (\(probe.primaryIP ?? server.host))"
                : "OFFLINE"
            let macTag = server.macAddress.map { " wol=\($0)" } ?? ""

            var lines: [String] = []
            var serverCaps: [VolumeCapacity] = []

            for share in server.shares {
                if !share.enabled {
                    lines.append("  - [disabled] \(share.name)")
                    continue
                }

                if let existing = mountedBefore.first(where: {
                    MountInspector.matches(
                        mounted: $0,
                        configuredHost: server.host,
                        configuredHostIPs: probe.allIPs,
                        configuredShareName: share.name
                    )
                }) {
                    let freshCap = await MountInspector.fetchFreshCapacity(forMountPoint: existing.mountPoint, timeout: 2.0)
                        ?? existing.capacity
                    if let cap = freshCap {
                        serverCaps.append(cap)
                        allMountedCapacities.append(cap)
                        lines.append(
                            "  ✓ [mounted]  \(share.name) -> \(cap.formattedUsedOfTotal(style: style)) (\(cap.usedPercentText), \(cap.formattedFree(style: style)))"
                        )
                    } else {
                        lines.append("  ✓ [mounted]  \(share.name) -> \(existing.mountPoint)")
                    }
                    continue
                }

                if doMount && probe.isReachable {
                    let outcome = await NetFSMounter.mount(
                        host: server.host,
                        username: server.username,
                        shareName: share.name,
                        timeout: TimeInterval(config.mountTimeoutSeconds)
                    )
                    switch outcome {
                    case .mounted(let path):
                        if let cap = await MountInspector.fetchFreshCapacity(forMountPoint: path, timeout: 2.0) {
                            serverCaps.append(cap)
                            allMountedCapacities.append(cap)
                            lines.append(
                                "  ✓ [mounted]  \(share.name) -> \(cap.formattedUsedOfTotal(style: style)) (\(cap.usedPercentText), \(cap.formattedFree(style: style)))"
                            )
                        } else {
                            lines.append("  ✓ [mounted]  \(share.name) -> \(path)")
                        }
                    case .failed(_, let msg, _):
                        lines.append("  ✗ [failed]   \(share.name) -> \(msg)")
                    }
                } else {
                    let state = probe.isReachable ? "unmounted" : "host offline"
                    lines.append("  ○ [\(state)] \(share.name)")
                }
            }

            let serverCapSuffix: String
            if let sCap = VolumeCapacity.combine(serverCaps) {
                serverCapSuffix = "  [\(sCap.formattedUsedOfTotal(style: style)) • \(sCap.usedPercentText)]"
            } else {
                serverCapSuffix = ""
            }
            let header = "[\(server.host)] \(hostTag)\(server.username.isEmpty ? "" : " user=\(server.username)")\(macTag)\(serverCapSuffix)"
            serverOutputBlocks.append(([header] + lines).joined(separator: "\n"))
        }

        if let overall = VolumeCapacity.combine(allMountedCapacities) {
            let n = allMountedCapacities.count
            print(
                "Storage: \(overall.formattedUsedOfTotal(style: style)) (\(overall.usedPercentText) used, \(overall.formattedFree(style: style)) across \(n) mounted \(n == 1 ? "drive" : "drives"))"
            )
        }
        for block in serverOutputBlocks {
            print(block)
        }

        semaphore.signal()
    }

    semaphore.wait()
    exit(0)
}

// Single-instance guard for GUI mode
let currentPID = ProcessInfo.processInfo.processIdentifier
if let bundleID = Bundle.main.bundleIdentifier {
    let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != currentPID }
    if !existing.isEmpty {
        exit(0)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = MountKeepAppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
