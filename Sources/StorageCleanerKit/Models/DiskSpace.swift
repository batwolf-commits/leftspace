import Foundation

/// Snapshot of the boot volume's capacity, for the menu bar summary and graphs.
///
/// `free` uses `volumeAvailableCapacityForImportantUsage`, which is what macOS
/// itself reports to the user (it accounts for purgeable space) — so our number
/// matches Finder's "Available" rather than the raw POSIX free blocks.
public struct DiskSpace: Sendable, Equatable {
    public let totalBytes: Int64
    public let freeBytes: Int64

    public init(totalBytes: Int64, freeBytes: Int64) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }

    public var usedBytes: Int64 { max(0, totalBytes - freeBytes) }

    public var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }

    public static func current(for url: URL = URL(fileURLWithPath: "/")) -> DiskSpace {
        let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        return DiskSpace(totalBytes: total, freeBytes: free)
    }
}
