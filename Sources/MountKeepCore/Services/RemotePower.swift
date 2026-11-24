import Foundation

public enum RemotePower {
    public static let defaultKeyPath = "~/.ssh/mountkeep_power"
    public static let shutdownCommand = "shutdown /s /t 5"
    private static let queue = DispatchQueue(label: "com.mountkeep.remote-power", qos: .userInitiated)

    public static func expandedPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmed.isEmpty ? defaultKeyPath : trimmed
        return (effective as NSString).expandingTildeInPath
    }

    public static func hasPrivateKey(at rawPath: String = defaultKeyPath) -> Bool {
        FileManager.default.fileExists(atPath: expandedPath(rawPath))
    }

    public static func readPublicKey(forPrivateKeyPath rawPath: String = defaultKeyPath) -> String? {
        let pubPath = expandedPath(rawPath) + ".pub"
        guard let text = try? String(contentsOfFile: pubPath, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Builds non-interactive `/usr/bin/ssh` arguments for remote shutdown.
    /// Works with both forced-command keys (`command="shutdown /s /t 5"`) and regular authorized keys.
    public static func buildSSHArguments(
        host: String,
        username: String,
        keyPath: String = defaultKeyPath
    ) -> [String] {
        [
            "-i", expandedPath(keyPath),
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "IdentitiesOnly=yes",
            "\(username)@\(host)",
            shutdownCommand
        ]
    }

    /// Generates a dedicated Ed25519 SSH key pair (no passphrase) if one does not already exist at `rawPath`.
    public static func generateKeyPairIfNeeded(at rawPath: String = defaultKeyPath) async -> Result<String, Error> {
        await withCheckedContinuation { continuation in
            queue.async {
                let privPath = expandedPath(rawPath)
                let pubPath = privPath + ".pub"

                if let existingPub = readPublicKey(forPrivateKeyPath: rawPath) {
                    continuation.resume(returning: .success(existingPub))
                    return
                }

                do {
                    let parentDir = (privPath as NSString).deletingLastPathComponent
                    try FileManager.default.createDirectory(
                        atPath: parentDir,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
                    process.arguments = [
                        "-t", "ed25519",
                        "-f", privPath,
                        "-N", "",
                        "-C", "mountkeep-power"
                    ]
                    let errPipe = Pipe()
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = errPipe
                    try process.run()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()

                    guard process.terminationStatus == 0 else {
                        let errText = String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "ssh-keygen failed"
                        continuation.resume(returning: .failure(NSError(
                            domain: "MountKeep.RemotePower",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: errText]
                        )))
                        return
                    }

                    let pubKey = try String(contentsOfFile: pubPath, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: .success(pubKey))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    /// Formats the restricted `authorized_keys` line that locks the SSH key to shutdown-only.
    public static func restrictedAuthorizedKeyLine(publicKey: String) -> String {
        let trimmed = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return #"command="shutdown /s /t 5",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty "# + trimmed
    }

    /// Builds an elevated Windows PowerShell setup script for enabling OpenSSH Server and installing
    /// the forced-command shutdown key in `administrators_authorized_keys` with required ACLs.
    public static func windowsSetupScript(publicKey: String?) -> String {
        let keyPlaceholder = publicKey ?? "ssh-ed25519 <PASTE_YOUR_MOUNTKEEP_POWER_PUB_KEY_HERE> mountkeep-power"
        let line = restrictedAuthorizedKeyLine(publicKey: keyPlaceholder)
        let escapedForSingleQuotedPS = line.replacingOccurrences(of: "'", with: "''")

        return """
        # Run in PowerShell as Administrator on your Windows PC
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
        Start-Service sshd
        Set-Service -Name sshd -StartupType Automatic

        $authFile = 'C:\\ProgramData\\ssh\\administrators_authorized_keys'
        $entry = '\(escapedForSingleQuotedPS)'
        New-Item -ItemType Directory -Force -Path (Split-Path $authFile) | Out-Null
        if (-not (Test-Path $authFile) -or -not ((Get-Content $authFile -Raw) -like "*$entry*")) {
            Add-Content -Path $authFile -Value $entry -Encoding ascii
        }

        icacls.exe $authFile /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
        Restart-Service sshd
        """
    }

    /// Sends the remote shutdown command over SSH using macOS's built-in `/usr/bin/ssh`.
    public static func shutdown(
        host: String,
        username: String,
        keyPath: String = defaultKeyPath
    ) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            queue.async {
                let privPath = expandedPath(keyPath)
                guard FileManager.default.fileExists(atPath: privPath) else {
                    continuation.resume(returning: .failure(NSError(
                        domain: "MountKeep.RemotePower",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "SSH key not found at \(keyPath). Open Edit Server → Setup Guide to generate one."]
                    )))
                    return
                }

                let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanUser.isEmpty else {
                    continuation.resume(returning: .failure(NSError(
                        domain: "MountKeep.RemotePower",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "No SSH username configured for \(host)."]
                    )))
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = buildSSHArguments(host: host, username: cleanUser, keyPath: keyPath)
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    _ = outPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: .success(()))
                    } else {
                        let stderrText = String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let message = stderrText.isEmpty
                            ? "SSH exited with status \(process.terminationStatus)"
                            : stderrText.components(separatedBy: .newlines).last ?? stderrText
                        continuation.resume(returning: .failure(NSError(
                            domain: "MountKeep.RemotePower",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: message]
                        )))
                    }
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }
}
