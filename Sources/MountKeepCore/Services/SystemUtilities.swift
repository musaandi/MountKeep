import Foundation
import AppKit
import Darwin
import notify
@preconcurrency import UserNotifications

// MARK: - Wake-on-LAN

public enum WakeOnLAN {
    private static let queue = DispatchQueue(label: "com.mountkeep.wol", qos: .utility)

    /// Builds a standard 102-byte Wake-on-LAN magic packet (6x 0xFF + 16x MAC).
    public static func magicPacket(for macAddress: String) -> Data? {
        guard let macBytes = MACAddress.parseBytes(macAddress), macBytes.count == 6 else {
            return nil
        }
        var bytes = [UInt8](repeating: 0xFF, count: 6)
        bytes.reserveCapacity(102)
        for _ in 0..<16 {
            bytes.append(contentsOf: macBytes)
        }
        return Data(bytes)
    }

    /// Sends a Wake-on-LAN UDP magic packet to all active LAN subnet broadcast addresses (plus 255.255.255.255).
    public static func wake(macAddress: String, port: UInt16 = 9) async -> Result<Int, Error> {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let packet = magicPacket(for: macAddress) else {
                    let err = NSError(
                        domain: "MountKeep.WoL",
                        code: Int(EINVAL),
                        userInfo: [NSLocalizedDescriptionKey: "Invalid MAC address: \(macAddress)"]
                    )
                    continuation.resume(returning: .failure(err))
                    return
                }

                let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard fd >= 0 else {
                    let err = NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(errno),
                        userInfo: [NSLocalizedDescriptionKey: "Failed to open UDP socket"]
                    )
                    continuation.resume(returning: .failure(err))
                    return
                }
                defer { Darwin.close(fd) }

                var broadcastEnable: Int32 = 1
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_BROADCAST,
                    &broadcastEnable,
                    socklen_t(MemoryLayout<Int32>.size)
                )

                var targets = activeIPv4BroadcastAddresses()
                if !targets.contains("255.255.255.255") {
                    targets.append("255.255.255.255")
                }

                var sentCount = 0
                var lastErr: Int32 = 0

                packet.withUnsafeBytes { rawBuf in
                    guard let baseAddr = rawBuf.baseAddress else { return }
                    for targetIP in targets {
                        var addr = sockaddr_in()
                        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                        addr.sin_family = sa_family_t(AF_INET)
                        addr.sin_port = port.bigEndian
                        guard inet_pton(AF_INET, targetIP, &addr.sin_addr) == 1 else { continue }

                        let sent = withUnsafePointer(to: &addr) { ptr in
                            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                                Darwin.sendto(
                                    fd,
                                    baseAddr,
                                    rawBuf.count,
                                    0,
                                    saPtr,
                                    socklen_t(MemoryLayout<sockaddr_in>.size)
                                )
                            }
                        }
                        if sent == rawBuf.count {
                            sentCount += 1
                        } else {
                            lastErr = errno
                        }
                    }
                }

                if sentCount > 0 {
                    continuation.resume(returning: .success(sentCount))
                } else {
                    let msg = lastErr != 0 ? String(cString: strerror(lastErr)) : "Could not send WoL packet"
                    let err = NSError(
                        domain: "MountKeep.WoL",
                        code: Int(lastErr),
                        userInfo: [NSLocalizedDescriptionKey: msg]
                    )
                    continuation.resume(returning: .failure(err))
                }
            }
        }
    }

    private static func activeIPv4BroadcastAddresses() -> [String] {
        var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrsPtr) == 0, let first = ifaddrsPtr else { return [] }
        defer { freeifaddrs(first) }

        var results: [String] = []
        var seen = Set<String>()
        var current: UnsafeMutablePointer<ifaddrs>? = first

        while let ptr = current {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let hasBroadcast = (flags & IFF_BROADCAST) != 0

            if isUp && !isLoopback && hasBroadcast,
               let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               let dst = ifa.ifa_dstaddr, dst.pointee.sa_family == UInt8(AF_INET) {
                var sin = dst.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &sin, &buf, socklen_t(buf.count)) != nil {
                    let ip = String(cString: buf)
                    if ip != "0.0.0.0" && seen.insert(ip).inserted {
                        results.append(ip)
                    }
                }
            }
            current = ifa.ifa_next
        }
        return results
    }
}

// MARK: - Actionable Auth-Failure Notifier

@MainActor
public final class AuthNotifier {
    private var lastNotifiedByServer: [UUID: Date] = [:]
    private let throttleInterval: TimeInterval = 1800 // 30 minutes
    private let logger: MountLogger

    public init(logger: MountLogger = .shared) {
        self.logger = logger
    }

    private var canUseUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    public func clearThrottle(forServerID serverID: UUID) {
        lastNotifiedByServer[serverID] = nil
    }

    public func notifyAuthFailure(serverID: UUID, host: String, username: String, shareName: String) {
        guard canUseUserNotifications else { return }

        let now = Date()
        if let last = lastNotifiedByServer[serverID], now.timeIntervalSince(last) < throttleInterval {
            return
        }
        lastNotifiedByServer[serverID] = now

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [logger] granted, error in
            if let error {
                logger.warn("Notification permission error: \(error.localizedDescription)")
                return
            }
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "MountKeep: Authentication Failed"
            let account = username.isEmpty ? host : "\(username)@\(host)"
            content.body = "Could not sign in to \(account) for \"\(shareName)\". Update your saved password in Finder (⌘K) or Keychain Access."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "com.mountkeep.auth.\(serverID.uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request) { addError in
                if let addError {
                    logger.warn("Failed to deliver auth notification: \(addError.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Finder Preferences

public enum FinderPreferences {
    private static let desktopServicesDomain = "com.apple.desktopservices" as CFString
    private static let dsStoreKey = "DSDontWriteNetworkStores" as CFString

    private static let finderDomain = "com.apple.finder" as CFString
    private static let showAllFilesKey = "AppleShowAllFiles" as CFString

    private static let showAllExtensionsKey = "AppleShowAllExtensions" as CFString
    public static let showAllExtensionsChangedNotification = Notification.Name(
        "com.apple.LaunchServices.ShowAllExtensionsChanged"
    )

    private static let finderQueue = DispatchQueue(label: "com.mountkeep.finder-prefs", qos: .userInitiated)
    private static var pendingRestartWorkItem: DispatchWorkItem?

    public static var dontWriteNetworkDSStore: Bool {
        get { readAppBool(key: dsStoreKey, domain: desktopServicesDomain) }
        set { writeAppBool(newValue, key: dsStoreKey, domain: desktopServicesDomain) }
    }

    public static var showHiddenFiles: Bool {
        get { readAppBool(key: showAllFilesKey, domain: finderDomain) }
        set {
            // Write to both com.apple.finder (Finder windows) and NSGlobalDomain (Open/Save dialogs).
            writeAppBool(newValue, key: showAllFilesKey, domain: finderDomain)
            writeGlobalBool(newValue, key: showAllFilesKey)
            scheduleFinderRestart()
        }
    }

    private static let launchServicesHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/CoreServices.framework/CoreServices",
        RTLD_LAZY
    )

    private static let lsGetShowAllExtensions: (@convention(c) () -> Bool)? = {
        guard let handle = launchServicesHandle,
              let sym = dlsym(handle, "_LSGetShowAllExtensionsPreference") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) () -> Bool).self)
    }()

    private static let lsSetShowAllExtensions: (@convention(c) (Bool) -> Void)? = {
        guard let handle = launchServicesHandle,
              let sym = dlsym(handle, "_LSSetShowAllExtensionsPreference") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (Bool) -> Void).self)
    }()

    public static var showFileExtensions: Bool {
        get {
            if let getter = lsGetShowAllExtensions {
                return getter()
            }
            return readGlobalBool(key: showAllExtensionsKey)
        }
        set {
            // Clear any stray per-app override in com.apple.finder so LaunchServices/NSGlobalDomain is authoritative.
            CFPreferencesSetValue(
                showAllExtensionsKey,
                nil,
                finderDomain,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
            CFPreferencesSynchronize(
                finderDomain,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )

            if let setter = lsSetShowAllExtensions {
                // Uses the exact LaunchServices API that Finder Settings uses — updates lsd, Finder,
                // Spotlight, and running apps live without needing killall Finder.
                setter(newValue)
            } else {
                writeGlobalBool(newValue, key: showAllExtensionsKey)
                notify_post(showAllExtensionsChangedNotification.rawValue)
                DistributedNotificationCenter.default().postNotificationName(
                    showAllExtensionsChangedNotification,
                    object: nil,
                    userInfo: nil,
                    options: [.deliverImmediately]
                )
                scheduleFinderRestart(includeSpotlight: true)
            }
        }
    }

    private static func readAppBool(key: CFString, domain: CFString) -> Bool {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let raw = CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return parseBool(raw)
    }

    private static func readGlobalBool(key: CFString) -> Bool {
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let raw = CFPreferencesCopyValue(
            key,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return parseBool(raw)
    }

    private static func writeAppBool(_ value: Bool, key: CFString, domain: CFString) {
        CFPreferencesSetValue(
            key,
            value ? kCFBooleanTrue : kCFBooleanFalse,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func writeGlobalBool(_ value: Bool, key: CFString) {
        CFPreferencesSetValue(
            key,
            value ? kCFBooleanTrue : kCFBooleanFalse,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }

    private static func parseBool(_ raw: CFPropertyList?) -> Bool {
        if let value = raw as? Bool {
            return value
        }
        if let num = raw as? NSNumber {
            return num.boolValue
        }
        if let str = raw as? String {
            return ["true", "yes", "1"].contains(str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return false
    }

    /// Debounces and serializes Finder (and optionally Spotlight) restarts so rapid toggles never overlap or race with cfprefsd.
    private static func scheduleFinderRestart(includeSpotlight: Bool = false) {
        finderQueue.async {
            pendingRestartWorkItem?.cancel()
            let item = DispatchWorkItem {
                restartFinderSync(includeSpotlight: includeSpotlight)
            }
            pendingRestartWorkItem = item
            finderQueue.asyncAfter(deadline: .now() + 0.15, execute: item)
        }
    }

    private static func restartFinderSync(includeSpotlight: Bool) {
        if includeSpotlight {
            for spotlight in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Spotlight") {
                _ = Darwin.kill(spotlight.processIdentifier, SIGTERM)
            }
        }

        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
        let oldPIDs = Set(existing.map(\.processIdentifier))

        if existing.isEmpty {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = ["Finder"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            return
        }

        for app in existing {
            _ = Darwin.kill(app.processIdentifier, SIGTERM)
        }

        // Wait up to 2s for the previous Finder instance(s) to exit cleanly.
        let exitDeadline = Date().addingTimeInterval(2.0)
        while Date() < exitDeadline {
            if existing.allSatisfy(\.isTerminated) {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        // Wait briefly for launchd to respawn a fresh Finder instance before allowing another restart.
        let respawnDeadline = Date().addingTimeInterval(1.5)
        while Date() < respawnDeadline {
            let current = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
            if current.contains(where: { !oldPIDs.contains($0.processIdentifier) && !$0.isTerminated }) {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
