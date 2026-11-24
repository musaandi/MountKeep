import Foundation

public struct AppReleaseInfo: Equatable, Sendable {
    public let version: String
    public let tagName: String
    public let releaseURL: URL
    public let releaseNotes: String?
    public let publishedAt: String?

    public init(
        version: String,
        tagName: String,
        releaseURL: URL,
        releaseNotes: String? = nil,
        publishedAt: String? = nil
    ) {
        self.version = version
        self.tagName = tagName
        self.releaseURL = releaseURL
        self.releaseNotes = releaseNotes
        self.publishedAt = publishedAt
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
        struct GitHubReleasePayload: Decodable {
            let tag_name: String
            let html_url: String
            let body: String?
            let published_at: String?
            let draft: Bool?
            let prerelease: Bool?
        }

        guard let payload = try? JSONDecoder().decode(GitHubReleasePayload.self, from: data),
              payload.draft != true,
              payload.prerelease != true,
              let url = URL(string: payload.html_url),
              let parsed = SemanticVersion(payload.tag_name) else {
            return nil
        }

        let trimmedNotes = payload.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedVersion = "\(parsed.major).\(parsed.minor).\(parsed.patch)"
        return AppReleaseInfo(
            version: normalizedVersion,
            tagName: payload.tag_name,
            releaseURL: url,
            releaseNotes: (trimmedNotes?.isEmpty == false) ? trimmedNotes : nil,
            publishedAt: payload.published_at
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

    public static func consumeWhatsNewNotes(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) -> (version: String, notes: String)? {
        let current = currentAppVersion(bundle: bundle)
        guard current != "0.0.0" else { return nil }
        let lastSeen = defaults.string(forKey: lastSeenVersionKey)
        guard lastSeen != current else { return nil }

        defaults.set(current, forKey: lastSeenVersionKey)

        guard let url = bundle.url(forResource: "CHANGELOG", withExtension: "md"),
              let markdown = try? String(contentsOf: url, encoding: .utf8),
              let notes = extractChangelogSection(forVersion: current, from: markdown) else {
            return nil
        }
        return (current, notes)
    }
}
