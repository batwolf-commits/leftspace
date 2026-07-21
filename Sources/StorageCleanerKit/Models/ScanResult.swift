import Foundation

/// One concrete on-disk entry the scanner found and considers a removal candidate.
public struct ScanItem: Identifiable, Sendable, Hashable {
    public var id: String { url.path }
    public let url: URL
    /// On-disk allocated size in bytes (what the user actually frees).
    public let sizeBytes: Int64
    /// The category rule that produced this item.
    public let categoryID: String
    /// Optional human context shown in the detail view (e.g. "in my-app · last
    /// changed 3 months ago"). `nil` for plain cache items.
    public let detail: String?

    public init(url: URL, sizeBytes: Int64, categoryID: String, detail: String? = nil) {
        self.url = url
        self.sizeBytes = sizeBytes
        self.categoryID = categoryID
        self.detail = detail
    }
}

/// Aggregated scan output for a single category.
public struct CategoryResult: Identifiable, Sendable {
    public var id: String { category.id }
    public let category: CleanupCategory
    public let items: [ScanItem]

    public init(category: CleanupCategory, items: [ScanItem]) {
        self.category = category
        self.items = items
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
    public var itemCount: Int { items.count }
}

/// The full result of a scan across all categories.
public struct ScanResult: Sendable {
    public let categories: [CategoryResult]
    public let scannedAt: Date
    /// Categories that were skipped because their roots were unreadable
    /// (usually: Full Disk Access not granted).
    public let unreadableCategoryIDs: [String]

    public init(categories: [CategoryResult], scannedAt: Date = Date(), unreadableCategoryIDs: [String] = []) {
        self.categories = categories
        self.scannedAt = scannedAt
        self.unreadableCategoryIDs = unreadableCategoryIDs
    }

    public var totalReclaimableBytes: Int64 {
        categories.reduce(0) { $0 + $1.totalBytes }
    }

    /// Categories with at least one item, largest first.
    public var nonEmptyCategories: [CategoryResult] {
        categories.filter { !$0.items.isEmpty }
            .sorted { $0.totalBytes > $1.totalBytes }
    }
}

public enum ByteFormat {
    /// Human-readable size using the same base macOS Finder uses (decimal, GB not GiB).
    public static func string(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: bytes)
    }
}
