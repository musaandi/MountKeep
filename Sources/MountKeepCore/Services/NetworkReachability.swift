import Foundation
import Darwin
import Network

public struct HostProbeResult: Sendable {
    public let isReachable: Bool
    public let primaryIP: String?
    public let allIPs: Set<String>

    public init(isReachable: Bool, primaryIP: String?, allIPs: Set<String>) {
        self.isReachable = isReachable
        self.primaryIP = primaryIP
        self.allIPs = allIPs
    }
}

public enum NetworkReachability {
    private static let probeQueue = DispatchQueue(
        label: "com.mountkeep.probe",
        qos: .utility,
        attributes: .concurrent
    )

    /// Fast, non-blocking TCP probe to SMB port 445 with strict total timeout.
    public static func probeSMBHost(
        _ host: String,
        port: UInt16 = 445,
        timeout: TimeInterval = 1.5
    ) async -> HostProbeResult {
        await withCheckedContinuation { continuation in
            probeQueue.async {
                let result = probeSync(host: host, port: port, timeout: timeout)
                continuation.resume(returning: result)
            }
        }
    }

    private static func probeSync(host: String, port: UInt16, timeout: TimeInterval) -> HostProbeResult {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return HostProbeResult(isReachable: false, primaryIP: nil, allIPs: [])
        }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var resultPtr: UnsafeMutablePointer<addrinfo>?
        let portString = String(port)
        guard getaddrinfo(trimmed, portString, &hints, &resultPtr) == 0, let first = resultPtr else {
            return HostProbeResult(isReachable: false, primaryIP: nil, allIPs: [])
        }
        defer { freeaddrinfo(first) }

        // Collect all resolved addresses, preferring IPv4 first for local LAN reliability.
        var entries: [(info: addrinfo, ip: String)] = []
        var allIPs = Set<String>()
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let ptr = current {
            let info = ptr.pointee
            if let ip = formatAddress(info) {
                allIPs.insert(ip)
                entries.append((info, ip))
            }
            current = info.ai_next
        }
        entries.sort { lhs, rhs in
            (lhs.info.ai_family == AF_INET ? 0 : 1) < (rhs.info.ai_family == AF_INET ? 0 : 1)
        }

        let deadline = Date().addingTimeInterval(timeout)
        for entry in entries {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0.05 { break }
            if tryConnect(info: entry.info, timeout: remaining) {
                return HostProbeResult(isReachable: true, primaryIP: entry.ip, allIPs: allIPs)
            }
        }

        return HostProbeResult(isReachable: false, primaryIP: entries.first?.ip, allIPs: allIPs)
    }

    private static func tryConnect(info: addrinfo, timeout: TimeInterval) -> Bool {
        let fd = Darwin.socket(info.ai_family, info.ai_socktype, info.ai_protocol)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }

        let connectResult = Darwin.connect(fd, info.ai_addr, info.ai_addrlen)
        if connectResult == 0 {
            return true
        }
        guard errno == EINPROGRESS else {
            return false
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let timeoutMs = max(1, Int32(timeout * 1000))
        let pollResult = Darwin.poll(&pfd, 1, timeoutMs)
        guard pollResult > 0, (pfd.revents & Int16(POLLOUT)) != 0 else {
            return false
        }

        var sockErr: Int32 = 0
        var sockErrLen = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &sockErr, &sockErrLen) == 0 else {
            return false
        }
        return sockErr == 0
    }

    private static func formatAddress(_ info: addrinfo) -> String? {
        guard let sa = info.ai_addr else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if info.ai_family == AF_INET {
            var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard inet_ntop(AF_INET, &sin, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(cString: buffer)
        } else if info.ai_family == AF_INET6 {
            var sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            guard inet_ntop(AF_INET6, &sin6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(cString: buffer)
        }
        return nil
    }
}

/// Observes system network path transitions (Wi-Fi/Ethernet changes, interface up/down).
public final class NetworkPathObserver {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.mountkeep.nwpath", qos: .utility)
    private var lastSignature: String?
    private let onNetworkChanged: @Sendable (Bool) -> Void

    public init(onNetworkChanged: @escaping @Sendable (Bool) -> Void) {
        self.onNetworkChanged = onNetworkChanged
    }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let interfaces = path.availableInterfaces.map { "\($0.name):\($0.type)" }.sorted().joined(separator: ",")
            let sig = "\(path.status)|\(interfaces)"
            let previous = self.lastSignature
            self.lastSignature = sig

            // Ignore initial callback on start (MountManager runs an initial check on launch).
            guard previous != nil, previous != sig else { return }
            self.onNetworkChanged(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
    }
}
