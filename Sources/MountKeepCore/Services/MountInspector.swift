import Foundation
@preconcurrency import Dispatch
import Darwin

public struct MountedSMBShare: Equatable, Sendable {
    public let mountFrom: String
    public let mountPoint: String
    public let host: String
    public let username: String?
    public let shareName: String
    public let capacity: VolumeCapacity?

    public init(
        mountFrom: String,
        mountPoint: String,
        host: String,
        username: String?,
        shareName: String,
        capacity: VolumeCapacity? = nil
    ) {
        self.mountFrom = mountFrom
        self.mountPoint = mountPoint
        self.host = host
        self.username = username
        self.shareName = shareName
        self.capacity = capacity
    }
}

public enum MountInspector {
    private static let statQueue = DispatchQueue(
        label: "com.mountkeep.statfs",
        qos: .utility,
        attributes: .concurrent
    )

    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var consumed = false

        func tryConsume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if consumed { return false }
            consumed = true
            return true
        }
    }

    /// Extracts overflow-safe `VolumeCapacity` from a `Darwin.statfs` struct.
    public static func capacity(from fs: Darwin.statfs) -> VolumeCapacity? {
        let blockSize = UInt64(fs.f_bsize)
        guard blockSize > 0, fs.f_blocks > 0 else { return nil }
        let (total, totalOverflow) = UInt64(fs.f_blocks).multipliedReportingOverflow(by: blockSize)
        guard !totalOverflow, total > 0 else { return nil }
        let (avail, availOverflow) = UInt64(fs.f_bavail).multipliedReportingOverflow(by: blockSize)
        let safeAvail = availOverflow ? total : min(avail, total)
        return VolumeCapacity(totalBytes: total, availableBytes: safeAvail)
    }

    /// Refreshes live capacity for a mounted SMB volume via `Darwin.statfs` with a strict timeout.
    public static func fetchFreshCapacity(
        forMountPoint mountPoint: String,
        timeout: TimeInterval = 2.5
    ) async -> VolumeCapacity? {
        await withCheckedContinuation { (continuation: CheckedContinuation<VolumeCapacity?, Never>) in
            let gate = OnceGate()
            let timeoutWork = DispatchWorkItem {
                if gate.tryConsume() {
                    continuation.resume(returning: nil)
                }
            }
            statQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

            statQueue.async {
                let url = URL(fileURLWithPath: mountPoint)
                let vals = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
                timeoutWork.cancel()
                guard gate.tryConsume() else { return }
                if let total = vals?.volumeTotalCapacity, total > 0,
                   let avail = vals?.volumeAvailableCapacity, avail >= 0 {
                    continuation.resume(
                        returning: VolumeCapacity(totalBytes: UInt64(total), availableBytes: UInt64(avail))
                    )
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Non-blocking snapshot of all currently mounted `smbfs` filesystems using POSIX `getfsstat`.
    public static func mountedSMBShares() -> [MountedSMBShare] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }

        var stats = Array<Darwin.statfs>(repeating: Darwin.statfs(), count: Int(count) + 8)
        let bufferSize = Int32(stats.count * MemoryLayout<Darwin.statfs>.stride)
        let actualCount = getfsstat(&stats, bufferSize, MNT_NOWAIT)
        guard actualCount > 0 else { return [] }

        var results: [MountedSMBShare] = []
        results.reserveCapacity(Int(actualCount))

        for i in 0..<Int(actualCount) {
            let fs = stats[i]
            let fsType = cString(from: fs.f_fstypename)
            guard fsType == "smbfs" else { continue }

            let mntFrom = cString(from: fs.f_mntfromname)
            let mntOn = cString(from: fs.f_mntonname)
            let cap = capacity(from: fs)

            if let parsed = parseMountFrom(mntFrom, mountPoint: mntOn, capacity: cap) {
                results.append(parsed)
            }
        }
        return results
    }

    /// Parses a `statfs.f_mntfromname` value like `//alice@studio-nas/%28Archive%29%20Media`.
    public static func parseMountFrom(
        _ mountFrom: String,
        mountPoint: String,
        capacity: VolumeCapacity? = nil
    ) -> MountedSMBShare? {
        var remainder = mountFrom
        if remainder.lowercased().hasPrefix("smb://") {
            remainder = String(remainder.dropFirst(6))
        } else if remainder.hasPrefix("//") {
            remainder = String(remainder.dropFirst(2))
        } else {
            return nil
        }

        guard let slashIdx = remainder.firstIndex(of: "/") else { return nil }
        let authority = String(remainder[..<slashIdx])
        let encodedPath = String(remainder[remainder.index(after: slashIdx)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !authority.isEmpty, !encodedPath.isEmpty else { return nil }

        let username: String?
        let hostWithPort: String
        if let atIdx = authority.lastIndex(of: "@") {
            let rawUser = String(authority[..<atIdx])
            username = rawUser.removingPercentEncoding ?? rawUser
            hostWithPort = String(authority[authority.index(after: atIdx)...])
        } else {
            username = nil
            hostWithPort = authority
        }

        let host: String
        if hostWithPort.hasPrefix("["), let closeBracket = hostWithPort.firstIndex(of: "]") {
            host = String(hostWithPort[hostWithPort.index(after: hostWithPort.startIndex)..<closeBracket])
        } else if let colonIdx = hostWithPort.lastIndex(of: ":") {
            host = String(hostWithPort[..<colonIdx])
        } else {
            host = hostWithPort
        }

        guard !host.isEmpty else { return nil }

        let decodedShare = encodedPath.removingPercentEncoding ?? encodedPath
        return MountedSMBShare(
            mountFrom: mountFrom,
            mountPoint: mountPoint,
            host: host,
            username: username,
            shareName: decodedShare,
            capacity: capacity
        )
    }

    /// Normalizes a hostname for resilient matching (case-insensitive, strips trailing `.` and `.local`).
    public static func normalizeHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") {
            value.removeLast()
        }
        if value.hasSuffix(".local") {
            value = String(value.dropLast(6))
        }
        return value
    }

    /// Matches a configured host + share against a live mounted SMB share.
    public static func matches(
        mounted: MountedSMBShare,
        configuredHost: String,
        configuredHostIPs: Set<String> = [],
        configuredShareName: String
    ) -> Bool {
        guard mounted.shareName.caseInsensitiveCompare(configuredShareName) == .orderedSame else {
            return false
        }
        let normMounted = normalizeHost(mounted.host)
        let normConfigured = normalizeHost(configuredHost)
        if normMounted == normConfigured {
            return true
        }
        if configuredHostIPs.contains(normMounted) || configuredHostIPs.contains(mounted.host) {
            return true
        }
        return false
    }

    /// Builds a properly percent-encoded SMB URL (`smb://[user@]host/share`) for `NetFSMountURLAsync`.
    public static func buildSMBURL(host: String, username: String, shareName: String) -> URL? {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanShare = shareName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanHost.isEmpty, !cleanShare.isEmpty else { return nil }

        var comps = URLComponents()
        comps.scheme = "smb"
        comps.host = cleanHost

        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUser.isEmpty {
            let userAllowed = CharacterSet.urlUserAllowed.subtracting(CharacterSet(charactersIn: "@:/?"))
            comps.percentEncodedUser = trimmedUser.addingPercentEncoding(withAllowedCharacters: userAllowed)
        }

        // RFC 3986 unreserved characters so spaces, parentheses, #, %, etc. encode cleanly.
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedSegment = cleanShare.addingPercentEncoding(withAllowedCharacters: unreserved) ?? cleanShare
        comps.percentEncodedPath = "/" + encodedSegment

        return comps.url
    }

    /// Resolves IPv4/IPv6 addresses for a host via `getaddrinfo`. Should be called off the main thread.
    public static func resolveAddresses(for host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var resultPtr: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &resultPtr)
        guard status == 0, let first = resultPtr else { return [] }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var seen = Set<String>()
        var current: UnsafeMutablePointer<addrinfo>? = first

        while let ptr = current {
            let info = ptr.pointee
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if info.ai_family == AF_INET, let sa = info.ai_addr {
                var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                if inet_ntop(AF_INET, &sin, &buffer, socklen_t(buffer.count)) != nil {
                    let ip = String(cString: buffer)
                    if seen.insert(ip).inserted { addresses.append(ip) }
                }
            } else if info.ai_family == AF_INET6, let sa = info.ai_addr {
                var sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                if inet_ntop(AF_INET6, &sin6, &buffer, socklen_t(buffer.count)) != nil {
                    let ip = String(cString: buffer)
                    if seen.insert(ip).inserted { addresses.append(ip) }
                }
            }
            current = info.ai_next
        }
        return addresses
    }

    private static func cString<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

public enum SMBUtilParser {
    /// Parses `smbutil view` output and returns sorted non-hidden `Disk` share names.
    public static func parseDiskShares(from output: String, includeHidden: Bool = false) -> [String] {
        let lines = output.components(separatedBy: .newlines)
        guard let separatorIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("---") }) else {
            return []
        }

        let sharePattern = try? NSRegularExpression(
            pattern: #"^(.+?)\s{2,}(Disk|Pipe|Print|IPC|Device|Comm)(?:\s+.*)?$"#,
            options: []
        )
        let fallbackPattern = try? NSRegularExpression(
            pattern: #"^(.+?)\s+(Disk|Pipe|Print|IPC|Device|Comm)(?:\s+.*)?$"#,
            options: []
        )

        var shares: [String] = []
        var seen = Set<String>()

        for line in lines.dropFirst(separatorIdx + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasSuffix("shares listed") || trimmed.hasSuffix("share listed") { break }

            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            let match = sharePattern?.firstMatch(in: line, range: range)
                ?? fallbackPattern?.firstMatch(in: line, range: range)
            guard let match, match.numberOfRanges >= 3 else { continue }

            let name = nsLine.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespaces)
            let type = nsLine.substring(with: match.range(at: 2))

            guard type == "Disk", !name.isEmpty else { continue }
            if !includeHidden && name.hasSuffix("$") { continue }

            let key = name.lowercased()
            if seen.insert(key).inserted {
                shares.append(name)
            }
        }

        return shares.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
