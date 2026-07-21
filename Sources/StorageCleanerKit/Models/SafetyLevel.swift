import Foundation

/// How confident we are that removing a category's contents is harmless.
///
/// This drives UI presentation (what is pre-selected) and the confirmation
/// friction we put in front of the user. It is advisory — the hard guarantee
/// against catastrophe lives in `ProtectedPaths`, not here.
public enum SafetyLevel: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Regenerated automatically on next use; removing it only costs a re-download
    /// or re-computation. Safe to pre-select. (e.g. package-manager caches, logs.)
    case safe = 0

    /// Almost always fine, but removal has a visible cost (re-index, slower first
    /// launch) or a narrow chance of surprising the user. Selectable, not pre-selected.
    case caution = 1

    /// Real blast radius if the user is wrong (device backups, large user files).
    /// Never pre-selected; always requires an explicit, informed choice.
    case risky = 2

    public static func < (lhs: SafetyLevel, rhs: SafetyLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Whether this level should be checked by default in the UI.
    public var isPreselectedByDefault: Bool { self == .safe }

    public var label: String {
        switch self {
        case .safe:    return "Safe"
        case .caution: return "Review"
        case .risky:   return "Risky"
        }
    }
}
