import Foundation

public enum StorageUnitStyle: String, Codable, CaseIterable, Sendable {
    case binaryHuman // Base 1024 with human labels (KB, MB, GB, TB) — matches Windows Explorer
    case binary      // Base 1024 with IEC labels (KiB, MiB, GiB, TiB)
    case decimal     // Base 1000 (KB, MB, GB, TB) — macOS Finder & drive vendor labels

    public var displayName: String {
        switch self {
        case .binaryHuman: return "Base-2 (GB / TB — Windows)"
        case .binary: return "IEC Binary (GiB / TiB)"
        case .decimal: return "Decimal (GB / TB — macOS)"
        }
    }

    public var base: Double {
        switch self {
        case .binaryHuman, .binary: return 1024.0
        case .decimal: return 1000.0
        }
    }

    public var units: [String] {
        switch self {
        case .binaryHuman, .decimal: return ["B", "KB", "MB", "GB", "TB", "PB"]
        case .binary: return ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
        }
    }
}

public enum UsageSeverity: Equatable, Sendable {
    case normal   // < 75%
    case warning  // 75% ..< 90%
    case critical // >= 90%
}

public struct VolumeCapacity: Equatable, Hashable, Sendable {
    public let totalBytes: UInt64
    public let availableBytes: UInt64

    public init(totalBytes: UInt64, availableBytes: UInt64) {
        self.totalBytes = totalBytes
        self.availableBytes = min(availableBytes, totalBytes)
    }

    public var usedBytes: UInt64 {
        totalBytes >= availableBytes ? (totalBytes - availableBytes) : 0
    }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    public var severity: UsageSeverity {
        let fraction = usedFraction
        if fraction >= 0.90 { return .critical }
        if fraction >= 0.75 { return .warning }
        return .normal
    }

    public var usedPercentText: String {
        guard totalBytes > 0, usedBytes > 0 else { return "0%" }
        if availableBytes == 0 { return "100%" }
        let pct = usedFraction * 100.0
        if pct < 0.5 { return "<1%" }
        return "\(min(99, max(1, Int(pct.rounded()))))%"
    }

    /// Aggregates multiple valid capacities (`totalBytes > 0`) into a single combined capacity.
    public static func combine(_ capacities: [VolumeCapacity]) -> VolumeCapacity? {
        let valid = capacities.filter { $0.totalBytes > 0 }
        guard !valid.isEmpty else { return nil }

        var total: UInt64 = 0
        var avail: UInt64 = 0
        for cap in valid {
            let (nextTotal, totalOverflow) = total.addingReportingOverflow(cap.totalBytes)
            total = totalOverflow ? UInt64.max : nextTotal
            let (nextAvail, availOverflow) = avail.addingReportingOverflow(cap.availableBytes)
            avail = availOverflow ? UInt64.max : nextAvail
        }
        return VolumeCapacity(totalBytes: total, availableBytes: avail)
    }

    /// Formats a byte count into `(number, unit)` using adaptive industry-standard precision:
    /// `< 10` -> 2 decimals (`7.94 TB`), `10..<100` -> 1 decimal (`63.1 GB`), `>= 100` -> 0 decimals (`162 GB`).
    public static func splitFormatted(_ bytes: UInt64, style: StorageUnitStyle = .binaryHuman) -> (value: String, unit: String) {
        let units = style.units
        let base = style.base
        guard bytes > 0 else { return ("0", units[0]) }

        var value = Double(bytes)
        var unitIndex = 0
        while value >= base && unitIndex < units.count - 1 {
            value /= base
            unitIndex += 1
        }

        // Avoid rounding to "1000 GB" (or "1024 GiB") when stepping up to the next unit is cleaner.
        if unitIndex < units.count - 1 && value >= (base - 0.5) {
            value /= base
            unitIndex += 1
        }

        let formattedNumber: String
        if unitIndex == 0 {
            formattedNumber = String(format: "%.0f", value)
        } else if value < 10.0 {
            formattedNumber = String(format: "%.2f", value)
        } else if value < 100.0 {
            formattedNumber = String(format: "%.1f", value)
        } else {
            formattedNumber = String(format: "%.0f", value)
        }
        return (formattedNumber, units[unitIndex])
    }

    public static func formatBytes(_ bytes: UInt64, style: StorageUnitStyle = .binaryHuman) -> String {
        let parts = splitFormatted(bytes, style: style)
        return "\(parts.value) \(parts.unit)"
    }

    /// Formats consumed / total concisely, sharing the trailing unit when both match:
    /// e.g. `7.22 / 7.28 TB` or `151 GB / 1.82 TB`.
    public func formattedUsedOfTotal(style: StorageUnitStyle = .binaryHuman) -> String {
        let used = Self.splitFormatted(usedBytes, style: style)
        let total = Self.splitFormatted(totalBytes, style: style)
        if used.unit == total.unit {
            return "\(used.value) / \(total.value) \(total.unit)"
        }
        return "\(used.value) \(used.unit) / \(total.value) \(total.unit)"
    }

    public func formattedFree(style: StorageUnitStyle = .binaryHuman) -> String {
        "\(Self.formatBytes(availableBytes, style: style)) free"
    }
}
