import SwiftUI
import AppKit

/// Launched from a minimal (ad-hoc) bundle, a SwiftUI app can come up as an
/// "accessory" — its window shows but it never owns the top menu bar, so the
/// Settings… item (⌘,) and the app menus are invisible. Forcing `.regular` here
/// gives it a proper Dock icon and menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Honors the user's "Dock icon & app window" preference (defaults to on).
        applyDockPolicy()
        // On first launch, start LeftSpace at login so the menu bar widget is
        // available after install. The user can turn this off in Settings.
        LoginItem.enableOnFirstLaunch()
        // In widget-only mode, start hidden: close the window SwiftUI auto-opens,
        // so the app lives purely in the menu bar until the widget opens it.
        if !showDockIconPreference {
            DispatchQueue.main.async {
                for window in NSApp.windows where window.canBecomeMain {
                    window.close()
                }
            }
        }
    }
    /// Keep running when the window is closed — this is a menu bar utility, so the
    /// widget stays available and the app only exits via its Quit action.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon after the window was closed reopens it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
            sender.activate(ignoringOtherApps: true)
        }
        return true
    }
}

@main
struct StorageCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ScanViewModel()
    @AppStorage(PrefKey.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some Scene {
        Window("LeftSpace", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 520)
                .task {
                    // Re-apply any saved reminder schedule when the app launches.
                    await applyReminderPreferences()
                }
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }

        // Optional menu bar summary with graphs + quick actions. Toggle in Settings.
        // Uses the app's own outline glyph as a template so it matches the Dock
        // icon and adapts to the light/dark menu bar automatically.
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarIconView(size: 18)
        }
        .menuBarExtraStyle(.window)
    }
}
