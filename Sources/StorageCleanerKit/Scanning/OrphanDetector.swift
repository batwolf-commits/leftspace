import Foundation

/// Finds files left behind by apps that are no longer installed — the classic
/// "I deleted the app but its data is still eating space, and Finder never shows
/// it" problem.
///
/// Strategy (deliberately conservative to avoid false positives):
///  - Look only in the standard per-user support locations.
///  - Consider only entries whose name is a *reverse-DNS bundle identifier*
///    (e.g. `com.acme.Widget`, `com.acme.Widget.plist`). Folders named after a
///    vendor or product (`Google`, `Steam`) are ambiguous and are left alone.
///  - Skip Apple's own identifiers (`com.apple.*`) — those belong to the OS, not
///    to a third-party app the user removed.
///  - Flag an entry only when its bundle ID is absent from `InstalledAppsIndex`.
///
/// Everything found is `.caution` (never pre-selected) and still passes through
/// `ProtectedPaths` at deletion time.
public struct OrphanDetector: Sendable {

    /// Category ID used for all orphan items, so the UI can group them.
    public static let categoryID = "leftovers.orphaned"

    public static let category = CleanupCategory(
        id: categoryID,
        group: .leftovers,
        title: "Leftovers from removed apps",
        explanation: "Support files, caches, and preferences belonging to apps that are no longer installed. Safe to remove unless you plan to reinstall and want the old settings back.",
        safety: .caution,
        roots: [],            // computed dynamically; not a static path rule
        contentsOnly: true
    )

    private let sizer = SizeCalculator()

    public init() {}

    /// Per-user directories whose immediate children are named by bundle ID.
    static func containerRoots(home: URL) -> [URL] {
        [
            "Library/Application Support",
            "Library/Caches",
            "Library/Containers",
            "Library/HTTPStorages",
            "Library/WebKit",
            "Library/Preferences",
            "Library/Saved Application State",
            "Library/Logs",
        ].map { home.appendingPathComponent($0) }
    }

    /// Detect orphaned leftovers. `installed` should come from
    /// `InstalledAppsIndex.build()`.
    public func detect(
        installed: InstalledAppsIndex,
        fileManager: FileManager = .default
    ) -> CategoryResult {
        let home = fileManager.homeDirectoryForCurrentUser
        var items: [ScanItem] = []
        var seenPaths = Set<String>()

        for root in Self.containerRoots(home: home) {
            guard let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { continue }

            for child in children {
                guard let bundleID = Self.bundleID(from: child.lastPathComponent) else { continue }
                if Self.isSystemOwned(bundleID) { continue }
                // `covers` also spares helpers/extensions of installed apps.
                if installed.covers(bundleID) { continue }
                // De-dupe if two roots somehow resolve to the same path.
                if !seenPaths.insert(child.path).inserted { continue }

                let size = sizer.directoryAllocatedSize(child)
                if size > 0 {
                    items.append(ScanItem(url: child, sizeBytes: size, categoryID: Self.categoryID))
                }
            }
        }

        items.sort { $0.sizeBytes > $1.sizeBytes }
        return CategoryResult(category: Self.category, items: items)
    }

    // MARK: - Heuristics

    /// Reverse-DNS bundle IDs begin with a top-level domain. Requiring the first
    /// label to be a real TLD is a strong precision filter: it rejects folders that
    /// merely look ID-ish, most importantly domain-order names like `zoom.us`
    /// (whose real bundle ID is `us.zoom.xos`) and generic files like
    /// `default.store`. It errs toward NOT flagging — the safe direction.
    static let knownTLDs: Set<String> = [
        "com", "org", "net", "io", "co", "ai", "app", "dev", "me", "us", "uk",
        "de", "fr", "it", "jp", "cn", "ca", "au", "nl", "se", "no", "es", "ch",
        "ru", "br", "in", "eu", "info", "biz", "tv", "gg", "xyz", "cloud", "sh",
        "edu", "gov", "int",
    ]

    /// Extract a bundle identifier from a file/folder name, or nil if the name
    /// doesn't look like a genuine reverse-DNS identifier. Strips known trailing
    /// extensions first.
    static func bundleID(from name: String) -> String? {
        var base = name
        for ext in [".savedState", ".plist", ".binarycookies"] {
            if base.hasSuffix(ext) { base = String(base.dropLast(ext.count)); break }
        }
        // At least three labels (tld.vendor.product) — two-label names are too
        // often generic files (`default.store`, `foo.bar`) to trust.
        let labels = base.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3 else { return nil }

        // First label must be a real TLD (reverse-DNS convention).
        guard Self.knownTLDs.contains(labels[0].lowercased()) else { return nil }

        let labelChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        for label in labels {
            if label.isEmpty { return nil }
            if label.unicodeScalars.contains(where: { !labelChars.contains($0) }) { return nil }
        }
        return base
    }

    /// Identifiers owned by macOS itself — never treated as removable leftovers.
    static func isSystemOwned(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        return lower.hasPrefix("com.apple.")
            || lower.hasPrefix("group.com.apple.")
            || lower == "systempolicyconfiguration"
    }
}
