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

// MARK: - Per-User SMB Client Stability Tuning (~/Library/Preferences/nsmb.conf)

public enum SMBClientConfig {
    private static let managedHeader = "# Managed by MountKeep (SMB Wi-Fi stability)"

    public static var userConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/nsmb.conf")
    }

    public static func isWiFiStabilityEnabled(at url: URL = userConfigURL) -> Bool {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return isWiFiStabilityEnabled(in: content)
    }

    public static func setWiFiStabilityEnabled(_ enabled: Bool, at url: URL = userConfigURL) throws {
        let existing = try? String(contentsOf: url, encoding: .utf8)
        let updated = applyWiFiStability(enabled: enabled, to: existing)
        if let updated {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Parses `[default]` in an `nsmb.conf` string and returns true when `mc_on=no` and `max_resp_timeout >= 60`.
    public static func isWiFiStabilityEnabled(in content: String) -> Bool {
        var inDefault = false
        var mcOff = false
        var respTimeoutOK = false

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let section = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
                inDefault = (section == "default")
                continue
            }
            guard inDefault, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "mc_on" {
                mcOff = (val == "no" || val == "0" || val == "false")
            } else if key == "max_resp_timeout" {
                let digits = val.hasSuffix("s") ? String(val.dropLast()) : val
                if let secs = Int(digits), secs >= 60 {
                    respTimeoutOK = true
                }
            }
        }
        return mcOff && respTimeoutOK
    }

    /// Applies or removes MountKeep's Wi-Fi SMB stability keys (`mc_on=no`, `max_resp_timeout=60`) inside `[default]`,
    /// preserving all other user sections and keys intact. Returns `nil` when disabling leaves the file empty.
    public static func applyWiFiStability(enabled: Bool, to existingContent: String?) -> String? {
        let trimmedExisting = (existingContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if enabled {
            if trimmedExisting.isEmpty {
                return "\(managedHeader)\n[default]\nmc_on=no\nmax_resp_timeout=60\n"
            }

            let lines = (existingContent ?? "").components(separatedBy: .newlines)
            var out: [String] = []
            var inDefault = false
            var foundDefault = false
            var wroteMC = false
            var wroteTimeout = false

            func flushMissingDefaultKeys() {
                if !wroteMC {
                    out.append("mc_on=no")
                    wroteMC = true
                }
                if !wroteTimeout {
                    out.append("max_resp_timeout=60")
                    wroteTimeout = true
                }
            }

            for rawLine in lines {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    if inDefault {
                        flushMissingDefaultKeys()
                    }
                    let section = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
                    inDefault = (section == "default")
                    if inDefault { foundDefault = true }
                    out.append(rawLine)
                    continue
                }

                if inDefault, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"), let eq = trimmed.firstIndex(of: "=") {
                    let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                    if key == "mc_on" {
                        out.append("mc_on=no")
                        wroteMC = true
                        continue
                    }
                    if key == "max_resp_timeout" {
                        out.append("max_resp_timeout=60")
                        wroteTimeout = true
                        continue
                    }
                }
                out.append(rawLine)
            }

            if inDefault {
                // Trim trailing blank lines inside [default] before appending keys
                while out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                    out.removeLast()
                }
                flushMissingDefaultKeys()
            } else if !foundDefault {
                var prefix = ["[default]", "mc_on=no", "max_resp_timeout=60", ""]
                prefix.append(contentsOf: out)
                out = prefix
            }

            let joined = out.joined(separator: "\n").trimmingCharacters(in: .newlines)
            return joined + "\n"
        } else {
            guard !trimmedExisting.isEmpty else { return nil }
            let lines = (existingContent ?? "").components(separatedBy: .newlines)
            var out: [String] = []
            var inDefault = false
            var defaultHeaderIndex: Int?
            var defaultHasRemainingEntries = false

            func pruneEmptyDefaultSectionIfNeeded() {
                if let headerIdx = defaultHeaderIndex, !defaultHasRemainingEntries {
                    // Remove [default] header and any blank lines immediately after it
                    while out.count > headerIdx {
                        out.removeLast()
                    }
                }
                defaultHeaderIndex = nil
                defaultHasRemainingEntries = false
            }

            for rawLine in lines {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed == managedHeader {
                    continue
                }
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    if inDefault {
                        pruneEmptyDefaultSectionIfNeeded()
                    }
                    let section = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
                    inDefault = (section == "default")
                    if inDefault {
                        defaultHeaderIndex = out.count
                        defaultHasRemainingEntries = false
                    }
                    out.append(rawLine)
                    continue
                }
                if inDefault, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"), let eq = trimmed.firstIndex(of: "=") {
                    let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                    if key == "mc_on" || key == "max_resp_timeout" {
                        continue
                    }
                }
                if inDefault && !trimmed.isEmpty {
                    defaultHasRemainingEntries = true
                }
                out.append(rawLine)
            }

            if inDefault {
                pruneEmptyDefaultSectionIfNeeded()
            }

            let joined = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined + "\n"
        }
    }
}
