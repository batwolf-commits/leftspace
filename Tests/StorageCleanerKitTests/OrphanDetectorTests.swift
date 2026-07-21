import XCTest
@testable import StorageCleanerKit

final class OrphanDetectorTests: XCTestCase {

    // MARK: - bundleID heuristic

    func testAcceptsGenuineReverseDNSIdentifiers() {
        XCTAssertEqual(OrphanDetector.bundleID(from: "com.microsoft.Outlook"), "com.microsoft.Outlook")
        XCTAssertEqual(OrphanDetector.bundleID(from: "ai.opencode.desktop"), "ai.opencode.desktop")
        XCTAssertEqual(OrphanDetector.bundleID(from: "jp.co.capcom.RE2US"), "jp.co.capcom.RE2US")
        // Trailing extensions are stripped.
        XCTAssertEqual(OrphanDetector.bundleID(from: "com.acme.Widget.savedState"), "com.acme.Widget")
        XCTAssertEqual(OrphanDetector.bundleID(from: "com.acme.Widget.plist"), "com.acme.Widget")
    }

    func testRejectsDomainOrderNames() {
        // The critical one: `zoom.us` is a data-folder name, NOT a bundle ID
        // (Zoom's real ID is us.zoom.xos). Must never be treated as an orphan.
        XCTAssertNil(OrphanDetector.bundleID(from: "zoom.us"))
    }

    func testRejectsGenericAndNonBundleNames() {
        XCTAssertNil(OrphanDetector.bundleID(from: "default.store"))
        XCTAssertNil(OrphanDetector.bundleID(from: "default.store-shm"))
        XCTAssertNil(OrphanDetector.bundleID(from: "Google"))       // single label
        XCTAssertNil(OrphanDetector.bundleID(from: "Steam"))
        XCTAssertNil(OrphanDetector.bundleID(from: "com.foo"))      // only two labels
        XCTAssertNil(OrphanDetector.bundleID(from: "notatld.foo.bar")) // first label not a TLD
    }

    // MARK: - installed-apps coverage (extensions of installed apps)

    func testCoversSubIdentifiersOfInstalledApps() {
        let index = InstalledAppsIndex(bundleIDs: ["com.microsoft.excel"])
        XCTAssertTrue(index.covers("com.microsoft.Excel"))                    // exact (case-insensitive)
        XCTAssertTrue(index.covers("com.microsoft.Excel.widgetextension"))    // extension of installed app
        XCTAssertFalse(index.covers("com.microsoft.ExcelHelper"))             // sibling, not a sub-identifier
        XCTAssertFalse(index.covers("com.google.Chrome"))                     // unrelated
    }

    // MARK: - system-owned exclusion

    func testSkipsAppleOwnedIdentifiers() {
        XCTAssertTrue(OrphanDetector.isSystemOwned("com.apple.Safari"))
        XCTAssertTrue(OrphanDetector.isSystemOwned("group.com.apple.notes"))
        XCTAssertFalse(OrphanDetector.isSystemOwned("com.microsoft.Outlook"))
    }
}
