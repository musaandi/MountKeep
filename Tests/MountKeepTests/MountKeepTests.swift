import XCTest
@testable import MountKeepCore

final class MountKeepTests: XCTestCase {
    func testParseMountFromStandardAndEncodedShares() {
        let parsed1 = MountInspector.parseMountFrom(
            "//alice@studio-nas/%28Archive%29%20Footage",
            mountPoint: "/Volumes/(Archive) Footage"
        )
        XCTAssertEqual(parsed1?.host, "studio-nas")
        XCTAssertEqual(parsed1?.username, "alice")
        XCTAssertEqual(parsed1?.shareName, "(Archive) Footage")
        XCTAssertEqual(parsed1?.mountPoint, "/Volumes/(Archive) Footage")

        let parsed2 = MountInspector.parseMountFrom(
            "//bob@render-pc/Media%20Vault%201",
            mountPoint: "/Volumes/Media Vault 1"
        )
        XCTAssertEqual(parsed2?.host, "render-pc")
        XCTAssertEqual(parsed2?.username, "bob")
        XCTAssertEqual(parsed2?.shareName, "Media Vault 1")
    }

    func testParseMountFromEmailUsernameAndPortsAndIPv6() {
        let email = MountInspector.parseMountFrom(
            "//user%40example.com@192.0.2.48:445/Data%20Drive",
            mountPoint: "/Volumes/Data Drive"
        )
        XCTAssertEqual(email?.username, "user@example.com")
        XCTAssertEqual(email?.host, "192.0.2.48")
        XCTAssertEqual(email?.shareName, "Data Drive")

        let ipv6 = MountInspector.parseMountFrom(
            "//bob@[2001:db8::1]/Scratch%201",
            mountPoint: "/Volumes/Scratch 1"
        )
        XCTAssertEqual(ipv6?.host, "2001:db8::1")
        XCTAssertEqual(ipv6?.shareName, "Scratch 1")
    }

    func testBuildSMBURLRoundTrip() {
        let url1 = MountInspector.buildSMBURL(
            host: "studio-nas",
            username: "alice",
            shareName: "(Archive) Footage"
        )
        XCTAssertEqual(url1?.absoluteString, "smb://alice@studio-nas/%28Archive%29%20Footage")

        let url2 = MountInspector.buildSMBURL(
            host: "render-pc",
            username: "bob",
            shareName: "Media Vault 1"
        )
        XCTAssertEqual(url2?.absoluteString, "smb://bob@render-pc/Media%20Vault%201")

        let urlEmail = MountInspector.buildSMBURL(
            host: "winbox",
            username: "me@example.com",
            shareName: "My Drive"
        )
        XCTAssertEqual(urlEmail?.absoluteString, "smb://me%40example.com@winbox/My%20Drive")
    }

    func testHostNormalizationAndIPMatching() {
        XCTAssertEqual(MountInspector.normalizeHost("Studio-NAS.local."), "studio-nas")
        XCTAssertEqual(MountInspector.normalizeHost("  RENDER-PC.LOCAL "), "render-pc")

        let mountedByIP = MountedSMBShare(
            mountFrom: "//alice@192.0.2.48/Projects%20SSD",
            mountPoint: "/Volumes/Projects SSD",
            host: "192.0.2.48",
            username: "alice",
            shareName: "Projects SSD"
        )
        XCTAssertTrue(
            MountInspector.matches(
                mounted: mountedByIP,
                configuredHost: "studio-nas",
                configuredHostIPs: ["192.0.2.48"],
                configuredShareName: "projects ssd"
            )
        )
        XCTAssertFalse(
            MountInspector.matches(
                mounted: mountedByIP,
                configuredHost: "studio-nas",
                configuredHostIPs: ["192.0.2.48"],
                configuredShareName: "(Archive) Footage"
            )
        )
    }

    func testSMBUtilParserRealWorldOutput() {
        let sampleOutput = """
        Share                                           Type    Comments
        -------------------------------
        Scratch 1                                       Disk    
        C$                                              Disk    Default share
        Media Vault 1                                   Disk    
        Scratch 2                                       Disk    
        IPC$                                            Pipe    Remote IPC
        ADMIN$                                          Disk    Remote Admin
        Users                                           Disk    
        G$                                              Disk    Default share
        F$                                              Disk    Default share
        E$                                              Disk    Default share
        Media Vault 2                                   Disk    
        D$                                              Disk    Default share

        12 shares listed
        """
        let shares = SMBUtilParser.parseDiskShares(from: sampleOutput)
        XCTAssertEqual(
            shares,
            ["Media Vault 1", "Media Vault 2", "Scratch 1", "Scratch 2", "Users"]
        )
    }

    func testSMBURLParser() {
        let p1 = SMBURLParser.parse("smb://alice@studio-nas/Projects SSD")
        XCTAssertEqual(p1, ParsedSMBAddress(host: "studio-nas", username: "alice", shareName: "Projects SSD"))

        let p2 = SMBURLParser.parse("smb://bob:ignoredpass@render-pc/Scratch%201")
        XCTAssertEqual(p2, ParsedSMBAddress(host: "render-pc", username: "bob", shareName: "Scratch 1"))

        let p3 = SMBURLParser.parse("//studio-nas/(Archive) Footage")
        XCTAssertEqual(p3, ParsedSMBAddress(host: "studio-nas", username: nil, shareName: "(Archive) Footage"))

        XCTAssertNil(SMBURLParser.parse("http://example.com/test"))
        XCTAssertNil(SMBURLParser.parse(""))
    }

    func testBackoffPolicy() {
        XCTAssertEqual(BackoffPolicy.delaySeconds(forFailureCount: 0), 0)
        XCTAssertEqual(BackoffPolicy.delaySeconds(forFailureCount: 1), 30)
        XCTAssertEqual(BackoffPolicy.delaySeconds(forFailureCount: 2), 60)
        XCTAssertEqual(BackoffPolicy.delaySeconds(forFailureCount: 3), 180)
        XCTAssertEqual(BackoffPolicy.delaySeconds(forFailureCount: 4), 300)
        XCTAssertEqual(BackoffPolicy.delaySeconds(forFailureCount: 10), 300)
    }

    func testMACAddressNormalization() {
        XCTAssertEqual(MACAddress.normalize("2:11:22:33:44:55"), "02:11:22:33:44:55")
        XCTAssertEqual(MACAddress.normalize("02-AA-B-0C-D-1"), "02:aa:0b:0c:0d:01")
        XCTAssertNil(MACAddress.normalize("ff:ff:ff:ff:ff:ff"))
        XCTAssertNil(MACAddress.normalize("00:00:00:00:00:00"))
        XCTAssertNil(MACAddress.normalize("(incomplete)"))
        XCTAssertNil(MACAddress.normalize("not-a-mac"))
    }

    func testARPParserAndHomeNetworkMatching() {
        let sampleARP = """
        ? (192.0.2.1) at 2:11:22:33:44:55 on en0 ifscope [ethernet]
        ? (192.0.2.48) at 02:aa:bb:cc:dd:01 on en0 ifscope [ethernet]
        ? (192.0.2.97) at 2:aa:bb:0:dd:2 on en0 ifscope [ethernet]
        ? (192.0.2.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
        ? (192.0.2.200) at (incomplete) on en0 ifscope [ethernet]
        """
        let parsed = ARPParser.parse(sampleARP)
        XCTAssertEqual(parsed["192.0.2.1"]?.macAddress, "02:11:22:33:44:55")
        XCTAssertEqual(parsed["192.0.2.48"]?.macAddress, "02:aa:bb:cc:dd:01")
        XCTAssertEqual(parsed["192.0.2.97"]?.macAddress, "02:aa:bb:00:dd:02")
        XCTAssertNil(parsed["192.0.2.255"])
        XCTAssertNil(parsed["192.0.2.200"])

        let homeFP = NetworkFingerprint(
            name: "Home",
            gatewayIP: "192.0.2.1",
            gatewayMAC: "02:11:22:33:44:55"
        )

        // Exact match on primary gateway
        let atHome = NetworkSnapshot(
            gateways: [ActiveGateway(ipAddress: "192.0.2.1", macAddress: "02:11:22:33:44:55", interfaceName: "en0", isPrimary: true)],
            arpByIP: parsed
        )
        XCTAssertTrue(HomeNetworkDetector.matches(snapshot: atHome, allowedNetworks: [homeFP]))

        // Same gateway IP on a coffee-shop router with different MAC -> MUST NOT match
        let coffeeShopSameSubnet = NetworkSnapshot(
            gateways: [ActiveGateway(ipAddress: "192.0.2.1", macAddress: "02:de:ad:be:ef:00", interfaceName: "en0", isPrimary: true)],
            arpByIP: [:]
        )
        XCTAssertFalse(HomeNetworkDetector.matches(snapshot: coffeeShopSameSubnet, allowedNetworks: [homeFP]))

        // VPN primary route + home physical interface still active -> matches
        let homeWithVPN = NetworkSnapshot(
            gateways: [
                ActiveGateway(ipAddress: "10.8.0.1", macAddress: nil, interfaceName: "utun4", isPrimary: true),
                ActiveGateway(ipAddress: "192.0.2.1", macAddress: "02:11:22:33:44:55", interfaceName: "en0", isPrimary: false)
            ],
            arpByIP: parsed
        )
        XCTAssertTrue(HomeNetworkDetector.matches(snapshot: homeWithVPN, allowedNetworks: [homeFP]))

        // Offline -> does not match
        let offline = NetworkSnapshot(gateways: [], arpByIP: [:])
        XCTAssertFalse(HomeNetworkDetector.matches(snapshot: offline, allowedNetworks: [homeFP]))

        // Empty pinned networks -> unrestricted
        XCTAssertTrue(HomeNetworkDetector.matches(snapshot: coffeeShopSameSubnet, allowedNetworks: []))

        // NetworkSignature parser from SCDynamicStore
        let sig = "IPv4.Router=192.0.2.1;IPv4.RouterHardwareAddress=2:11:22:33:44:55"
        XCTAssertEqual(ARPParser.parseRouterMAC(fromNetworkSignature: sig), "02:11:22:33:44:55")
        XCTAssertNil(ARPParser.parseRouterMAC(fromNetworkSignature: "IPv4.Router=10.0.0.1"))
    }

    func testWakeOnLANMagicPacket() {
        guard let packet = WakeOnLAN.magicPacket(for: "02:aa:bb:cc:dd:01") else {
            return XCTFail("Expected valid magic packet")
        }
        XCTAssertEqual(packet.count, 102)
        let bytes = [UInt8](packet)
        XCTAssertEqual(Array(bytes[0..<6]), [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        let expectedMAC: [UInt8] = [0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0x01]
        for i in 0..<16 {
            let start = 6 + i * 6
            XCTAssertEqual(Array(bytes[start..<(start + 6)]), expectedMAC)
        }
        XCTAssertNil(WakeOnLAN.magicPacket(for: "ff:ff:ff:ff:ff:ff"))
    }

    func testAuthErrorClassification() {
        XCTAssertTrue(NetFSMounter.isAuthError(EAUTH))
        XCTAssertTrue(NetFSMounter.isAuthError(EACCES))
        XCTAssertTrue(NetFSMounter.isAuthError(-5045))
        XCTAssertTrue(NetFSMounter.isAuthError(-6600))
        XCTAssertFalse(NetFSMounter.isAuthError(EHOSTUNREACH))
        XCTAssertFalse(NetFSMounter.isAuthError(ETIMEDOUT))
        XCTAssertFalse(NetFSMounter.isAuthError(ENOENT))
    }

    func testConfigStoreV1ToV2BackwardCompatibilityAndClamping() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MountKeepTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let configURL = tempDir.appendingPathComponent("config.json")
        let v1JSON = """
        {
          "mountTimeoutSeconds": 15,
          "paused": false,
          "pollIntervalSeconds": 30,
          "version": 1,
          "servers": [
            {
              "autoSyncAllShares": true,
              "host": "studio-nas",
              "id": "11111111-2222-3333-4444-555555555555",
              "username": "alice",
              "shares": [
                { "enabled": true, "id": "66666666-7777-8888-9999-aaaaaaaaaaaa", "name": "Projects SSD" }
              ]
            }
          ]
        }
        """
        try v1JSON.data(using: .utf8)!.write(to: configURL)

        let store = ConfigStore(configURL: configURL)
        let migrated = store.load()
        XCTAssertEqual(migrated.version, 1)
        XCTAssertEqual(migrated.servers.count, 1)
        XCTAssertEqual(migrated.servers[0].host, "studio-nas")
        XCTAssertTrue(migrated.servers[0].autoSyncAllShares)
        XCTAssertTrue(migrated.servers[0].requireHomeNetwork)
        XCTAssertNil(migrated.servers[0].macAddress)
        XCTAssertEqual(migrated.idlePollIntervalSeconds, 120)
        XCTAssertTrue(migrated.cleanupStaleMountsOnAway)
        XCTAssertTrue(migrated.healZombieMounts)
        XCTAssertTrue(migrated.notifyOnAuthFailure)
        XCTAssertEqual(migrated.storageUnitStyle, .binaryHuman)

        // Verify clamping and storageUnitStyle round-trip on save/reload
        var modified = migrated
        modified.pollIntervalSeconds = 2
        modified.idlePollIntervalSeconds = 5
        modified.mountTimeoutSeconds = 999
        modified.storageUnitStyle = .decimal
        try store.save(modified)

        let reloaded = store.load()
        XCTAssertEqual(reloaded.pollIntervalSeconds, 10)
        XCTAssertEqual(reloaded.idlePollIntervalSeconds, 30)
        XCTAssertEqual(reloaded.mountTimeoutSeconds, 60)
        XCTAssertEqual(reloaded.storageUnitStyle, .decimal)
    }

    func testVolumeCapacityFormattingAndSeverity() {
        // Base-2 human units (default: 1024-based with GB/TB labels)
        let nvme4TB = VolumeCapacity(totalBytes: 4_096_788_525_056, availableBytes: 3_993_071_624_192)
        XCTAssertEqual(nvme4TB.formattedUsedOfTotal(style: .binaryHuman), "96.6 GB / 3.73 TB")
        XCTAssertEqual(nvme4TB.formattedFree(style: .binaryHuman), "3.63 TB free")
        XCTAssertEqual(nvme4TB.usedPercentText, "3%")
        XCTAssertEqual(nvme4TB.severity, .normal)

        // Shared TB unit (critical: 99%)
        let criticalDrive = VolumeCapacity(totalBytes: 8_001_545_039_872, availableBytes: 63_136_964_608)
        XCTAssertEqual(criticalDrive.formattedUsedOfTotal(style: .binaryHuman), "7.22 / 7.28 TB")
        XCTAssertEqual(criticalDrive.formattedFree(style: .binaryHuman), "58.8 GB free")
        XCTAssertEqual(criticalDrive.formattedUsedOfTotal(style: .decimal), "7.94 / 8.00 TB")
        XCTAssertEqual(criticalDrive.formattedFree(style: .decimal), "63.1 GB free")
        XCTAssertEqual(criticalDrive.usedPercentText, "99%")
        XCTAssertEqual(criticalDrive.severity, .critical)

        // Mixed GB / TB units (normal: 8%)
        let mixedDrive = VolumeCapacity(totalBytes: 2_000_263_573_504, availableBytes: 1_838_279_872_512)
        XCTAssertEqual(mixedDrive.formattedUsedOfTotal(style: .decimal), "162 GB / 2.00 TB")
        XCTAssertEqual(mixedDrive.formattedFree(style: .decimal), "1.84 TB free")
        XCTAssertEqual(mixedDrive.usedPercentText, "8%")
        XCTAssertEqual(mixedDrive.severity, .normal)

        // Warning threshold (75%)
        let warningDrive = VolumeCapacity(totalBytes: 4_096_787_476_480, availableBytes: 1_024_196_869_120)
        XCTAssertEqual(warningDrive.usedPercentText, "75%")
        XCTAssertEqual(warningDrive.severity, .warning)

        // Tiny non-zero usage shows "<1%" rather than misleading "0%"
        let nearlyEmpty = VolumeCapacity(totalBytes: 2_048_390_066_176, availableBytes: 2_048_136_372_224)
        XCTAssertEqual(nearlyEmpty.formattedUsedOfTotal(style: .decimal), "254 MB / 2.05 TB")
        XCTAssertEqual(nearlyEmpty.usedPercentText, "<1%")

        // Completely full drive shows "100%"
        let fullDrive = VolumeCapacity(totalBytes: 1_000_000_000_000, availableBytes: 0)
        XCTAssertEqual(fullDrive.formattedUsedOfTotal(style: .decimal), "1.00 / 1.00 TB")
        XCTAssertEqual(fullDrive.usedPercentText, "100%")

        // 970 GB / 1000 GB steps total to 1.00 TB cleanly; 970 / 990 GB shares GB
        let oneTB = VolumeCapacity(totalBytes: 1_000_000_000_000, availableBytes: 30_000_000_000)
        XCTAssertEqual(oneTB.formattedUsedOfTotal(style: .decimal), "970 GB / 1.00 TB")
        let sharedGB = VolumeCapacity(totalBytes: 990_000_000_000, availableBytes: 20_000_000_000)
        XCTAssertEqual(sharedGB.formattedUsedOfTotal(style: .decimal), "970 / 990 GB")

        // IEC Binary units (GiB / TiB)
        let twoTiB = VolumeCapacity(
            totalBytes: 2 * 1024 * 1024 * 1024 * 1024,
            availableBytes: 512 * 1024 * 1024 * 1024
        )
        XCTAssertEqual(twoTiB.formattedUsedOfTotal(style: .binary), "1.50 / 2.00 TiB")
        XCTAssertEqual(twoTiB.formattedFree(style: .binary), "512 GiB free")
    }

    func testVolumeCapacityCombine() {
        let d1 = VolumeCapacity(totalBytes: 8_000_000_000_000, availableBytes: 2_000_000_000_000)
        let d2 = VolumeCapacity(totalBytes: 4_000_000_000_000, availableBytes: 1_000_000_000_000)
        let invalid = VolumeCapacity(totalBytes: 0, availableBytes: 0)

        let combined = VolumeCapacity.combine([d1, d2, invalid])
        XCTAssertEqual(combined?.totalBytes, 12_000_000_000_000)
        XCTAssertEqual(combined?.availableBytes, 3_000_000_000_000)
        XCTAssertEqual(combined?.usedBytes, 9_000_000_000_000)
        XCTAssertEqual(combined?.formattedUsedOfTotal(style: .decimal), "9.00 / 12.0 TB")
        XCTAssertEqual(combined?.usedPercentText, "75%")
        XCTAssertNil(VolumeCapacity.combine([invalid]))
        XCTAssertNil(VolumeCapacity.combine([]))
    }

    func testUpdateCheckerVersionComparisonAndParsing() {
        XCTAssertTrue(UpdateChecker.isNewer(releaseVersion: "1.3.0", than: "1.2.1"))
        XCTAssertTrue(UpdateChecker.isNewer(releaseVersion: "v1.2.2", than: "1.2.1"))
        XCTAssertTrue(UpdateChecker.isNewer(releaseVersion: "2.0.0", than: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer(releaseVersion: "1.2.1", than: "1.2.1"))
        XCTAssertFalse(UpdateChecker.isNewer(releaseVersion: "1.2.0", than: "1.2.1"))

        let json = """
        {
          "tag_name": "v1.3.0",
          "html_url": "https://github.com/musaandi/MountKeep/releases/tag/v1.3.0",
          "tarball_url": "https://api.github.com/repos/musaandi/MountKeep/tarball/v1.3.0",
          "body": "### Added\\n- Finder quick toggles",
          "published_at": "2026-11-23T20:00:00Z",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "MountKeep-v1.3.0.zip",
              "browser_download_url": "https://github.com/musaandi/MountKeep/releases/download/v1.3.0/MountKeep-v1.3.0.zip"
            }
          ]
        }
        """.data(using: .utf8)!

        let parsed = UpdateChecker.parseLatestRelease(from: json)
        XCTAssertEqual(parsed?.version, "1.3.0")
        XCTAssertEqual(parsed?.tagName, "v1.3.0")
        XCTAssertEqual(parsed?.releaseNotes, "### Added\n- Finder quick toggles")
        XCTAssertEqual(parsed?.releaseURL.absoluteString, "https://github.com/musaandi/MountKeep/releases/tag/v1.3.0")
        XCTAssertEqual(parsed?.assetName, "MountKeep-v1.3.0.zip")
        XCTAssertEqual(parsed?.assetDownloadURL?.absoluteString, "https://github.com/musaandi/MountKeep/releases/download/v1.3.0/MountKeep-v1.3.0.zip")
        XCTAssertEqual(parsed?.sourceTarballURL?.absoluteString, "https://api.github.com/repos/musaandi/MountKeep/tarball/v1.3.0")
        XCTAssertTrue(parsed?.canInstallInApp == true)

        let changelog = """
        # Changelog

        ## [1.3.1] - 2026-11-23
        ### Added
        - In-app changelog popup

        ## [1.3.0] - 2026-11-23
        ### Added
        - Finder quick toggles
        """
        XCTAssertEqual(
            UpdateChecker.extractChangelogSection(forVersion: "1.3.1", from: changelog),
            "### Added\n- In-app changelog popup"
        )
        XCTAssertNil(UpdateChecker.extractChangelogSection(forVersion: "9.9.9", from: changelog))

        let draftJSON = """
        {
          "tag_name": "v1.4.0",
          "html_url": "https://github.com/musaandi/MountKeep/releases/tag/v1.4.0",
          "draft": true,
          "prerelease": false
        }
        """.data(using: .utf8)!
        XCTAssertNil(UpdateChecker.parseLatestRelease(from: draftJSON))
    }

    func testRemotePowerSSHArgumentsAndSetupScript() throws {
        let server = ServerConfig(
            host: "workstation",
            username: "alice",
            sshShutdownEnabled: true
        )
        XCTAssertTrue(server.canRemoteShutdown)
        XCTAssertEqual(server.effectiveSSHUsername, "alice")
        XCTAssertEqual(server.effectiveSSHKeyPath, RemotePower.defaultKeyPath)

        let args = RemotePower.buildSSHArguments(
            host: server.host,
            username: server.effectiveSSHUsername,
            keyPath: "/tmp/test_key"
        )
        XCTAssertEqual(args[0], "-i")
        XCTAssertEqual(args[1], "/tmp/test_key")
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("alice@workstation"))
        XCTAssertEqual(args.last, "shutdown /s /t 5")

        let pub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey mountkeep-power"
        let restricted = RemotePower.restrictedAuthorizedKeyLine(publicKey: pub)
        XCTAssertTrue(restricted.hasPrefix(#"command="shutdown /s /t 5",no-port-forwarding"#))
        XCTAssertTrue(restricted.hasSuffix(pub))

        let script = RemotePower.windowsSetupScript(publicKey: pub)
        XCTAssertTrue(script.contains("OpenSSH.Server"))
        XCTAssertTrue(script.contains("administrators_authorized_keys"))
        XCTAssertTrue(script.contains("icacls.exe"))
        XCTAssertTrue(script.contains(pub))

        // Backward compatibility: older ServerConfig JSON without SSH keys decodes cleanly.
        let legacyJSON = #"{"host":"nas","username":"bob","shares":[]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: legacyJSON)
        XCTAssertFalse(decoded.sshShutdownEnabled)
        XCTAssertFalse(decoded.canRemoteShutdown)
        XCTAssertNil(decoded.sshUsername)
        XCTAssertNil(decoded.sshKeyPath)
    }

    func testHostSyncPolicyOnlineSyncTriggersAndNoOpSteadyState() {
        // Offline / waking / checking / unknown servers MUST trigger wakefulness sync on drive mount.
        XCTAssertTrue(HostSyncPolicy.needsOnlineSync(
            hostState: .offline, sshEnabled: true, sshReadiness: .hostOffline, hasOfflineStrike: false, isAway: false
        ))
        XCTAssertTrue(HostSyncPolicy.needsOnlineSync(
            hostState: .waking, sshEnabled: false, sshReadiness: nil, hasOfflineStrike: false, isAway: false
        ))
        XCTAssertTrue(HostSyncPolicy.needsOnlineSync(
            hostState: .unknown, sshEnabled: false, sshReadiness: nil, hasOfflineStrike: false, isAway: false
        ))

        // Online with a pending offline strike MUST sync immediately to clear the strike.
        XCTAssertTrue(HostSyncPolicy.needsOnlineSync(
            hostState: .online(ipAddress: "192.0.2.10"), sshEnabled: false, sshReadiness: nil, hasOfflineStrike: true, isAway: false
        ))

        // Online with stale SSH readiness (.hostOffline / nil / .checking) MUST refresh SSH.
        XCTAssertTrue(HostSyncPolicy.needsOnlineSync(
            hostState: .online(ipAddress: "192.0.2.10"), sshEnabled: true, sshReadiness: .hostOffline, hasOfflineStrike: false, isAway: false
        ))
        XCTAssertTrue(HostSyncPolicy.needsOnlineSync(
            hostState: .online(ipAddress: "192.0.2.10"), sshEnabled: true, sshReadiness: nil, hasOfflineStrike: false, isAway: false
        ))

        // Steady-state online & settled servers MUST be a no-op (zero extra probes / zero CPU).
        XCTAssertFalse(HostSyncPolicy.needsOnlineSync(
            hostState: .online(ipAddress: "192.0.2.10"), sshEnabled: false, sshReadiness: .disabled, hasOfflineStrike: false, isAway: false
        ))
        XCTAssertFalse(HostSyncPolicy.needsOnlineSync(
            hostState: .online(ipAddress: "192.0.2.10"), sshEnabled: true, sshReadiness: .ready, hasOfflineStrike: false, isAway: false
        ))
        XCTAssertFalse(HostSyncPolicy.needsOnlineSync(
            hostState: .online(ipAddress: "192.0.2.10"), sshEnabled: true, sshReadiness: .portClosed, hasOfflineStrike: false, isAway: false
        ))
        XCTAssertFalse(HostSyncPolicy.needsOnlineSync(
            hostState: .online(ipAddress: "192.0.2.10"), sshEnabled: true, sshReadiness: .missingLocalKey, hasOfflineStrike: false, isAway: false
        ))

        // Away or shutting down servers MUST never sync online on mount notifications.
        XCTAssertFalse(HostSyncPolicy.needsOnlineSync(
            hostState: .offline, sshEnabled: true, sshReadiness: .hostOffline, hasOfflineStrike: false, isAway: true
        ))
        XCTAssertFalse(HostSyncPolicy.needsOnlineSync(
            hostState: .shuttingDown, sshEnabled: true, sshReadiness: .ready, hasOfflineStrike: false, isAway: false
        ))
    }

    func testHostSyncPolicyTwoStrikeOfflineGuardAndPollingAttention() {
        let onlineState = HostReachabilityState.online(ipAddress: "192.0.2.20")

        // If any mounted share passes a health check despite TCP :445 failing, stay online with cached IP.
        let rescued = HostSyncPolicy.evaluateFailedHostProbe(
            previousState: onlineState,
            mountedShareCount: 3,
            anyMountedShareHealthy: true,
            currentStrikes: 1,
            primaryIP: nil,
            cachedIP: "192.0.2.20"
        )
        XCTAssertEqual(rescued, FailedHostProbeOutcome(nextHostState: onlineState, nextStrikes: 0, treatedAsReachable: true))

        // Strike 1 on an online server with mounted shares holds .online instead of flickering offline.
        let strike1 = HostSyncPolicy.evaluateFailedHostProbe(
            previousState: onlineState,
            mountedShareCount: 3,
            anyMountedShareHealthy: false,
            currentStrikes: 0,
            primaryIP: nil,
            cachedIP: "192.0.2.20"
        )
        XCTAssertEqual(strike1, FailedHostProbeOutcome(nextHostState: onlineState, nextStrikes: 1, treatedAsReachable: false))

        // Strike 2 confirms the host is offline.
        let strike2 = HostSyncPolicy.evaluateFailedHostProbe(
            previousState: onlineState,
            mountedShareCount: 3,
            anyMountedShareHealthy: false,
            currentStrikes: 1,
            primaryIP: nil,
            cachedIP: "192.0.2.20"
        )
        XCTAssertEqual(strike2, FailedHostProbeOutcome(nextHostState: .offline, nextStrikes: 0, treatedAsReachable: false))

        // Zero mounted shares flips offline immediately on first failed probe.
        let unmountedOffline = HostSyncPolicy.evaluateFailedHostProbe(
            previousState: onlineState,
            mountedShareCount: 0,
            anyMountedShareHealthy: false,
            currentStrikes: 0,
            primaryIP: nil,
            cachedIP: "192.0.2.20"
        )
        XCTAssertEqual(unmountedOffline, FailedHostProbeOutcome(nextHostState: .offline, nextStrikes: 0, treatedAsReachable: false))

        // Shutting down flips straight to offline once TCP :445 drops.
        let shutdownDone = HostSyncPolicy.evaluateFailedHostProbe(
            previousState: .shuttingDown,
            mountedShareCount: 0,
            anyMountedShareHealthy: false,
            currentStrikes: 0,
            primaryIP: nil,
            cachedIP: nil
        )
        XCTAssertEqual(shutdownDone, FailedHostProbeOutcome(nextHostState: .offline, nextStrikes: 0, treatedAsReachable: false))

        // Polling attention: steady-state mounted + online drops to idle; pending strike or mismatch stays active.
        let mountedShares: [ShareRuntimeState] = [.mounted(mountPoint: "/Volumes/Data")]
        XCTAssertFalse(HostSyncPolicy.serverNeedsAttention(
            enabledShareStates: mountedShares, hostState: onlineState, hasOfflineStrike: false
        ))
        XCTAssertTrue(HostSyncPolicy.serverNeedsAttention(
            enabledShareStates: mountedShares, hostState: onlineState, hasOfflineStrike: true
        ))
        XCTAssertTrue(HostSyncPolicy.serverNeedsAttention(
            enabledShareStates: mountedShares, hostState: .offline, hasOfflineStrike: false
        ))
        XCTAssertFalse(HostSyncPolicy.serverNeedsAttention(
            enabledShareStates: [.manuallyUnmounted], hostState: .offline, hasOfflineStrike: false
        ))
    }
}
