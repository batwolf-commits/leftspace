import Foundation

/// Detects whether the app has been granted Full Disk Access and points the user
/// to the right place to grant it.
///
/// There is no public API to query FDA directly, so we probe: attempt to read a
/// directory that is only readable with FDA. `~/Library/Application Support/
/// com.apple.TCC` is the standard sentinel — readable only when FDA is granted.
public enum FullDiskAccess {

    public static func isGranted(fileManager: FileManager = .default) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser
        let tcc = home
            .appendingPathComponent("Library/Application Support/com.apple.TCC")
            .appendingPathComponent("TCC.db")
        // If we can open the TCC database for reading, FDA is granted.
        if let handle = try? FileHandle(forReadingFrom: tcc) {
            try? handle.close()
            return true
        }
        return false
    }

    /// Deep link to System Settings → Privacy & Security → Full Disk Access.
    public static let settingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
}
