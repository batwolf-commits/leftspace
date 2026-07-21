import Foundation

/// Progress callback payload, emitted as each category finishes scanning.
public struct ScanProgress: Sendable {
    public let completedCategories: Int
    public let totalCategories: Int
    public let currentCategoryTitle: String
    public let bytesSoFar: Int64
}

/// Scans the catalog concurrently and produces a `ScanResult`.
///
/// Each category is scanned in its own child task; within a category we build one
/// `ScanItem` per top-level removal candidate (a child of each root when
/// `contentsOnly`, otherwise the root itself), sized recursively. Producing items
/// at the top level — rather than per file — keeps the UI legible ("Homebrew:
/// 2.6 GB") and makes deletion a small number of trash operations.
public actor Scanner {

    private let sizer = SizeCalculator()

    public init() {}

    public func scan(
        categories: [CleanupCategory] = CategoryCatalog.all,
        includeOrphans: Bool = true,
        includeProjects: Bool = true,
        includePersonalFolders: Bool = false,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async -> ScanResult {
        var results: [CategoryResult] = []
        var unreadable: [String] = []
        // Orphan + project detection are extra logical "locations" in the count.
        let total = categories.count + (includeOrphans ? 1 : 0) + (includeProjects ? 1 : 0)
        var completed = 0
        var runningBytes: Int64 = 0

        // Scan categories concurrently, but bound the fan-out so we don't spawn a
        // task storm on a machine with dozens of rules.
        await withTaskGroup(of: (CategoryResult, Bool).self) { group in
            for category in categories {
                group.addTask { [sizer] in
                    // FileManager.default is a thread-safe shared instance; each
                    // task uses it directly rather than capturing a non-Sendable one.
                    Self.scanCategory(category, sizer: sizer, fileManager: .default)
                }
            }
            for await (result, wasReadable) in group {
                completed += 1
                runningBytes += result.totalBytes
                if !wasReadable { unreadable.append(result.category.id) }
                results.append(result)
                progress?(ScanProgress(
                    completedCategories: completed,
                    totalCategories: total,
                    currentCategoryTitle: result.category.title,
                    bytesSoFar: runningBytes
                ))
            }
        }

        // Stable display order: keep catalog order.
        let order = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($1.id, $0) })
        results.sort { (order[$0.category.id] ?? 0) < (order[$1.category.id] ?? 0) }

        // Orphaned-app leftovers: computed separately since its "roots" depend on
        // which apps are installed. Appended last so it sits below the fixed rules.
        if includeOrphans {
            let orphanResult = Self.scanOrphans()
            completed += 1
            runningBytes += orphanResult.totalBytes
            progress?(ScanProgress(
                completedCategories: completed,
                totalCategories: total,
                currentCategoryTitle: orphanResult.category.title,
                bytesSoFar: runningBytes
            ))
            results.append(orphanResult)
        }

        // Project build artifacts (node_modules, virtualenvs, build caches).
        if includeProjects {
            let projectResult = Self.scanProjects(includePersonalFolders: includePersonalFolders)
            completed += 1
            runningBytes += projectResult.totalBytes
            progress?(ScanProgress(
                completedCategories: completed,
                totalCategories: total,
                currentCategoryTitle: projectResult.category.title,
                bytesSoFar: runningBytes
            ))
            results.append(projectResult)
        }

        return ScanResult(categories: results, unreadableCategoryIDs: unreadable)
    }

    /// Build the installed-apps index and run orphan detection. Kept `nonisolated`
    /// and using `FileManager.default` so it can run off the actor cheaply.
    nonisolated static func scanOrphans() -> CategoryResult {
        let installed = InstalledAppsIndex.build()
        return OrphanDetector().detect(installed: installed)
    }

    nonisolated static func scanProjects(includePersonalFolders: Bool = false) -> CategoryResult {
        ProjectArtifactScanner().detect(includePersonalFolders: includePersonalFolders)
    }

    /// Scan a single category. Returns the result plus whether its roots were
    /// readable (false → likely needs Full Disk Access).
    nonisolated static func scanCategory(
        _ category: CleanupCategory,
        sizer: SizeCalculator,
        fileManager: FileManager
    ) -> (CategoryResult, Bool) {
        var items: [ScanItem] = []
        var readable = true

        for root in category.existingRootURLs(fileManager: fileManager) {
            if category.contentsOnly {
                guard let children = try? fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [] // include hidden — caches use dotfiles
                ) else {
                    // Root exists but we couldn't list it → permissions.
                    readable = false
                    continue
                }
                for child in children {
                    if category.excludes.contains(child.lastPathComponent) { continue }
                    let size = sizer.directoryAllocatedSize(child)
                    if size > 0 {
                        items.append(ScanItem(url: child, sizeBytes: size, categoryID: category.id))
                    }
                }
            } else {
                let size = sizer.directoryAllocatedSize(root)
                if size > 0 {
                    items.append(ScanItem(url: root, sizeBytes: size, categoryID: category.id))
                }
            }
        }

        // Only the largest items matter to the user; sort descending.
        items.sort { $0.sizeBytes > $1.sizeBytes }
        return (CategoryResult(category: category, items: items), readable)
    }
}
