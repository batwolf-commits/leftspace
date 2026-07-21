import Foundation

/// The declarative set of cleanup rules for v1. Everything the scanner knows how
/// to clean is listed here as data. Order within `all` is the default display order.
public enum CategoryCatalog {

    public static let all: [CleanupCategory] = tier1a_developer + tier1b_general

    // MARK: - Tier 1a — Developer caches (headline feature)

    public static let tier1a_developer: [CleanupCategory] = [
        CleanupCategory(
            id: "dev.npm",
            group: .developer,
            title: "npm cache",
            explanation: "Downloaded npm packages. npm re-downloads anything it needs on the next install.",
            safety: .safe,
            roots: ["~/.npm/_cacache"],
            contentsOnly: true
        ),
        CleanupCategory(
            id: "dev.bun",
            group: .developer,
            title: "Bun cache",
            explanation: "Bun's global install cache. Rebuilt automatically when you next install packages.",
            safety: .safe,
            roots: ["~/.bun/install/cache"]
        ),
        CleanupCategory(
            id: "dev.yarn",
            group: .developer,
            title: "Yarn cache",
            explanation: "Yarn's package cache. Repopulated on the next install.",
            safety: .safe,
            roots: ["~/Library/Caches/Yarn", "~/.yarn/cache"]
        ),
        CleanupCategory(
            id: "dev.pnpm",
            group: .developer,
            title: "pnpm store",
            explanation: "pnpm's content-addressable store. Note: removing it means re-downloading for all projects.",
            safety: .caution,
            roots: ["~/Library/pnpm/store", "~/.pnpm-store"]
        ),
        CleanupCategory(
            id: "dev.pip",
            group: .developer,
            title: "pip cache",
            explanation: "Cached Python wheels. pip re-fetches as needed.",
            safety: .safe,
            // Note: ~/.cache/pip is intentionally omitted — it lives under the
            // separate "~/.cache" category, and listing it here would double-count.
            roots: ["~/Library/Caches/pip"]
        ),
        CleanupCategory(
            id: "dev.gradle",
            group: .developer,
            title: "Gradle cache",
            explanation: "Downloaded dependencies and build caches for Gradle. Regenerated on the next build.",
            safety: .caution,
            roots: ["~/.gradle/caches"]
        ),
        CleanupCategory(
            id: "dev.homebrew",
            group: .developer,
            title: "Homebrew downloads",
            explanation: "Cached formula/cask downloads (the same thing `brew cleanup` removes).",
            safety: .safe,
            roots: ["~/Library/Caches/Homebrew"]
        ),
        CleanupCategory(
            id: "dev.xcode.deriveddata",
            group: .developer,
            title: "Xcode DerivedData",
            explanation: "Xcode build products and indexes. Rebuilt on the next build; frees a lot of space.",
            safety: .safe,
            roots: ["~/Library/Developer/Xcode/DerivedData"]
        ),
        CleanupCategory(
            id: "dev.coresimulator.caches",
            group: .developer,
            title: "Simulator caches",
            explanation: "CoreSimulator caches. Safe to clear; simulators rebuild them.",
            safety: .safe,
            roots: ["~/Library/Developer/CoreSimulator/Caches"]
        ),
        CleanupCategory(
            id: "dev.generic-cache",
            group: .developer,
            title: "~/.cache",
            explanation: "Generic tool cache directory used by many CLIs. Contents are regenerable.",
            safety: .caution,
            roots: ["~/.cache"],
            contentsOnly: true,
            excludes: []
        ),
        CleanupCategory(
            id: "dev.maven",
            group: .developer,
            title: "Maven repository",
            explanation: "Local Maven artifact cache. Re-downloaded on the next build — can be large.",
            safety: .caution,
            roots: ["~/.m2/repository"]
        ),
    ]

    // MARK: - Tier 1b — General user caches

    public static let tier1b_general: [CleanupCategory] = [
        CleanupCategory(
            id: "user.caches",
            group: .userCaches,
            title: "Application caches",
            explanation: "Per-app cache folders in ~/Library/Caches. Apps recreate these as needed.",
            safety: .safe,
            roots: ["~/Library/Caches"],
            contentsOnly: true,
            // Keep dev-tool caches out of this bucket so they show under Developer,
            // and never touch anything that isn't purely a cache.
            excludes: ["Homebrew", "pip", "Yarn", "com.apple.dt.Xcode"]
        ),
        CleanupCategory(
            id: "user.logs",
            group: .logs,
            title: "Logs",
            explanation: "Diagnostic logs in ~/Library/Logs. Safe to remove; only useful for debugging.",
            safety: .safe,
            roots: ["~/Library/Logs"]
        ),
        CleanupCategory(
            id: "user.trash",
            group: .trash,
            title: "Trash",
            explanation: "Items already in the Trash. Emptying is permanent.",
            safety: .caution,
            roots: ["~/.Trash"]
        ),
        CleanupCategory(
            id: "user.savedstate",
            group: .appState,
            title: "Saved application state",
            explanation: "Window/session restore data. Removing it only means apps reopen with fresh windows.",
            safety: .safe,
            roots: ["~/Library/Saved Application State"]
        ),
    ]

    // MARK: - Tier 2 — Advanced
    //
    // Orphaned app leftovers (OrphanDetector) and device backups are deferred to a
    // later milestone. Device backups in particular are deliberately kept inside
    // the ProtectedPaths deny-list (MobileSync) so v1 can never target them.

    public static func category(id: String) -> CleanupCategory? {
        all.first { $0.id == id }
    }
}
