import Foundation
@preconcurrency import Dispatch
import AppKit
import Darwin
import NetFS

public enum MountOutcome: Sendable, Equatable {
    case mounted(mountPoint: String)
    case failed(code: Int32, message: String, isAuthError: Bool)
}

public enum MountHealth: Sendable, Equatable {
    case healthy
    case stale(reason: String)
    case timedOut
}

public enum NetFSMounter {
    private static let netfsQueue = DispatchQueue(
        label: "com.mountkeep.netfs",
        qos: .utility,
        attributes: .concurrent
    )
    private static let utilityQueue = DispatchQueue(
        label: "com.mountkeep.utility",
        qos: .utility,
        attributes: .concurrent
    )
    private static let healthQueue = DispatchQueue(
        label: "com.mountkeep.health",
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

    /// Returns true if a NetFS / errno status indicates an authentication / Keychain credentials problem.
    public static func isAuthError(_ status: Int32) -> Bool {
        switch status {
        case EAUTH, EACCES, EPERM, -5045, -5046, -5999, -6600:
            return true
        default:
            return false
        }
    }

    /// Silently mounts an SMB share using macOS's native NetFS framework & Keychain (`NoUI`, `SoftMount`).
    public static func mount(
        host: String,
        username: String,
        shareName: String,
        timeout: TimeInterval = 15
    ) async -> MountOutcome {
        guard let url = MountInspector.buildSMBURL(host: host, username: username, shareName: shareName) else {
            return .failed(code: EINVAL, message: "Invalid SMB URL for \(host)/\(shareName)", isAuthError: false)
        }

        let openOpts = NSMutableDictionary()
        openOpts[kNAUIOptionKey] = kNAUIOptionNoUI

        let mountOpts = NSMutableDictionary()
        mountOpts[kNetFSSoftMountKey] = true

        return await withCheckedContinuation { continuation in
            let gate = OnceGate()
            var requestID: AsyncRequestID?

            let timeoutWork = DispatchWorkItem {
                guard gate.tryConsume() else { return }
                if let req = requestID {
                    NetFSMountURLCancel(req)
                }
                continuation.resume(
                    returning: .failed(
                        code: ETIMEDOUT,
                        message: "Mount timed out after \(Int(timeout))s",
                        isAuthError: false
                    )
                )
            }

            let startStatus = NetFSMountURLAsync(
                url as CFURL,
                nil,
                nil,
                nil,
                openOpts,
                mountOpts,
                &requestID,
                netfsQueue
            ) { status, _, mountpointsCF in
                timeoutWork.cancel()
                guard gate.tryConsume() else { return }

                if status == 0 {
                    let paths = (mountpointsCF as? [String]) ?? []
                    let mountPath = paths.first ?? "/Volumes/\(shareName)"
                    continuation.resume(returning: .mounted(mountPoint: mountPath))
                } else {
                    continuation.resume(
                        returning: .failed(
                            code: status,
                            message: describeError(status),
                            isAuthError: isAuthError(status)
                        )
                    )
                }
            }

            if startStatus != 0 {
                timeoutWork.cancel()
                if gate.tryConsume() {
                    continuation.resume(
                        returning: .failed(
                            code: startStatus,
                            message: describeError(startStatus),
                            isAuthError: isAuthError(startStatus)
                        )
                    )
                }
            } else {
                netfsQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            }
        }
    }

    /// Cleanly unmounts a mounted volume using `NSWorkspace`.
    public static func unmount(mountPoint: String) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            utilityQueue.async {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: mountPoint))
                    continuation.resume(returning: .success(()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    /// Force-unmounts a dead/stale SMB volume via `diskutil unmount force` (falling back to Darwin `unmount(..., MNT_FORCE)`).
    public static func forceUnmount(mountPoint: String, timeout: TimeInterval = 5) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            utilityQueue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                process.arguments = ["unmount", "force", mountPoint]

                let stderrPipe = Pipe()
                process.standardOutput = FileHandle.nullDevice
                process.standardError = stderrPipe

                let timeoutWork = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }

                do {
                    try process.run()
                    utilityQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
                    process.waitUntilExit()
                    timeoutWork.cancel()

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: .success(()))
                        return
                    }
                } catch {
                    timeoutWork.cancel()
                }

                // Fallback to direct Darwin unmount(MNT_FORCE)
                if Darwin.unmount(mountPoint, MNT_FORCE) == 0 {
                    continuation.resume(returning: .success(()))
                } else {
                    let errCode = errno
                    let errMsg = String(cString: strerror(errCode))
                    let err = NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(errCode),
                        userInfo: [NSLocalizedDescriptionKey: "Force unmount failed: \(errMsg)"]
                    )
                    continuation.resume(returning: .failure(err))
                }
            }
        }
    }

    /// Timeout-guarded liveness probe for an already-mounted SMB volume.
    /// Detects zombie/hung mounts where `opendir` fails (`ESTALE`/`EIO`/`ENOTCONN`) or stalls past `timeout`.
    public static func checkMountHealth(mountPoint: String, timeout: TimeInterval = 3.0) async -> MountHealth {
        await withCheckedContinuation { continuation in
            let gate = OnceGate()

            let timeoutWork = DispatchWorkItem {
                if gate.tryConsume() {
                    continuation.resume(returning: .timedOut)
                }
            }
            utilityQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

            healthQueue.async {
                guard let dir = Darwin.opendir(mountPoint) else {
                    let errCode = errno
                    timeoutWork.cancel()
                    if gate.tryConsume() {
                        let msg = String(cString: strerror(errCode))
                        continuation.resume(returning: .stale(reason: "\(msg) (errno \(errCode))"))
                    }
                    return
                }
                _ = Darwin.readdir(dir)
                Darwin.closedir(dir)

                timeoutWork.cancel()
                if gate.tryConsume() {
                    continuation.resume(returning: .healthy)
                }
            }
        }
    }

    /// Discovers non-hidden `Disk` shares on a server via `smbutil view -N` (never prompts for password).
    public static func discoverShares(
        host: String,
        username: String,
        timeout: TimeInterval = 6
    ) async -> Result<[String], Error> {
        await withCheckedContinuation { continuation in
            utilityQueue.async {
                let target: String
                let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedUser.isEmpty {
                    let allowed = CharacterSet.urlUserAllowed.subtracting(CharacterSet(charactersIn: "@:/?"))
                    let encodedUser = trimmedUser.addingPercentEncoding(withAllowedCharacters: allowed) ?? trimmedUser
                    target = "//\(encodedUser)@\(host)"
                } else {
                    target = "//\(host)"
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")
                process.arguments = ["view", "-N", target]

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let gate = OnceGate()
                let timeoutWork = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                    }
                }

                do {
                    try process.run()
                    utilityQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
                    process.waitUntilExit()
                    timeoutWork.cancel()

                    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let outText = String(data: outData, encoding: .utf8) ?? ""
                    let errText = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    guard gate.tryConsume() else { return }

                    if process.terminationStatus == 0 {
                        let shares = SMBUtilParser.parseDiskShares(from: outText)
                        continuation.resume(returning: .success(shares))
                    } else {
                        let msg = errText.isEmpty
                            ? "smbutil exited with status \(process.terminationStatus)"
                            : errText
                        let err = NSError(
                            domain: "MountKeep.Discover",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: msg]
                        )
                        continuation.resume(returning: .failure(err))
                    }
                } catch {
                    timeoutWork.cancel()
                    if gate.tryConsume() {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
        }
    }

    public static func describeError(_ status: Int32) -> String {
        switch status {
        case EAUTH, EACCES, EPERM, -5045, -5046, -5999:
            return "Authentication failed — check Keychain credentials (code \(status))"
        case ENOENT, -5998, -6003:
            return "Share not found on server (code \(status))"
        case EHOSTUNREACH, ENETUNREACH, ECONNREFUSED, EHOSTDOWN:
            return "Server unreachable (code \(status))"
        case ETIMEDOUT:
            return "Connection timed out (code \(status))"
        case EEXIST, EBUSY:
            return "Mount point busy or already mounted (code \(status))"
        case -6600, -6602:
            return "NetAuth mount failed — verify server & Keychain login (code \(status))"
        case -128:
            return "Mount cancelled (code \(status))"
        default:
            if status > 0, let cStr = strerror(status) {
                return "\(String(cString: cStr)) (errno \(status))"
            }
            return "Mount failed (status \(status))"
        }
    }
}
