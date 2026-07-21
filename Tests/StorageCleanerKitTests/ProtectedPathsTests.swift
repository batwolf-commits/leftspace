import XCTest
import Foundation
@testable import StorageCleanerKit

final class ProtectedPathsTests: XCTestCase {

    let guardrail = ProtectedPaths()
    let home = FileManager.default.homeDirectoryForCurrentUser

    func testRefusesDocuments() {
        XCTAssertFalse(guardrail.check(home.appendingPathComponent("Documents")).isAllowed)
        XCTAssertFalse(guardrail.check(home.appendingPathComponent("Documents/taxes/2025.pdf")).isAllowed)
    }

    func testRefusesIrreplaceable() {
        XCTAssertFalse(guardrail.check(home.appendingPathComponent("Desktop")).isAllowed)
        XCTAssertFalse(guardrail.check(home.appendingPathComponent("Pictures/Photos Library.photoslibrary")).isAllowed)
        XCTAssertFalse(guardrail.check(home.appendingPathComponent("Library/Mobile Documents/x")).isAllowed)
        XCTAssertFalse(guardrail.check(URL(fileURLWithPath: "/System/Library")).isAllowed)
        XCTAssertFalse(guardrail.check(URL(fileURLWithPath: "/Applications/Safari.app")).isAllowed)
        XCTAssertFalse(guardrail.check(URL(fileURLWithPath: "/")).isAllowed)
    }

    func testHomeItselfVsCaches() {
        XCTAssertFalse(guardrail.check(home).isAllowed)
        XCTAssertTrue(guardrail.check(home.appendingPathComponent("Library/Caches/com.example.app")).isAllowed)
        XCTAssertTrue(guardrail.check(home.appendingPathComponent(".npm/_cacache")).isAllowed)
    }

    func testRefusesAncestorOfProtected() {
        // ~/Library contains protected subpaths → removing ~/Library is refused.
        XCTAssertFalse(guardrail.check(home.appendingPathComponent("Library")).isAllowed)
    }

    func testBoundaryAware() {
        // A sibling that merely shares a prefix must not be caught.
        let sibling = home.appendingPathComponent("DocumentsOld/file")
        XCTAssertTrue(guardrail.check(sibling).isAllowed)
    }

    func testNormalizeTrailingSlash() {
        XCTAssertEqual(ProtectedPaths.normalize("/Users/x/"), "/Users/x")
        XCTAssertEqual(ProtectedPaths.normalize("/"), "/")
    }

    func testIsDescendantBoundaries() {
        XCTAssertTrue(ProtectedPaths.isDescendant("/a/b/c", of: "/a/b"))
        XCTAssertFalse(ProtectedPaths.isDescendant("/a/bc", of: "/a/b"))
        XCTAssertFalse(ProtectedPaths.isDescendant("/a/b", of: "/a/b"))
    }
}
