import Foundation

/// The set of bundle identifiers for apps currently installed on this Mac.
///
/// Orphan detection is only as safe as this index is complete: if we miss an
/// installed app, we might flag its support files as "leftovers." So we cast a
/// wide net — the standard app folders plus one level of nesting (many apps live
/// in `/Applications/Some Suite/App.app`) — and read each bundle's real
/// `CFBundleIdentifier` rather than guessing from the name.
public struct InstalledAppsIndex: Sendable {

    /// Lowercased bundle identifiers of every app we found.
    public let bundleIDs: Set<String>

    public init(bundleIDs: Set<String>) {
        self.bundleIDs = bundleIDs
    }

    public func contains(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID.lowercased())
    }

    /// Whether `bundleID` belongs to an installed app — either an exact match, or
    /// a sub-identifier of one (an installed app's helper/extension). For example
    /// if `com.microsoft.excel` is installed, `com.microsoft.excel.widgetextension`
    /// is covered and must NOT be treated as an orphan.
    public func covers(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        if bundleIDs.contains(lower) { return true }
        for installed in bundleIDs where lower.hasPrefix(installed + ".") {
            return true
        }
        return false
    }

    /// Build the index by scanning the well-known application directories.
    public static func build(fileManager: FileManager = .default) -> InstalledAppsIndex {
        let home = fileManager.homeDirectoryForCurrentUser
        let searchRoots: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Library/CoreServices"),
            home.appendingPathComponent("Applications"),
        ]

        var ids = Set<String>()
        for root in searchRoots {
            collectAppBundleIDs(in: root, depth: 1, into: &ids, fileManager: fileManager)
        }
        return InstalledAppsIndex(bundleIDs: ids)
    }

    /// Recursively (bounded by `depth`) find `.app` bundles under `dir` and record
    /// their bundle IDs. `.app` bundles themselves are not descended into.
    private static func collectAppBundleIDs(
        in dir: URL,
        depth: Int,
        into ids: inout Set<String>,
        fileManager: FileManager
    ) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            if entry.pathExtension == "app" {
                if let id = bundleID(ofApp: entry) {
                    ids.insert(id.lowercased())
                }
            } else if depth > 0,
                      (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                collectAppBundleIDs(in: entry, depth: depth - 1, into: &ids, fileManager: fileManager)
            }
        }
    }

    /// Read `CFBundleIdentifier` from an app bundle's Info.plist.
    static func bundleID(ofApp appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let id = dict["CFBundleIdentifier"] as? String
        else { return nil }
        return id
    }
}
