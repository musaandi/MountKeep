import Foundation

/// Lightweight thread-safe rolling file logger writing to `~/Library/Logs/MountKeep.log`.
public final class MountLogger: @unchecked Sendable {
    public static let shared = MountLogger()

    public let logFileURL: URL
    private let queue = DispatchQueue(label: "com.mountkeep.logger", qos: .utility)
    private let maxFileSizeBytes: UInt64 = 1_048_576 // 1 MiB
    private let dateFormatter: ISO8601DateFormatter

    public init(logFileURL: URL? = nil) {
        if let customURL = logFileURL {
            self.logFileURL = customURL
        } else {
            let logsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs", isDirectory: true)
            self.logFileURL = logsDir.appendingPathComponent("MountKeep.log")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        self.dateFormatter = formatter
    }

    public func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    public func warn(_ message: String) {
        write(level: "WARN", message: message)
    }

    public func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    private func write(level: String, message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level)] \(message)\n"
        queue.async { [logFileURL, maxFileSizeBytes] in
            let fm = FileManager.default
            let dir = logFileURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            if let attrs = try? fm.attributesOfItem(atPath: logFileURL.path),
               let size = attrs[.size] as? UInt64,
               size >= maxFileSizeBytes {
                let backupURL = logFileURL.deletingPathExtension().appendingPathExtension("log.1")
                try? fm.removeItem(at: backupURL)
                try? fm.moveItem(at: logFileURL, to: backupURL)
            }
            if !fm.fileExists(atPath: logFileURL.path) {
                fm.createFile(atPath: logFileURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: logFileURL),
               let data = line.data(using: .utf8) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }
}
