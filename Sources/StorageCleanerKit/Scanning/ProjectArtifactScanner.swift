import Foundation

/// Finds regenerable build/dependency folders sitting inside the user's projects —
/// the space developers actually reach for tools (npkill, `docker prune`, manual
/// `rm -rf node_modules`) to reclaim. Unlike the global caches, these live next to
/// source code and are the biggest, most-forgotten space hogs on a dev machine.
///
/// Conservative by design:
///  - Only scans dedicated project roots (`~/Developer`, `~/Projects`, `~/code`…),
///    never protected areas like `~/Documents` (the safety guard would refuse them
///    anyway) and never the whole home directory.
///  - Only recognizes clearly regenerable folder names; `target` is only counted
///    when a `Cargo.toml` sits beside it (avoids nuking unrelated "target" dirs).
///  - Never descends into a matched folder or into `.git`.
///  - Reports staleness (last-changed) so the user can spot what's truly dead.
///
/// Everything found is `.caution` (never pre-selected) and still passes through
/// `ProtectedPaths` at deletion time.
public struct ProjectArtifactScanner: Sendable {

    public static let categoryID = "dev.project-artifacts"

    public static let category = CleanupCategory(
        id: categoryID,
        group: .developer,
        title: "Project build artifacts",
        explanation: "Regenerable folders inside your projects — dependencies and build output. Restore any of them with a reinstall or rebuild.",
        safety: .caution,
        roots: []
    )

    /// A recognizable artifact folder and how to describe it.
    struct Rule: Sendable {
        let name: String
        let label: String
        /// If set, only match when this file exists in the same parent directory.
        let requiresSibling: String?
    }

    /// The exact folder basenames this scanner recognizes. `ProtectedPaths` uses
    /// this to allow these (and only these) to be removed from otherwise-protected
    /// user-content areas like ~/Documents.
    public static var allowedArtifactNames: Set<String> { Set(rules.map(\.name)) }

    static let rules: [Rule] = [
        Rule(name: "node_modules", label: "npm packages", requiresSibling: nil),
        Rule(name: ".venv", label: "Python virtualenv", requiresSibling: nil),
        Rule(name: "venv", label: "Python virtualenv", requiresSibling: nil),
        Rule(name: "Pods", label: "CocoaPods", requiresSibling: "Podfile"),
        Rule(name: "target", label: "Rust build", requiresSibling: "Cargo.toml"),
        Rule(name: ".next", label: "Next.js build", requiresSibling: nil),
        Rule(name: ".nuxt", label: "Nuxt build", requiresSibling: nil),
        Rule(name: ".svelte-kit", label: "SvelteKit build", requiresSibling: nil),
        Rule(name: ".turbo", label: "Turbo cache", requiresSibling: nil),
        Rule(name: ".parcel-cache", label: "Parcel cache", requiresSibling: nil),
        Rule(name: ".gradle", label: "Gradle project cache", requiresSibling: nil),
    ]

    /// Directories we refuse to descend into while searching.
    static let pruneNames: Set<String> = ["node_modules", ".git", "Library", ".Trash"]

    /// Only surface artifacts at least this large — keeps the list meaningful.
    static let minSizeBytes: Int64 = 20 * 1024 * 1024   // 20 MB
    static let maxDepth = 7

    private let sizer = SizeCalculator()

    public init() {}

    /// Dedicated developer folders — safe to scan without tripping macOS's
    /// Documents/Desktop/Downloads privacy prompts.
    static let devFolderNames = ["Developer", "Projects", "Project", "code", "Code",
                                 "src", "repos", "Repos", "git", "workspace",
                                 "Workspace", "Sites", "dev", "go/src"]

    /// Personal folders macOS gates behind an access prompt. Scanned only when the
    /// user explicitly opts in, so a default run stays prompt-free like AppCleaner.
    static let personalFolderNames = ["Documents", "Desktop", "Downloads"]

    /// Candidate project roots (only those that exist). Personal folders are
    /// included only when opted in. Deletion of anything found is still gated by
    /// `ProtectedPaths.checkArtifact`, which permits only recognized artifacts.
    static func projectRoots(home: URL, includePersonalFolders: Bool) -> [URL] {
        var names = devFolderNames
        if includePersonalFolders { names += personalFolderNames }
        return names.map { home.appendingPathComponent($0) }
    }

    public func detect(includePersonalFolders: Bool = false,
                       fileManager: FileManager = .default) -> CategoryResult {
        let home = fileManager.homeDirectoryForCurrentUser
        var items: [ScanItem] = []
        var seen = Set<String>()

        for root in Self.projectRoots(home: home, includePersonalFolders: includePersonalFolders)
            where fileManager.fileExists(atPath: root.path) {
            scan(root: root, fileManager: fileManager, items: &items, seen: &seen)
        }

        items.sort { $0.sizeBytes > $1.sizeBytes }
        return CategoryResult(category: Self.category, items: items)
    }

    private func scan(root: URL, fileManager: FileManager, items: inout [ScanItem], seen: inout Set<String>) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let en = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return }

        let rootDepth = root.pathComponents.count
        for case let url as URL in en {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }
            let name = url.lastPathComponent

            // Depth guard.
            if url.pathComponents.count - rootDepth > Self.maxDepth {
                en.skipDescendants(); continue
            }
            // Never wander into these.
            if Self.pruneNames.contains(name) {
                if let item = artifactItem(at: url, name: name, modified: values?.contentModificationDate,
                                           fileManager: fileManager), seen.insert(url.path).inserted {
                    items.append(item)
                }
                en.skipDescendants()
                continue
            }
            // Other recognized artifacts (don't descend into them either).
            if let item = artifactItem(at: url, name: name, modified: values?.contentModificationDate,
                                       fileManager: fileManager) {
                if seen.insert(url.path).inserted { items.append(item) }
                en.skipDescendants()
            }
        }
    }

    /// Build a `ScanItem` if `name` matches a rule and clears the size threshold.
    private func artifactItem(at url: URL, name: String, modified: Date?, fileManager: FileManager) -> ScanItem? {
        guard let rule = Self.rules.first(where: { $0.name == name }) else { return nil }
        if let sibling = rule.requiresSibling {
            let siblingPath = url.deletingLastPathComponent().appendingPathComponent(sibling)
            guard fileManager.fileExists(atPath: siblingPath.path) else { return nil }
        }
        let size = sizer.directoryAllocatedSize(url)
        guard size >= Self.minSizeBytes else { return nil }

        let project = url.deletingLastPathComponent().lastPathComponent
        var detail = "\(rule.label) in “\(project)”"
        if let modified {
            detail += " · last changed \(Self.relative(modified))"
        }
        return ScanItem(url: url, sizeBytes: size, categoryID: Self.categoryID, detail: detail)
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
