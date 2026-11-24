import Foundation

public struct AppReleaseInfo: Equatable, Sendable {
    public let version: String
    public let tagName: String
    public let releaseURL: URL
    public let releaseNotes: String?
    public let publishedAt: String?
    public let assetDownloadURL: URL?
    public let assetName: String?
    public let sourceTarballURL: URL?

    public init(
        version: String,
        tagName: String,
        releaseURL: URL,
        releaseNotes: String? = nil,
        publishedAt: String? = nil,
        assetDownloadURL: URL? = nil,
        assetName: String? = nil,
        sourceTarballURL: URL? = nil
    ) {
        self.version = version
        self.tagName = tagName
        self.releaseURL = releaseURL
        self.releaseNotes = releaseNotes
        self.publishedAt = publishedAt
        self.assetDownloadURL = assetDownloadURL
        self.assetName = assetName
        self.sourceTarballURL = sourceTarballURL
    }

    public var canInstallInApp: Bool {
        assetDownloadURL != nil || sourceTarballURL != nil
    }
}

public enum UpdateInstallProgress: Equatable, Sendable {
    case idle
    case downloading(String)
    case installing(String)
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .downloading, .installing: return true
        case .idle, .failed: return false
        }
    }

    public var message: String? {
        switch self {
        case .idle: return nil
        case .downloading(let msg), .installing(let msg), .failed(let msg): return msg
        }
    }
}

public struct SemanticVersion: Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ raw: String) {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
            cleaned.removeFirst()
        }
        if let dash = cleaned.firstIndex(of: "-") {
            cleaned = String(cleaned[..<dash])
        }
        let parts = cleaned.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else {
            return nil
        }
        self.major = parts[0] ?? 0
        self.minor = parts.count > 1 ? (parts[1] ?? 0) : 0
        self.patch = parts.count > 2 ? (parts[2] ?? 0) : 0
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

public enum UpdateCheckOutcome: Equatable, Sendable {
    case updateAvailable(AppReleaseInfo)
    case upToDate(currentVersion: String)
    case noReleasesPublished
    case failed(String)
}

public enum UpdateChecker {
    public static let defaultOwner = "musaandi"
    public static let defaultRepo = "MountKeep"

    public static func currentAppVersion(bundle: Bundle = .main) -> String {
        (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    public static func parseLatestRelease(from data: Data) -> AppReleaseInfo? {
        struct GitHubAssetPayload: Decodable {
            let name: String
            let browser_download_url: String
        }
        struct GitHubReleasePayload: Decodable {
            let tag_name: String
            let html_url: String
            let body: String?
            let published_at: String?
            let tarball_url: String?
            let draft: Bool?
            let prerelease: Bool?
            let assets: [GitHubAssetPayload]?
        }

        guard let payload = try? JSONDecoder().decode(GitHubReleasePayload.self, from: data),
              payload.draft != true,
              payload.prerelease != true,
              let url = URL(string: payload.html_url),
              let parsed = SemanticVersion(payload.tag_name) else {
            return nil
        }

        let assets = payload.assets ?? []
        let zipAsset = assets.first(where: {
            $0.name.lowercased().hasSuffix(".zip") && $0.name.lowercased().contains("mountkeep")
        }) ?? assets.first(where: {
            $0.name.lowercased().hasSuffix(".zip")
        })

        let assetURL = zipAsset.flatMap { URL(string: $0.browser_download_url) }
        let tarballURL = payload.tarball_url.flatMap(URL.init(string:))

        let trimmedNotes = payload.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedVersion = "\(parsed.major).\(parsed.minor).\(parsed.patch)"
        return AppReleaseInfo(
            version: normalizedVersion,
            tagName: payload.tag_name,
            releaseURL: url,
            releaseNotes: (trimmedNotes?.isEmpty == false) ? trimmedNotes : nil,
            publishedAt: payload.published_at,
            assetDownloadURL: assetURL,
            assetName: zipAsset?.name,
            sourceTarballURL: tarballURL
        )
    }

    public static func isNewer(
        releaseVersion: String,
        than currentVersion: String
    ) -> Bool {
        guard let latest = SemanticVersion(releaseVersion),
              let current = SemanticVersion(currentVersion) else {
            return false
        }
        return latest > current
    }

    public static func checkLatestRelease(
        owner: String = defaultOwner,
        repo: String = defaultRepo,
        currentVersion: String = currentAppVersion()
    ) async -> UpdateCheckOutcome {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            return .failed("Invalid GitHub repository URL.")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MountKeep/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Unexpected network response.")
            }
            if http.statusCode == 404 {
                return .noReleasesPublished
            }
            guard (200...299).contains(http.statusCode) else {
                return .failed("GitHub returned HTTP \(http.statusCode).")
            }
            guard let release = parseLatestRelease(from: data) else {
                return .failed("Could not parse release metadata.")
            }
            if isNewer(releaseVersion: release.version, than: currentVersion) {
                return .updateAvailable(release)
            }
            return .upToDate(currentVersion: currentVersion)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Bundled Changelog & "What's New"

    private static let lastSeenVersionKey = "MountKeepLastSeenVersion"

    public static func extractChangelogSection(forVersion version: String, from markdown: String) -> String? {
        let targetHeader = "## [\(version)]"
        let lines = markdown.components(separatedBy: .newlines)
        var capturing = false
        var captured: [String] = []

        for line in lines {
            if line.hasPrefix("## [") {
                if capturing { break }
                if line.hasPrefix(targetHeader) {
                    capturing = true
                    continue
                }
            } else if capturing {
                captured.append(line)
            }
        }

        let result = captured.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    public static func currentVersionChangelog(
        bundle: Bundle = .main
    ) -> (version: String, notes: String)? {
        let current = currentAppVersion(bundle: bundle)
        guard current != "0.0.0",
              let url = bundle.url(forResource: "CHANGELOG", withExtension: "md"),
              let markdown = try? String(contentsOf: url, encoding: .utf8),
              let notes = extractChangelogSection(forVersion: current, from: markdown) else {
            return nil
        }
        return (current, notes)
    }

    public static func pendingWhatsNewNotes(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) -> (version: String, notes: String)? {
        guard let info = currentVersionChangelog(bundle: bundle) else { return nil }
        let lastSeen = defaults.string(forKey: lastSeenVersionKey)
        guard lastSeen != info.version else { return nil }
        return info
    }

    public static func markWhatsNewSeen(
        version: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(version, forKey: lastSeenVersionKey)
    }

    public static func consumeWhatsNewNotes(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) -> (version: String, notes: String)? {
        guard let info = pendingWhatsNewNotes(bundle: bundle, defaults: defaults) else {
            return nil
        }
        markWhatsNewSeen(version: info.version, defaults: defaults)
        return info
    }
}

// MARK: - Hybrid In-App Updater (Prebuilt .app.zip + Source Tarball Fallback)

public enum AppUpdater {
    public enum InstallAction: Sendable {
        /// Detached swap script is waiting for this app process to terminate, then relaunches the new bundle.
        case terminateForSwap
        /// Detached source installer (`scripts/install.sh`) is building and will stop/relaunch MountKeep when done.
        case runningExternalInstaller
    }

    public static func install(
        release: AppReleaseInfo,
        onProgress: @escaping @Sendable (UpdateInstallProgress) -> Void
    ) async -> Result<InstallAction, Error> {
        if let zipURL = release.assetDownloadURL {
            return await installFromZip(release: release, zipURL: zipURL, onProgress: onProgress)
        }
        if let tarballURL = release.sourceTarballURL {
            return await installFromSourceTarball(release: release, tarballURL: tarballURL, onProgress: onProgress)
        }
        return .failure(makeError("No downloadable package found for v\(release.version). Use View on GitHub instead."))
    }

    private static func installFromZip(
        release: AppReleaseInfo,
        zipURL: URL,
        onProgress: @escaping @Sendable (UpdateInstallProgress) -> Void
    ) async -> Result<InstallAction, Error> {
        let label = release.assetName ?? "MountKeep v\(release.version)"
        onProgress(.downloading("Downloading \(label)…"))

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mountkeep-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            let zipFile = workDir.appendingPathComponent("update.zip")
            try await downloadFile(from: zipURL, to: zipFile)

            onProgress(.installing("Extracting & verifying v\(release.version)…"))
            let extractDir = workDir.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            try runTool("/usr/bin/ditto", arguments: ["-x", "-k", zipFile.path, extractDir.path])

            guard let stagedApp = findAppBundle(in: extractDir) else {
                throw makeError("Downloaded archive did not contain a valid MountKeep.app bundle.")
            }

            let binary = stagedApp.appendingPathComponent("Contents/MacOS/MountKeep")
            guard FileManager.default.isExecutableFile(atPath: binary.path) else {
                throw makeError("Extracted MountKeep.app is missing its executable.")
            }

            // Remove any quarantine attribute and re-sign with this Mac's local Apple Development cert
            // if available so macOS preserves Local Network Privacy across updates.
            _ = try? runTool("/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", stagedApp.path])
            resignWithLocalDevCertIfAvailable(appBundlePath: stagedApp.path)

            onProgress(.installing("Installing v\(release.version) & relaunching…"))
            let targetApp = currentInstallTargetPath()
            try launchDetachedAppSwap(
                currentPID: ProcessInfo.processInfo.processIdentifier,
                stagedAppPath: stagedApp.path,
                targetAppPath: targetApp,
                workDirPath: workDir.path
            )
            return .success(.terminateForSwap)
        } catch {
            try? FileManager.default.removeItem(at: workDir)
            return .failure(error)
        }
    }

    private static func installFromSourceTarball(
        release: AppReleaseInfo,
        tarballURL: URL,
        onProgress: @escaping @Sendable (UpdateInstallProgress) -> Void
    ) async -> Result<InstallAction, Error> {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/swift") else {
            return .failure(makeError(
                "v\(release.version) has no prebuilt .zip asset and Xcode Command Line Tools (swift) are not installed. Click View on GitHub to update manually."
            ))
        }

        onProgress(.downloading("Downloading v\(release.version) source…"))
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mountkeep-src-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let tarFile = workDir.appendingPathComponent("source.tar.gz")
            try await downloadFile(from: tarballURL, to: tarFile)

            onProgress(.installing("Building & installing v\(release.version) (this takes ~15s)…"))
            let extractDir = workDir.appendingPathComponent("src", isDirectory: true)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            try runTool("/usr/bin/tar", arguments: ["-xzf", tarFile.path, "-C", extractDir.path])

            guard let installScript = findInstallScript(in: extractDir) else {
                throw makeError("Source archive did not contain scripts/install.sh.")
            }

            let runner = Process()
            runner.executableURL = URL(fileURLWithPath: "/bin/sh")
            runner.arguments = [
                "-c",
                #"bash "$1" >/tmp/mountkeep-updater.log 2>&1; rm -rf "$2""#,
                "mountkeep-src-updater",
                installScript.path,
                workDir.path
            ]
            runner.standardInput = FileHandle.nullDevice
            runner.standardOutput = FileHandle.nullDevice
            runner.standardError = FileHandle.nullDevice
            try runner.run()
            return .success(.runningExternalInstaller)
        } catch {
            try? FileManager.default.removeItem(at: workDir)
            return .failure(error)
        }
    }

    private static func downloadFile(from url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 90
        request.setValue("MountKeep/\(UpdateChecker.currentAppVersion())", forHTTPHeaderField: "User-Agent")

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw makeError("Download failed (HTTP \(code)).")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    private static func currentInstallTargetPath() -> String {
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            return bundlePath
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/MountKeep.app").path
    }

    private static func findAppBundle(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let item as URL in enumerator {
            if item.lastPathComponent == "MountKeep.app" {
                return item
            }
            if item.pathExtension == "app" {
                enumerator.skipDescendants()
            }
        }
        return nil
    }

    private static func findInstallScript(in directory: URL) -> URL? {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return nil }
        for child in children {
            let candidate = child.appendingPathComponent("scripts/install.sh")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func resignWithLocalDevCertIfAvailable(appBundlePath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-identity", "-v", "-p", "codesigning"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return }

        for line in output.components(separatedBy: .newlines) where line.contains("Apple Development:") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            if parts.count >= 2 {
                let hash = String(parts[1])
                if hash.count == 40 {
                    _ = try? runTool("/usr/bin/codesign", arguments: ["--force", "--deep", "--sign", hash, appBundlePath])
                    return
                }
            }
        }
    }

    private static func launchDetachedAppSwap(
        currentPID: Int32,
        stagedAppPath: String,
        targetAppPath: String,
        workDirPath: String
    ) throws {
        let script = #"""
        OLD_PID="$1"
        STAGED_APP="$2"
        TARGET_APP="$3"
        WORK_DIR="$4"
        BACKUP_APP="${TARGET_APP}.previous"

        i=0
        while kill -0 "$OLD_PID" 2>/dev/null && [ "$i" -lt 50 ]; do
            sleep 0.1
            i=$((i + 1))
        done

        mkdir -p "$(dirname "$TARGET_APP")"
        rm -rf "$BACKUP_APP"
        if [ -e "$TARGET_APP" ]; then
            mv "$TARGET_APP" "$BACKUP_APP" || exit 1
        fi

        if mv "$STAGED_APP" "$TARGET_APP"; then
            rm -rf "$BACKUP_APP" "$WORK_DIR"
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET_APP" >/dev/null 2>&1 || true
            open -n "$TARGET_APP"
        else
            if [ -e "$BACKUP_APP" ]; then
                mv "$BACKUP_APP" "$TARGET_APP" || true
            fi
            rm -rf "$WORK_DIR"
            exit 1
        fi
        """#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            script,
            "mountkeep-swap-updater",
            String(currentPID),
            stagedAppPath,
            targetAppPath,
            workDirPath
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    @discardableResult
    private static func runTool(_ path: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw makeError(errText.isEmpty ? "\(path) exited with status \(process.terminationStatus)" : errText)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(
            domain: "MountKeep.AppUpdater",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
