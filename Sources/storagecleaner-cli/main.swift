import Foundation
import StorageCleanerKit

// A thin command-line front-end over StorageCleanerKit. It exists so the engine
// can be exercised and verified today, without Xcode. The SwiftUI app will call
// the exact same Scanner / Deleter APIs.
//
// Usage:
//   storagecleaner scan                 Scan and print a report (no changes)
//   storagecleaner clean [--permanent]  Scan, then move safe items to Trash
//                                        (add --yes to skip the prompt)
//   storagecleaner check <path>         Ask the safety guard about a path
//   storagecleaner permissions          Report Full Disk Access status

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "scan"

func printReport(_ result: ScanResult) {
    print("")
    print("  LeftSpace — scan report")
    print("  " + String(repeating: "─", count: 50))
    for cat in result.nonEmptyCategories {
        let size = ByteFormat.string(cat.totalBytes)
        let padded = cat.category.title.padding(toLength: 30, withPad: " ", startingAt: 0)
        print("  \(padded) \(size.leftPadded(to: 10))   [\(cat.category.safety.label)]")
    }
    print("  " + String(repeating: "─", count: 50))
    print("  Total reclaimable: \(ByteFormat.string(result.totalReclaimableBytes))")
    if !result.unreadableCategoryIDs.isEmpty {
        print("")
        print("  ⚠️  Some locations were unreadable (grant Full Disk Access to include them):")
        for id in result.unreadableCategoryIDs {
            if let c = CategoryCatalog.category(id: id) { print("      - \(c.title)") }
        }
    }
    print("")
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

switch command {
case "scan":
    let scanner = Scanner()
    let result = await scanner.scan { p in
        FileHandle.standardError.write("  scanning \(p.completedCategories)/\(p.totalCategories): \(p.currentCategoryTitle)…\n".data(using: .utf8)!)
    }
    printReport(result)

case "orphans":
    // List leftovers from removed apps, largest first, with the bundle ID we keyed
    // on — so the detection can be eyeballed for false positives.
    let installed = InstalledAppsIndex.build()
    FileHandle.standardError.write("  indexed \(installed.bundleIDs.count) installed apps\n".data(using: .utf8)!)
    let result = OrphanDetector().detect(installed: installed)
    print("")
    print("  Leftovers from removed apps — \(result.itemCount) items, \(ByteFormat.string(result.totalBytes))")
    print("  " + String(repeating: "─", count: 60))
    for item in result.items.prefix(40) {
        print("  \(ByteFormat.string(item.sizeBytes).leftPadded(to: 10))   \(item.url.lastPathComponent)")
    }
    print("")

case "projects":
    // List regenerable project artifacts (node_modules, venvs, build caches).
    let result = ProjectArtifactScanner().detect()
    print("")
    print("  Project build artifacts — \(result.itemCount) items, \(ByteFormat.string(result.totalBytes))")
    print("  " + String(repeating: "─", count: 64))
    for item in result.items.prefix(40) {
        print("  \(ByteFormat.string(item.sizeBytes).leftPadded(to: 10))   \(item.detail ?? item.url.lastPathComponent)")
    }
    print("")

case "permissions":
    let granted = FullDiskAccess.isGranted()
    print("Full Disk Access: \(granted ? "GRANTED" : "NOT granted")")
    if !granted {
        print("Grant it here: \(FullDiskAccess.settingsURLString)")
    }

case "check":
    guard args.count >= 2 else { print("usage: storagecleaner check <path>"); exit(2) }
    let url = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
    let verdict = ProtectedPaths().check(url)
    switch verdict {
    case .allowed:            print("ALLOWED: \(url.path)")
    case .refused(let why):   print("REFUSED: \(url.path)\n  reason: \(why)")
    }

case "clean":
    let permanent = args.contains("--permanent")
    let autoYes = args.contains("--yes")
    let scanner = Scanner()
    let result = await scanner.scan()
    printReport(result)

    // v1 CLI policy: only auto-select SAFE items. Anything else must be chosen
    // deliberately (the GUI handles per-item selection; the CLI stays conservative).
    let safeItems = result.categories
        .filter { $0.category.safety == .safe }
        .flatMap { $0.items }
    guard !safeItems.isEmpty else { print("Nothing safe to clean."); break }

    let safeBytes = safeItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
    print("  Will \(permanent ? "PERMANENTLY DELETE" : "move to Trash") \(safeItems.count) safe items (\(ByteFormat.string(safeBytes))).")
    if permanent { print("  ⚠️  Permanent mode: this is NOT recoverable.") }

    if !autoYes {
        print("  Proceed? [y/N] ", terminator: "")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        guard answer == "y" || answer == "yes" else { print("Aborted."); break }
    }

    let deleter = Deleter(dryRun: false)
    let report = deleter.delete(safeItems, mode: permanent ? .permanent : .trash)
    print("")
    print("  Freed \(ByteFormat.string(report.freedBytes)) — \(report.succeededCount) removed, \(report.failedCount) failed (\(report.refusedCount) refused by safety guard).")
    for o in report.outcomes where !o.succeeded {
        print("    ✗ \(o.url.lastPathComponent): \(o.error ?? "unknown")")
    }

case "selftest":
    // Dependency-free verification of the safety guard (until Xcode/XCTest is
    // available). Exits non-zero on any failure.
    let g = ProtectedPaths()
    let home = FileManager.default.homeDirectoryForCurrentUser
    var failures: [String] = []
    func expectRefused(_ path: String) {
        let u = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if g.check(u).isAllowed { failures.append("expected REFUSED but ALLOWED: \(u.path)") }
    }
    func expectAllowed(_ path: String) {
        let u = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if !g.check(u).isAllowed { failures.append("expected ALLOWED but REFUSED: \(u.path)") }
    }

    expectRefused(home.appendingPathComponent("Documents").path)
    expectRefused(home.appendingPathComponent("Documents/taxes/2025.pdf").path)
    expectRefused(home.appendingPathComponent("Desktop").path)
    expectRefused(home.appendingPathComponent("Pictures/Photos Library.photoslibrary").path)
    expectRefused(home.appendingPathComponent("Library/Mobile Documents/x").path)
    expectRefused(home.appendingPathComponent("Library").path)          // ancestor of protected
    expectRefused(home.path)                                            // home itself
    expectRefused("/")
    expectRefused("/System/Library")
    expectRefused("/Applications/Safari.app")

    expectAllowed(home.appendingPathComponent("Library/Caches/com.example.app").path)
    expectAllowed(home.appendingPathComponent(".npm/_cacache").path)
    expectAllowed(home.appendingPathComponent("DocumentsOld/file").path) // boundary-aware

    // Scoped project-artifact guard: allow recognized artifacts under Documents,
    // but still refuse ordinary files there.
    func expectArtifactAllowed(_ path: String) {
        let u = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if !g.checkArtifact(u).isAllowed { failures.append("artifact expected ALLOWED: \(u.path)") }
    }
    func expectArtifactRefused(_ path: String) {
        let u = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if g.checkArtifact(u).isAllowed { failures.append("artifact expected REFUSED: \(u.path)") }
    }
    expectArtifactAllowed(home.appendingPathComponent("Documents/Projects/app/node_modules").path)
    expectArtifactAllowed(home.appendingPathComponent("Desktop/thing/.venv").path)
    expectArtifactRefused(home.appendingPathComponent("Documents/Projects/app/src").path)   // not an artifact name
    expectArtifactRefused(home.appendingPathComponent("Documents/taxes.pdf").path)          // real document
    expectArtifactRefused(home.appendingPathComponent("Pictures/node_modules").path)        // hard-protected area

    if failures.isEmpty {
        print("selftest: PASS (all safety-guard assertions held)")
    } else {
        print("selftest: FAIL")
        failures.forEach { print("  ✗ \($0)") }
        exit(1)
    }

case "trashtest":
    // Self-contained end-to-end check of trash-first deletion. Creates its own
    // throwaway cache folder, routes it through the real Deleter, and verifies it
    // left the source and is recoverable from the Trash. Touches nothing else.
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let fake = home.appendingPathComponent("Library/Caches/com.storagecleaner.trashtest")
    try? fm.removeItem(at: fake)
    try! fm.createDirectory(at: fake, withIntermediateDirectories: true)
    let payload = fake.appendingPathComponent("blob.bin")
    fm.createFile(atPath: payload.path, contents: Data(count: 2_000_000)) // 2 MB
    let size = SizeCalculator().directoryAllocatedSize(fake)
    print("  seeded \(fake.lastPathComponent) (\(ByteFormat.string(size)))")

    let item = ScanItem(url: fake, sizeBytes: size, categoryID: "user.caches")
    let report = Deleter(dryRun: false).delete([item], mode: .trash)
    let o = report.outcomes.first!

    var ok = true
    if fm.fileExists(atPath: fake.path) { print("  ✗ source still exists"); ok = false }
    else { print("  ✓ source removed") }
    if let trashed = o.trashedTo, fm.fileExists(atPath: trashed.path) {
        print("  ✓ recoverable in Trash: \(trashed.path)")
        try? fm.removeItem(at: trashed) // clean up our own test artifact
    } else {
        print("  ✗ not found in Trash"); ok = false
    }
    print(ok ? "trashtest: PASS" : "trashtest: FAIL")
    if !ok { exit(1) }

case "undotest":
    // End-to-end check of trash → undo (restore). Seeds a throwaway cache folder,
    // trashes it through the real Deleter, then restores it and verifies it is back
    // at its original path and gone from the Trash. Touches nothing else.
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let fake = home.appendingPathComponent("Library/Caches/com.storagecleaner.undotest")
    try? fm.removeItem(at: fake)
    try! fm.createDirectory(at: fake, withIntermediateDirectories: true)
    fm.createFile(atPath: fake.appendingPathComponent("blob.bin").path, contents: Data(count: 2_000_000))
    let size = SizeCalculator().directoryAllocatedSize(fake)
    print("  seeded \(fake.lastPathComponent) (\(ByteFormat.string(size)))")

    let deleter = Deleter(dryRun: false)
    let report = deleter.delete([ScanItem(url: fake, sizeBytes: size, categoryID: "user.caches")], mode: .trash)
    var ok = true
    if fm.fileExists(atPath: fake.path) { print("  ✗ source still exists after trash"); ok = false }
    else { print("  ✓ trashed") }

    let restores = deleter.restore(report.outcomes)
    if restores.first?.restored == true, fm.fileExists(atPath: fake.path) {
        print("  ✓ restored to original location")
    } else {
        print("  ✗ not restored: \(restores.first?.error ?? "unknown")"); ok = false
    }
    if let trashed = report.outcomes.first?.trashedTo, fm.fileExists(atPath: trashed.path) {
        print("  ✗ still present in Trash after undo"); ok = false
    }
    try? fm.removeItem(at: fake) // clean up our own test artifact
    print(ok ? "undotest: PASS" : "undotest: FAIL")
    if !ok { exit(1) }

case "emptytest":
    // End-to-end check of trash → empty-from-Trash. Seeds a throwaway cache folder,
    // trashes it, then permanently removes just that item from the Trash and
    // verifies it is gone from both the source and the Trash. Touches nothing else.
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let fake = home.appendingPathComponent("Library/Caches/com.storagecleaner.emptytest")
    try? fm.removeItem(at: fake)
    try! fm.createDirectory(at: fake, withIntermediateDirectories: true)
    fm.createFile(atPath: fake.appendingPathComponent("blob.bin").path, contents: Data(count: 2_000_000))
    let size = SizeCalculator().directoryAllocatedSize(fake)
    print("  seeded \(fake.lastPathComponent) (\(ByteFormat.string(size)))")

    let deleter = Deleter(dryRun: false)
    let report = deleter.delete([ScanItem(url: fake, sizeBytes: size, categoryID: "user.caches")], mode: .trash)
    let trashedPath = report.outcomes.first?.trashedTo
    var ok = true
    if let t = trashedPath, fm.fileExists(atPath: t.path) { print("  ✓ trashed") }
    else { print("  ✗ not in Trash after move"); ok = false }

    let emptied = deleter.emptyTrashed(report.outcomes)
    if emptied.first?.removed == true { print("  ✓ emptied from Trash (\(ByteFormat.string(emptied.first?.bytes ?? 0)))") }
    else { print("  ✗ not emptied: \(emptied.first?.error ?? "unknown")"); ok = false }
    if let t = trashedPath, fm.fileExists(atPath: t.path) { print("  ✗ still in Trash after empty"); ok = false }
    if fm.fileExists(atPath: fake.path) { print("  ✗ source reappeared"); ok = false }
    print(ok ? "emptytest: PASS" : "emptytest: FAIL")
    if !ok { exit(1) }

default:
    print("""
    LeftSpace CLI
      storagecleaner scan                 Scan and print report (no changes)
      storagecleaner clean [--permanent] [--yes]   Clean SAFE items (Trash by default)
      storagecleaner check <path>         Ask the safety guard about a path
      storagecleaner permissions          Full Disk Access status
    """)
}
