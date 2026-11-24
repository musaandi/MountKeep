import SwiftUI
import AppKit

public struct RemotePowerSetupView: View {
    let serverHost: String
    let sshUsername: String
    let keyPath: String
    let onDismiss: () -> Void

    @State private var publicKey: String?
    @State private var isGenerating = false
    @State private var keyError: String?
    @State private var copiedScript = false

    public init(
        serverHost: String,
        sshUsername: String,
        keyPath: String,
        onDismiss: @escaping () -> Void
    ) {
        self.serverHost = serverHost
        self.sshUsername = sshUsername
        self.keyPath = keyPath
        self.onDismiss = onDismiss
    }

    private var effectiveKeyPath: String {
        let trimmed = keyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? RemotePower.defaultKeyPath : trimmed
    }

    private var setupScript: String {
        RemotePower.windowsSetupScript(publicKey: publicKey)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "power.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remote Shut Down Setup (SSH)")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Safely power off \(serverHost.isEmpty ? "your Windows PC" : serverHost) after unmounting its shares.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Step 1: Dedicated SSH Key on Mac
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Create a dedicated shutdown-only SSH key on this Mac")
                            .font(.system(size: 12.5, weight: .semibold))

                        HStack(spacing: 8) {
                            if publicKey != nil {
                                Label("Key ready at \(effectiveKeyPath)", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Label("No key found at \(effectiveKeyPath)", systemImage: "key")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if publicKey == nil {
                                Button(isGenerating ? "Generating…" : "Generate Shutdown Key") {
                                    generateKey()
                                }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                                .disabled(isGenerating)
                            }
                        }

                        if let keyError {
                            Text(keyError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    // Step 2: Windows PowerShell Setup
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("2. Run once in PowerShell (as Administrator) on Windows")
                                .font(.system(size: 12.5, weight: .semibold))
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(setupScript, forType: .string)
                                copiedScript = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                    copiedScript = false
                                }
                            } label: {
                                Label(copiedScript ? "Copied!" : "Copy PowerShell", systemImage: copiedScript ? "checkmark" : "doc.on.doc")
                                    .font(.caption)
                            }
                            .controlSize(.small)
                        }

                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(setupScript)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(10)
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                        )

                        Text("Security: the forced-command prefix (`command=\"shutdown /s /t 5\"`) restricts this key so it cannot open a shell or run any command other than a 5-second graceful shutdown.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Step 3: Enable in MountKeep
                    VStack(alignment: .leading, spacing: 4) {
                        Text("3. Enable & Save in MountKeep")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("Check \"Enable Remote Shut Down (SSH)\" (using Windows admin username \(sshUsername.isEmpty ? "e.g. admin" : "\"\(sshUsername)\"")) and click Save. When the PC is online, an Off button appears next to it in the menu bar popover. MountKeep always unmounts all shares first and cancels shutdown if any files are busy.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560, height: 470)
        .onAppear {
            publicKey = RemotePower.readPublicKey(forPrivateKeyPath: effectiveKeyPath)
        }
    }

    private func generateKey() {
        isGenerating = true
        keyError = nil
        let targetPath = effectiveKeyPath
        Task {
            let result = await RemotePower.generateKeyPairIfNeeded(at: targetPath)
            await MainActor.run {
                isGenerating = false
                switch result {
                case .success(let pub):
                    publicKey = pub
                case .failure(let err):
                    keyError = err.localizedDescription
                }
            }
        }
    }
}
