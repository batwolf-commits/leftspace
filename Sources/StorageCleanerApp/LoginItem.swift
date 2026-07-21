import Foundation
import ServiceManagement

/// Manages whether LeftSpace opens automatically at login, using `SMAppService`
/// (macOS 13+). No privileged helper is needed — the main app registers itself.
///
/// Note: registration requires the app to be code-signed and, in practice, to run
/// from a stable location (e.g. /Applications). It works fully once the app is
/// notarized and installed; from a local build it may be limited.
enum LoginItem {

    /// True when the app is currently set to open at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register or unregister the app as a login item. Errors are logged rather
    /// than thrown, so a failure never crashes or blocks the UI.
    static func setEnabled(_ enabled: Bool) {
        do {
            let service = SMAppService.mainApp
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            NSLog("LeftSpace: could not \(enabled ? "enable" : "disable") open-at-login: \(error.localizedDescription)")
        }
    }

    /// Enable open-at-login once, the first time the app runs, so a freshly
    /// installed LeftSpace starts with the menu bar widget available. After this
    /// runs once, the user's choice in Settings is respected and never overridden.
    static func enableOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: PrefKey.didSetupLoginItem) else { return }
        defaults.set(true, forKey: PrefKey.didSetupLoginItem)
        setEnabled(true)
    }
}
