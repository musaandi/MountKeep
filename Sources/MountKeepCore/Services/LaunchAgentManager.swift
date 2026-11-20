import Foundation
import Darwin
import ServiceManagement

/// Manages MountKeep's Login Item using macOS's native `SMAppService.mainApp` API
/// so System Settings displays `MountKeep.app` with its app icon (instead of a
/// legacy LaunchAgent grouped under the developer certificate name).
public enum LaunchAgentManager {
    public static let label = "com.mountkeep.app"

    public static var legacyPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    public static func isEnabled() -> Bool {
        guard isBundledApp else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    public static func setEnabled(_ enabled: Bool) throws {
        // Always clean up any legacy LaunchAgent plist so macOS Login Items
        // never shows a duplicate/generic developer-name entry.
        removeLegacyLaunchAgentIfPresent()

        guard isBundledApp else {
            throw NSError(
                domain: "MountKeep.LoginItem",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Launch at Login requires running from MountKeep.app."]
            )
        }

        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
        }
    }

    /// Removes any older legacy `~/Library/LaunchAgents/com.mountkeep.app.plist` entry.
    public static func removeLegacyLaunchAgentIfPresent() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyPlistURL.path) else { return }

        let uid = getuid()
        runLaunchctl(["disable", "gui/\(uid)/\(label)"])
        try? fm.removeItem(at: legacyPlistURL)
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
