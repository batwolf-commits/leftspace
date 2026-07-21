import Foundation

/// The last line of defence against ever deleting something irreplaceable.
///
/// Every candidate URL passes through `check(_:)` immediately before deletion.
/// This guard is intentionally paranoid and independent of the category catalog:
/// even if a bad rule is authored, or a symlink points somewhere unexpected, a
/// protected path is refused. It errs toward refusing.
///
/// Design notes:
///  - Paths are compared after resolving symlinks, so a symlink inside a cache
///    that points at `~/Documents` cannot be used to escape the guard.
///  - Comparison is boundary-aware: `/Users/bob/Documents` protects
///    `/Users/bob/Documents/x` but not `/Users/bob/DocumentsOld`.
public struct ProtectedPaths: Sendable {

    public enum Verdict: Sendable, Equatable {
        case allowed
        case refused(reason: String)

        public var isAllowed: Bool { if case .allowed = self { return true }; return false }
    }

    /// Always refused — system dirs and irreplaceable user data.
    private let hardRoots: [String]
    /// User content (Documents/Desktop/Downloads). Refused for normal cleaning,
    /// but recognized regenerable artifact folders may be removed from here.
    private let softRoots: [String]
    private let homeURL: URL

    public init(fileManager: FileManager = .default) {
        let home = fileManager.homeDirectoryForCurrentUser
        self.homeURL = home
        let h = home.path

        // Absolute directories that must never be targeted, nor any descendant.
        // Note: the volume root "/" is handled as an exact-match refusal in
        // `check(_:)` — it must NOT go in this list, since every path is a
        // descendant of "/".
        var hard: [String] = [
            "/System",
            "/Library",             // system-level Library (root-owned; out of MVP scope)
            "/Applications",
            "/usr", "/bin", "/sbin", "/opt", "/etc", "/var", "/private/etc", "/cores",
            "/Users/Shared",
        ]

        // Per-user locations holding irreplaceable data — always refused, even for
        // project artifacts (you'd never keep node_modules in your Photos library).
        let userHard = [
            "Pictures", "Movies", "Music", "Public", "Applications",
            "Library/Mobile Documents",            // iCloud Drive
            "Library/CloudStorage",                // iCloud/Dropbox/OneDrive mounts
            "Library/Photos", "Pictures/Photos Library.photoslibrary",
            "Library/Keychains",
            "Library/Messages",
            "Library/Mail",                        // local mail store
            "Library/Application Support/AddressBook",
            "Library/Application Support/MobileSync", // device backups
        ]
        hard.append(contentsOf: userHard.map { h + "/" + $0 })
        self.hardRoots = hard.map { Self.normalize($0) }

        // User content: protected for general cleaning, but projects commonly live
        // here, so `checkArtifact` allows recognized artifact folders through.
        self.softRoots = ["Documents", "Desktop", "Downloads"]
            .map { Self.normalize(h + "/" + $0) }
    }

    /// Decide whether `url` may be removed. Call this for every general candidate.
    public func check(_ url: URL) -> Verdict {
        let resolved = Self.normalize(url.resolvingSymlinksInPath().path)
        if let base = baseRefusal(resolved, lastComponent: url.lastPathComponent) {
            return base
        }
        // Normal cleaning also protects all user-content roots.
        if let soft = refusal(resolved, against: softRoots) { return soft }
        return .allowed
    }

    /// Like `check`, but for recognized project artifacts (node_modules, .venv…).
    /// Hard-protected locations are still refused; user-content areas
    /// (Documents/Desktop/Downloads) are permitted ONLY when the folder's name is a
    /// known regenerable artifact — everything else there stays protected.
    public func checkArtifact(_ url: URL) -> Verdict {
        let resolved = Self.normalize(url.resolvingSymlinksInPath().path)
        if let base = baseRefusal(resolved, lastComponent: url.lastPathComponent) {
            return base
        }
        // Only genuine artifact folders may be removed from user content.
        if !ProjectArtifactScanner.allowedArtifactNames.contains(url.lastPathComponent) {
            if let soft = refusal(resolved, against: softRoots) { return soft }
        }
        return .allowed
    }

    // MARK: - Shared refusal logic

    /// Refusals that apply regardless of mode: home/volume root and hard roots.
    private func baseRefusal(_ resolved: String, lastComponent: String) -> Verdict? {
        if resolved == Self.normalize(homeURL.path) {
            return .refused(reason: "This is your home folder.")
        }
        if resolved == "/" || resolved.isEmpty {
            return .refused(reason: "This is the system root.")
        }
        return refusal(resolved, against: hardRoots, lastComponent: lastComponent)
    }

    /// Refuse if `resolved` equals, is inside, or is an ancestor of any given root.
    private func refusal(_ resolved: String, against roots: [String], lastComponent: String = "") -> Verdict? {
        for root in roots {
            if resolved == root {
                return .refused(reason: "\(lastComponent.isEmpty ? "This" : lastComponent) is a protected location.")
            }
            if Self.isDescendant(resolved, of: root) {
                return .refused(reason: "Inside protected location \(root).")
            }
            // Refuse if the candidate is an *ancestor* of a protected root —
            // deleting it would take the protected location with it.
            if Self.isDescendant(root, of: resolved) {
                return .refused(reason: "Removing this would also remove \(root).")
            }
        }
        return nil
    }

    // MARK: - Path helpers

    /// Collapse duplicate slashes and strip a trailing slash (except for "/").
    static func normalize(_ path: String) -> String {
        let std = (path as NSString).standardizingPath
        if std.count > 1 && std.hasSuffix("/") { return String(std.dropLast()) }
        return std
    }

    /// True when `path` is strictly inside `ancestor`, respecting path boundaries.
    static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        guard path != ancestor else { return false }
        let prefix = ancestor == "/" ? "/" : ancestor + "/"
        return path.hasPrefix(prefix)
    }
}
