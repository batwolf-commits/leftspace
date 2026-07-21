import Foundation

/// A high-level grouping shown in the UI (e.g. "Developer caches", "System junk").
public enum CategoryGroup: String, Codable, Sendable, CaseIterable {
    case developer      // Tier 1a — the headline feature
    case userCaches     // Tier 1b
    case logs
    case trash
    case appState
    case browser
    case leftovers      // Tier 2 — orphaned app data
    case backups        // Tier 2

    public var title: String {
        switch self {
        case .developer:  return "Developer caches"
        case .userCaches: return "Application caches"
        case .logs:       return "Logs"
        case .trash:      return "Trash"
        case .appState:   return "Saved application state"
        case .browser:    return "Browser caches"
        case .leftovers:  return "Leftovers from removed apps"
        case .backups:    return "Device backups"
        }
    }
}

/// A single, declarative cleanup rule. The scanning engine treats these as data:
/// adding a new cleanable location means appending a `CleanupCategory`, never
/// editing the scanner.
///
/// A category resolves to one or more concrete directories on disk. `roots` are
/// expanded from `~` at scan time. When `contentsOnly` is true, we clean the
/// *children* of each root (leaving the cache directory itself in place, which is
/// what tools expect); when false, the roots themselves are removal candidates.
public struct CleanupCategory: Identifiable, Codable, Sendable {
    public let id: String
    public let group: CategoryGroup
    public let title: String
    /// Plain-English reason this is safe to remove — shown verbatim to the user.
    public let explanation: String
    public let safety: SafetyLevel
    /// True if removal needs administrator/root privileges (deferred to post-MVP;
    /// such categories are surfaced but disabled in v1).
    public let requiresAdmin: Bool
    /// `~`-relative or absolute directory paths this category targets.
    public let roots: [String]
    /// Clean the children of each root rather than the root itself.
    public let contentsOnly: Bool
    /// Child names to never touch within a root (e.g. keep a lockfile).
    public let excludes: [String]

    public init(
        id: String,
        group: CategoryGroup,
        title: String,
        explanation: String,
        safety: SafetyLevel,
        requiresAdmin: Bool = false,
        roots: [String],
        contentsOnly: Bool = true,
        excludes: [String] = []
    ) {
        self.id = id
        self.group = group
        self.title = title
        self.explanation = explanation
        self.safety = safety
        self.requiresAdmin = requiresAdmin
        self.roots = roots
        self.contentsOnly = contentsOnly
        self.excludes = excludes
    }

    /// Roots expanded to absolute URLs, filtered to those that actually exist.
    public func existingRootURLs(fileManager: FileManager = .default) -> [URL] {
        roots.compactMap { raw -> URL? in
            let expanded = (raw as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
    }
}
