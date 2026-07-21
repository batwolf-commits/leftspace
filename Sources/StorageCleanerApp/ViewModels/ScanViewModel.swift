import Foundation
import Observation
import StorageCleanerKit

/// Drives the whole UI. Wraps the `Scanner` and `Deleter` from StorageCleanerKit
/// and holds the transient selection/progress state the views bind to.
///
/// Selection model: keyed by `ScanItem.id` (its path). Safe items are pre-selected
/// after a scan; everything else the user opts into. The view model never decides
/// safety on its own — it reads `SafetyLevel` from the catalog.
@Observable
@MainActor
final class ScanViewModel {

    enum Phase: Equatable {
        case idle
        case scanning(done: Int, total: Int, current: String)
        case results
        case cleaning
        case finished(freed: Int64, failures: Int)
    }

    var phase: Phase = .idle
    var result: ScanResult?
    /// Paths the user has chosen to remove.
    var selected: Set<String> = []
    var fullDiskAccessGranted: Bool = FullDiskAccess.isGranted()

    /// Whether cleans move to Trash (true) vs delete permanently. This is a proxy
    /// over the single persistent `permanentDelete` preference, so the main window,
    /// the menu bar, and Settings all agree — there is exactly one source of truth.
    var trashMode: Bool {
        get { !UserDefaults.standard.bool(forKey: PrefKey.permanentDelete) }
        set { UserDefaults.standard.set(!newValue, forKey: PrefKey.permanentDelete) }
    }

    /// Priority filter: when non-nil, only categories at this safety level show.
    var safetyFilter: SafetyLevel? = nil

    /// Boot-volume capacity, for the menu bar summary/graphs. Refreshed on demand.
    var diskSpace: DiskSpace = .current()

    private let scanner = Scanner()

    func refreshDiskSpace() { diskSpace = .current() }

    /// Deletion mode from the user's preference: permanent (skip Trash) vs trash.
    var deleteMode: Deleter.Mode {
        UserDefaults.standard.bool(forKey: PrefKey.permanentDelete) ? .permanent : .trash
    }

    // MARK: - Derived state the views read

    var totalReclaimable: Int64 { result?.totalReclaimableBytes ?? 0 }

    var selectedBytes: Int64 {
        guard let result else { return 0 }
        var sum: Int64 = 0
        for cat in result.categories {
            for item in cat.items where selected.contains(item.id) {
                sum += item.sizeBytes
            }
        }
        return sum
    }

    var selectedItems: [ScanItem] {
        guard let result else { return [] }
        return result.categories.flatMap { $0.items }.filter { selected.contains($0.id) }
    }

    /// Category results grouped by their high-level `CategoryGroup`, non-empty only,
    /// each group ordered by size — this is the shape the results list renders.
    /// Honors `safetyFilter` when set.
    var groups: [(group: CategoryGroup, categories: [CategoryResult])] {
        guard let result else { return [] }
        let nonEmpty = result.nonEmptyCategories.filter { cat in
            safetyFilter == nil || cat.category.safety == safetyFilter
        }
        let grouped = Dictionary(grouping: nonEmpty) { $0.category.group }
        return CategoryGroup.allCases.compactMap { g in
            guard let cats = grouped[g], !cats.isEmpty else { return nil }
            return (g, cats.sorted { $0.totalBytes > $1.totalBytes })
        }
    }

    /// How many non-empty categories exist at each safety level (for filter badges).
    func categoryCount(for level: SafetyLevel?) -> Int {
        guard let result else { return 0 }
        return result.nonEmptyCategories.filter { level == nil || $0.category.safety == level }.count
    }

    func isSelected(_ item: ScanItem) -> Bool { selected.contains(item.id) }

    /// Every item in the currently visible (filtered) groups.
    var visibleItems: [ScanItem] {
        groups.flatMap { $0.categories }.flatMap { $0.items }
    }

    /// True when all visible items are selected — drives the "Select all" checkbox.
    var allVisibleSelected: Bool {
        let items = visibleItems
        return !items.isEmpty && items.allSatisfy { selected.contains($0.id) }
    }

    func setAllVisibleSelected(_ on: Bool) {
        for item in visibleItems {
            if on { selected.insert(item.id) } else { selected.remove(item.id) }
        }
    }

    // MARK: - Menu bar summary helpers

    /// Total bytes in `.safe` categories — what a one-click "clean safe" would free.
    var safeReclaimableBytes: Int64 {
        reclaimableBytes(for: .safe)
    }

    /// Reclaimable bytes across the categories at a given safety level.
    func reclaimableBytes(for level: SafetyLevel) -> Int64 {
        result?.categories
            .filter { $0.category.safety == level }
            .reduce(0) { $0 + $1.totalBytes } ?? 0
    }

    /// Reclaimable bytes across a set of safety levels (for the menu bar picker).
    func reclaimableBytes(forLevels levels: Set<SafetyLevel>) -> Int64 {
        levels.reduce(0) { $0 + reclaimableBytes(for: $1) }
    }

    /// Top categories by size for a compact chart (largest first).
    func topCategories(_ limit: Int) -> [CategoryResult] {
        Array((result?.nonEmptyCategories ?? []).prefix(limit))
    }

    var isScanning: Bool { if case .scanning = phase { return true }; return false }
    var isCleaning: Bool { if case .cleaning = phase { return true }; return false }
    var hasResult: Bool { result != nil }

    /// Bytes freed by the most recent quick-clean, for a brief widget confirmation.
    var lastCleanedBytes: Int64? = nil
    /// Whether that last quick-clean deleted permanently (vs moved to Trash).
    var lastCleanPermanent: Bool = false

    // MARK: - Menu bar empty-from-Trash state

    /// The report from the most recent menu bar clean that moved items to the Trash,
    /// kept so the widget can offer to empty exactly those items (and nothing else).
    private var menuBarTrashReport: Deleter.Report? = nil
    /// True once the widget has emptied that menu bar clean from the Trash.
    private var didEmptyMenuBarTrash = false

    /// True when the last menu bar clean left recoverable items in the Trash that
    /// can still be permanently emptied to actually free the space.
    var canEmptyMenuBarClean: Bool {
        !didEmptyMenuBarTrash &&
        (menuBarTrashReport?.outcomes.contains { $0.succeeded && $0.trashedTo != nil } ?? false)
    }

    /// Permanently remove the items from the last menu bar clean out of the Trash.
    /// Irreversible; callers must confirm first. Only touches what we trashed, and
    /// leaves the scan phase untouched so it never disrupts the main window.
    func emptyMenuBarClean() async {
        guard let report = menuBarTrashReport else { return }
        let outcomes = report.outcomes
        _ = await Task.detached {
            Deleter(dryRun: false).emptyTrashed(outcomes)
        }.value
        menuBarTrashReport = nil
        didEmptyMenuBarTrash = true
        // Those items are now permanently gone; reflect that in the widget label.
        lastCleanPermanent = true
        refreshDiskSpace()
    }

    // MARK: - Undo state (for the finished screen)

    /// Disk snapshot captured immediately before the last clean, so the finished
    /// screen can show a before/after gauge of space actually reclaimed.
    var diskBeforeClean: DiskSpace? = nil
    /// The report from the last clean, kept so it can be undone (restored from Trash).
    private var lastCleanReport: Deleter.Report? = nil
    /// Whether the last clean moved to Trash (undoable) vs deleted permanently.
    var lastCleanWasTrash: Bool = false
    /// How many items the most recent undo restored, for a brief confirmation.
    var lastUndoRestoredCount: Int? = nil
    /// True once the just-trashed items have been permanently emptied from the Trash.
    var didEmptyTrashed = false

    /// True when the last clean can still be undone (trash mode + restorable items).
    var canUndoLastClean: Bool {
        lastCleanWasTrash && !didEmptyTrashed &&
        (lastCleanReport?.outcomes.contains { $0.succeeded && $0.trashedTo != nil } ?? false)
    }

    /// True when the just-trashed items can be permanently emptied from the Trash
    /// to actually reclaim the space (moving to Trash alone doesn't free it).
    var canEmptyTrashed: Bool { canUndoLastClean }

    /// Permanently remove the items from the last clean out of the Trash. This is
    /// irreversible; callers must confirm first. Only touches what we trashed.
    func emptyTrashedFromLastClean() async {
        guard let report = lastCleanReport else { return }
        let outcomes = report.outcomes
        let freed = report.freedBytes
        let failures = report.failedCount
        phase = .cleaning
        _ = await Task.detached {
            Deleter(dryRun: false).emptyTrashed(outcomes)
        }.value
        // Undo is no longer possible once the Trash copies are gone.
        lastCleanReport = nil
        didEmptyTrashed = true
        refreshDiskSpace()
        phase = .finished(freed: freed, failures: failures)
    }

    /// Move everything from the last clean back out of the Trash to where it was.
    func undoLastClean() async {
        guard let report = lastCleanReport else { return }
        let outcomes = report.outcomes
        phase = .cleaning
        let restores = await Task.detached {
            Deleter(dryRun: false).restore(outcomes)
        }.value
        lastUndoRestoredCount = restores.filter(\.restored).count
        lastCleanReport = nil
        refreshDiskSpace()
        // Restored files will reappear on the next scan; return to the start.
        reset()
    }

    /// One-click safe cleanup used by the menu bar: clean every `.safe` item.
    func cleanSafeToTrash() async {
        await cleanLevels([.safe])
    }

    /// Quick cleanup used by the menu bar: remove every item whose category safety
    /// is in `levels`, using the user's Trash/permanent preference. Afterwards the
    /// result is updated in place so the summary reflects what was actually removed.
    func cleanLevels(_ levels: Set<SafetyLevel>) async {
        guard let current = result, !levels.isEmpty else { return }
        let items = current.categories
            .filter { levels.contains($0.category.safety) }
            .flatMap { $0.items }
        guard !items.isEmpty else { return }

        let mode = deleteMode
        phase = .cleaning
        let report = await Task.detached {
            Deleter(dryRun: false).delete(items, mode: mode)
        }.value

        // Drop successfully removed items so reclaimable totals update immediately.
        let removed = Set(report.outcomes.filter(\.succeeded).map { $0.url.path })
        let newCategories = current.categories.map { cat in
            CategoryResult(category: cat.category,
                           items: cat.items.filter { !removed.contains($0.url.path) })
        }
        result = ScanResult(categories: newCategories,
                            scannedAt: current.scannedAt,
                            unreadableCategoryIDs: current.unreadableCategoryIDs)
        selected.subtract(removed)
        lastCleanedBytes = report.freedBytes
        lastCleanPermanent = (mode == .permanent)
        // Remember what went to the Trash so the widget can offer to empty it.
        menuBarTrashReport = (mode == .trash) ? report : nil
        didEmptyMenuBarTrash = false
        refreshDiskSpace()
        phase = .results
    }

    // MARK: - Actions

    func refreshPermissions() {
        fullDiskAccessGranted = FullDiskAccess.isGranted()
    }

    func startScan() async {
        lastCleanedBytes = nil
        menuBarTrashReport = nil
        didEmptyMenuBarTrash = false
        phase = .scanning(done: 0, total: CategoryCatalog.all.count, current: "")
        let includePersonal = UserDefaults.standard.bool(forKey: PrefKey.scanPersonalFolders)
        let includeLeftovers = UserDefaults.standard.bool(forKey: PrefKey.scanAppLeftovers)
        let scanned = await scanner.scan(includeOrphans: includeLeftovers,
                                         includePersonalFolders: includePersonal) { [weak self] p in
            Task { @MainActor in
                self?.phase = .scanning(done: p.completedCategories,
                                        total: p.totalCategories,
                                        current: p.currentCategoryTitle)
            }
        }
        self.result = scanned
        self.selected = Self.defaultSelection(for: scanned)
        self.phase = .results
    }

    /// Pre-select every item belonging to a `.safe` category.
    static func defaultSelection(for result: ScanResult) -> Set<String> {
        var set = Set<String>()
        for cat in result.categories where cat.category.safety == .safe {
            for item in cat.items { set.insert(item.id) }
        }
        return set
    }

    func toggle(_ item: ScanItem) {
        if selected.contains(item.id) { selected.remove(item.id) }
        else { selected.insert(item.id) }
    }

    func toggleCategory(_ cat: CategoryResult, on: Bool) {
        for item in cat.items {
            if on { selected.insert(item.id) } else { selected.remove(item.id) }
        }
    }

    func isCategoryFullySelected(_ cat: CategoryResult) -> Bool {
        !cat.items.isEmpty && cat.items.allSatisfy { selected.contains($0.id) }
    }

    func clean() async {
        let items = selectedItems
        guard !items.isEmpty else { return }
        diskBeforeClean = .current()
        lastUndoRestoredCount = nil
        didEmptyTrashed = false
        phase = .cleaning
        let mode = deleteMode
        // Deletion is synchronous filesystem work; run it off the main actor.
        let report = await Task.detached {
            Deleter(dryRun: false).delete(items, mode: mode)
        }.value
        lastCleanReport = report
        lastCleanWasTrash = (mode == .trash)
        refreshDiskSpace()
        phase = .finished(freed: report.freedBytes, failures: report.failedCount)
    }

    func reset() {
        phase = .idle
        result = nil
        selected = []
        lastCleanReport = nil
        diskBeforeClean = nil
        didEmptyTrashed = false
        menuBarTrashReport = nil
        didEmptyMenuBarTrash = false
    }
}
