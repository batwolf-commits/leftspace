import Foundation

/// Removes scan items, defaulting to move-to-Trash so every action is recoverable.
///
/// Non-negotiable invariant: every candidate is run through `ProtectedPaths` first.
/// Nothing is deleted that the guard refuses, regardless of what asked for it.
public struct Deleter: Sendable {

    public enum Mode: Sendable {
        /// Move to the Trash — recoverable. The default and recommended path.
        case trash
        /// Permanently remove. Only when the user explicitly opts in.
        case permanent
    }

    public struct Outcome: Sendable {
        public let url: URL
        public let requestedBytes: Int64
        public let succeeded: Bool
        /// Where it went in the Trash, when applicable.
        public let trashedTo: URL?
        public let error: String?
    }

    public struct Report: Sendable {
        public let outcomes: [Outcome]
        public var freedBytes: Int64 { outcomes.filter { $0.succeeded }.reduce(0) { $0 + $1.requestedBytes } }
        public var succeededCount: Int { outcomes.filter { $0.succeeded }.count }
        public var failedCount: Int { outcomes.filter { !$0.succeeded }.count }
        /// Items rejected by the safety guard (a subset of failures).
        public var refusedCount: Int { outcomes.filter { !$0.succeeded && ($0.error?.hasPrefix("Refused") ?? false) }.count }
    }

    private let guardrail: ProtectedPaths
    /// When true, no filesystem changes are made — used for previews/tests.
    public let dryRun: Bool

    /// Thread-safe shared instance; `FileManager` itself is not `Sendable`, so we
    /// use the singleton rather than storing one.
    private var fileManager: FileManager { .default }

    public init(dryRun: Bool = false) {
        self.guardrail = ProtectedPaths()
        self.dryRun = dryRun
    }

    public func delete(_ items: [ScanItem], mode: Mode = .trash) -> Report {
        var outcomes: [Outcome] = []
        for item in items {
            outcomes.append(deleteOne(item, mode: mode))
        }
        return Report(outcomes: outcomes)
    }

    // MARK: - Undo (restore from Trash)

    public struct RestoreOutcome: Sendable {
        public let url: URL
        public let restored: Bool
        public let error: String?
    }

    /// Move previously-trashed items back to where they came from.
    ///
    /// Only trash-mode outcomes can be undone — permanent deletions are gone. An
    /// item is restored only when its Trash copy still exists and nothing new has
    /// taken its original path (we never overwrite).
    public func restore(_ outcomes: [Outcome]) -> [RestoreOutcome] {
        outcomes.compactMap { outcome in
            guard outcome.succeeded, let trashed = outcome.trashedTo else { return nil }
            let original = outcome.url
            guard fileManager.fileExists(atPath: trashed.path) else {
                return RestoreOutcome(url: original, restored: false,
                                      error: "No longer in the Trash.")
            }
            guard !fileManager.fileExists(atPath: original.path) else {
                return RestoreOutcome(url: original, restored: false,
                                      error: "Something already exists at the original location.")
            }
            do {
                // Make sure the parent directory is still there before moving back.
                let parent = original.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: parent.path) {
                    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                }
                try fileManager.moveItem(at: trashed, to: original)
                return RestoreOutcome(url: original, restored: true, error: nil)
            } catch {
                return RestoreOutcome(url: original, restored: false,
                                      error: error.localizedDescription)
            }
        }
    }

    // MARK: - Empty from Trash (finish the job — actually reclaim the space)

    public struct EmptyOutcome: Sendable {
        public let url: URL
        public let removed: Bool
        public let bytes: Int64
        public let error: String?
    }

    /// Permanently remove items that were previously moved to the Trash, using the
    /// exact Trash URLs we recorded. This only touches what *this app* trashed — it
    /// never empties the whole Trash. After this, the freed space is truly reclaimed.
    public func emptyTrashed(_ outcomes: [Outcome]) -> [EmptyOutcome] {
        outcomes.compactMap { outcome in
            guard outcome.succeeded, let trashed = outcome.trashedTo else { return nil }
            guard fileManager.fileExists(atPath: trashed.path) else {
                return EmptyOutcome(url: outcome.url, removed: false, bytes: 0,
                                    error: "Already gone from the Trash.")
            }
            do {
                try fileManager.removeItem(at: trashed)
                return EmptyOutcome(url: outcome.url, removed: true,
                                    bytes: outcome.requestedBytes, error: nil)
            } catch {
                return EmptyOutcome(url: outcome.url, removed: false, bytes: 0,
                                    error: error.localizedDescription)
            }
        }
    }

    private func deleteOne(_ item: ScanItem, mode: Mode) -> Outcome {
        // 1. Safety guard — always, no exceptions. Project artifacts use the scoped
        //    check that permits recognized regenerable folders inside user content.
        let verdict = item.categoryID == ProjectArtifactScanner.categoryID
            ? guardrail.checkArtifact(item.url)
            : guardrail.check(item.url)
        if case .refused(let reason) = verdict {
            return Outcome(url: item.url, requestedBytes: item.sizeBytes,
                           succeeded: false, trashedTo: nil,
                           error: "Refused by safety guard: \(reason)")
        }

        // 2. It must still exist.
        guard fileManager.fileExists(atPath: item.url.path) else {
            return Outcome(url: item.url, requestedBytes: item.sizeBytes,
                           succeeded: false, trashedTo: nil,
                           error: "No longer exists.")
        }

        // 3. Dry run stops here, reporting what it *would* do.
        if dryRun {
            return Outcome(url: item.url, requestedBytes: item.sizeBytes,
                           succeeded: true, trashedTo: nil, error: nil)
        }

        // 4. Perform the removal.
        do {
            switch mode {
            case .trash:
                var resulting: NSURL?
                try fileManager.trashItem(at: item.url, resultingItemURL: &resulting)
                return Outcome(url: item.url, requestedBytes: item.sizeBytes,
                               succeeded: true, trashedTo: resulting as URL?, error: nil)
            case .permanent:
                try fileManager.removeItem(at: item.url)
                return Outcome(url: item.url, requestedBytes: item.sizeBytes,
                               succeeded: true, trashedTo: nil, error: nil)
            }
        } catch {
            return Outcome(url: item.url, requestedBytes: item.sizeBytes,
                           succeeded: false, trashedTo: nil,
                           error: error.localizedDescription)
        }
    }
}
