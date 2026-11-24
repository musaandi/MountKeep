import SwiftUI

public enum ReleaseNotesMode: Equatable {
    case updateAvailable(AppReleaseInfo)
    case whatsNew(version: String, notes: String)
}

public struct ReleaseNotesView: View {
    let mode: ReleaseNotesMode
    let onOpenGitHub: (URL) -> Void
    let onDismiss: () -> Void

    public init(
        mode: ReleaseNotesMode,
        onOpenGitHub: @escaping (URL) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.mode = mode
        self.onOpenGitHub = onOpenGitHub
        self.onDismiss = onDismiss
    }

    private var titleText: String {
        switch mode {
        case .updateAvailable(let release):
            return "MountKeep v\(release.version) Available"
        case .whatsNew(let version, _):
            return "What's New in MountKeep v\(version)"
        }
    }

    private var subtitleText: String {
        switch mode {
        case .updateAvailable:
            return "A newer release is published on GitHub."
        case .whatsNew:
            return "Updated and running on this Mac."
        }
    }

    private var bodyMarkdown: String {
        switch mode {
        case .updateAvailable(let release):
            return release.releaseNotes ?? "View full release details on GitHub."
        case .whatsNew(_, let notes):
            return notes
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: isUpdateMode ? "arrow.down.circle.fill" : "sparkles")
                    .font(.system(size: 24))
                    .foregroundStyle(isUpdateMode ? Color.blue : Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                        .font(.system(size: 15, weight: .semibold))
                    Text(subtitleText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(bodyMarkdown.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, rawLine in
                        markdownLineView(rawLine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(2)
            }
            .frame(maxHeight: 240)

            Divider()

            HStack {
                Spacer()
                if case .updateAvailable(let release) = mode {
                    Button("Later", action: onDismiss)
                        .keyboardShortcut(.cancelAction)
                    Button("Open on GitHub") {
                        onOpenGitHub(release.releaseURL)
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done", action: onDismiss)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private var isUpdateMode: Bool {
        if case .updateAvailable = mode { return true }
        return false
    }

    @ViewBuilder
    private func markdownLineView(_ rawLine: String) -> some View {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 2)
        } else if trimmed.hasPrefix("### ") {
            Text(String(trimmed.dropFirst(4)))
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.top, 4)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            let content = String(trimmed.dropFirst(2))
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .foregroundStyle(.secondary)
                formattedText(content)
            }
            .font(.system(size: 12.5))
        } else {
            formattedText(trimmed)
                .font(.system(size: 12.5))
        }
    }

    private func formattedText(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text) {
            return Text(attributed)
        }
        return Text(text)
    }
}
