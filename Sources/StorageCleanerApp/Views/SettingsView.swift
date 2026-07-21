import SwiftUI
import StorageCleanerKit

/// Keys for the small set of persisted preferences.
enum PrefKey {
    static let reminderEnabled = "reminderEnabled"
    static let reminderFrequency = "reminderFrequency"
    static let reminderHour = "reminderHour"
    static let reminderMinute = "reminderMinute"
    static let showMenuBarIcon = "showMenuBarIcon"
    static let showDockIcon = "showDockIcon"
    static let permanentDelete = "permanentDelete"
    static let scanPersonalFolders = "scanPersonalFolders"
    static let scanAppLeftovers = "scanAppLeftovers"
    static let didSetupLoginItem = "didSetupLoginItem"
}

/// Whether the user has opted into permanent deletion (skip the Trash).
/// Defaults to off — move-to-Trash is the safe default.
@MainActor
var permanentDeletePreference: Bool {
    UserDefaults.standard.bool(forKey: PrefKey.permanentDelete)
}

/// Whether the user wants the Dock icon / app window (defaults to on).
@MainActor
var showDockIconPreference: Bool {
    UserDefaults.standard.object(forKey: PrefKey.showDockIcon) as? Bool ?? true
}

/// Whether the menu bar widget is enabled (defaults to on).
@MainActor
var showMenuBarIconPreference: Bool {
    UserDefaults.standard.object(forKey: PrefKey.showMenuBarIcon) as? Bool ?? true
}

/// Applies the "show Dock icon / app window" preference by switching the app's
/// activation policy: `.regular` gives a Dock icon + top menu bar + window;
/// `.accessory` makes it a pure menu-bar utility with no Dock presence.
@MainActor
func applyDockPolicy() {
    NSApp.setActivationPolicy(showDockIconPreference ? .regular : .accessory)
    if showDockIconPreference { NSApp.activate(ignoringOtherApps: true) }
}

/// Brings up the main window from the menu bar widget. In widget-only (accessory)
/// mode the app can't show a proper window, so we temporarily promote it to a
/// regular app; `RootView` drops it back to accessory when the window closes.
@MainActor
func presentMainWindow(_ openWindow: OpenWindowAction) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: "main")
    // Ensure the (re)opened window is frontmost.
    DispatchQueue.main.async {
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }
}

/// Reads current reminder preferences from `UserDefaults` and (re)applies them to
/// the scheduler — called on launch and whenever the Reminders settings change.
@MainActor
func applyReminderPreferences() async {
    let d = UserDefaults.standard
    let enabled = d.bool(forKey: PrefKey.reminderEnabled)
    let freq = ReminderFrequency(rawValue: d.string(forKey: PrefKey.reminderFrequency) ?? "")
        ?? .weekly
    // Default to 10:00 when unset.
    let hour = d.object(forKey: PrefKey.reminderHour) as? Int ?? 10
    let minute = d.object(forKey: PrefKey.reminderMinute) as? Int ?? 0
    await ReminderScheduler.shared.reschedule(
        enabled: enabled, frequency: freq, hour: hour, minute: minute)
}

/// Resets every LeftSpace preference to its default. Files are never touched.
@MainActor
func resetAllSettings() {
    let d = UserDefaults.standard
    [PrefKey.reminderEnabled, PrefKey.reminderFrequency, PrefKey.reminderHour,
     PrefKey.reminderMinute, PrefKey.showMenuBarIcon, PrefKey.showDockIcon,
     PrefKey.permanentDelete, PrefKey.scanPersonalFolders,
     PrefKey.scanAppLeftovers].forEach { d.removeObject(forKey: $0) }
    applyDockPolicy()
    Task { await applyReminderPreferences() }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            RemindersSettingsView()
                .tabItem { Label("Reminders", systemImage: "bell") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
            SupportSettingsView()
                .tabItem { Label("Support", systemImage: "lifepreserver") }
        }
        // One fixed, compact size for every tab so the window never resizes.
        .frame(width: 460, height: 400)
    }
}

// MARK: - General (setup: permissions + how it appears)

struct GeneralSettingsView: View {
    @AppStorage(PrefKey.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(PrefKey.permanentDelete) private var permanentDelete = false
    @AppStorage(PrefKey.scanPersonalFolders) private var scanPersonalFolders = false
    @AppStorage(PrefKey.scanAppLeftovers) private var scanAppLeftovers = false
    @State private var fullDiskAccessGranted = FullDiskAccess.isGranted()
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var showPermanentConfirm = false
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Full Disk Access") {
                    HStack(spacing: 8) {
                        if fullDiskAccessGranted {
                            Label("Granted", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .labelStyle(.titleAndIcon)
                                .font(.callout)
                        }
                        Button("Open Settings…") {
                            if let url = URL(string: FullDiskAccess.settingsURLString) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }

                Toggle("Open LeftSpace at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in launchAtLogin = on; LoginItem.setEnabled(on) }
                ))

                Toggle("Show menu bar widget", isOn: $showMenuBarIcon)

                Toggle("Scan Documents, Desktop and Downloads", isOn: $scanPersonalFolders)

                Toggle("Find leftovers from removed apps", isOn: $scanAppLeftovers)

                Toggle("Delete permanently (skip the Trash)", isOn: Binding(
                    get: { permanentDelete },
                    set: { wantsOn in
                        if wantsOn { showPermanentConfirm = true } else { permanentDelete = false }
                    }
                ))
                .alert("Delete permanently instead of using the Trash?",
                       isPresented: $showPermanentConfirm) {
                    Button("Turn On Permanent Delete", role: .destructive) { permanentDelete = true }
                    Button("Cancel", role: .cancel) { permanentDelete = false }
                } message: {
                    Text("Everything LeftSpace removes will be erased immediately and cannot be recovered. You can switch it back off at any time.")
                }

                HStack {
                    Spacer()
                    Button("Reset all settings…", role: .destructive) { showResetConfirm = true }
                        .alert("Reset all settings to defaults?", isPresented: $showResetConfirm) {
                            Button("Reset", role: .destructive) { resetAllSettings() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This only resets LeftSpace's preferences. It does not touch any of your files.")
                        }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            fullDiskAccessGranted = FullDiskAccess.isGranted()
            launchAtLogin = LoginItem.isEnabled
        }
    }
}

// MARK: - Reminders

struct RemindersSettingsView: View {
    @AppStorage(PrefKey.reminderEnabled) private var enabled = false
    @AppStorage(PrefKey.reminderFrequency) private var frequencyRaw = ReminderFrequency.weekly.rawValue
    @AppStorage(PrefKey.reminderHour) private var hour = 10
    @AppStorage(PrefKey.reminderMinute) private var minute = 0
    @State private var permissionDenied = false

    private var frequency: ReminderFrequency {
        ReminderFrequency(rawValue: frequencyRaw) ?? .weekly
    }

    var body: some View {
        Form {
            Section {
                Toggle("Remind me to clear space", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in apply() }

                if enabled {
                    Picker("How often", selection: $frequencyRaw) {
                        ForEach(ReminderFrequency.allCases) { f in
                            Text(f.isRecommended ? "\(f.title)  (Recommended)" : f.title)
                                .tag(f.rawValue)
                        }
                    }
                    .onChange(of: frequencyRaw) { _, _ in apply() }

                    Text(frequency.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    DatePicker(
                        "At",
                        selection: Binding(
                            get: { timeAsDate() },
                            set: { setTime(from: $0) }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    .onChange(of: hour) { _, _ in apply() }
                    .onChange(of: minute) { _, _ in apply() }
                }
            } header: {
                Text("Cache reminders")
            } footer: {
                if permissionDenied {
                    Label("Notifications are turned off for LeftSpace in System Settings → Notifications.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if enabled {
                Section {
                    LabeledContent("Notification permissions") {
                        Button("Open Settings…") {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func apply() {
        Task {
            await applyReminderPreferences()
            if enabled {
                permissionDenied = (await ReminderScheduler.shared.authorizationStatus == .denied)
            } else {
                permissionDenied = false
            }
        }
    }

    private func timeAsDate() -> Date {
        Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
    }
    private func setTime(from date: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        hour = c.hour ?? 10
        minute = c.minute ?? 0
    }
}

// MARK: - About

struct AboutSettingsView: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                AppIconColorView(size: 46)
                Text("LeftSpace")
                    .font(.headline)
                Text(version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("One app that cleans the everyday junk and the developer junk — so a developer doesn't need five tools, and a regular user still gets value.")
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                Text("Hi! 👋 I'm Bhathiya.")
                    .font(.callout.weight(.medium))
                Text("I'm not a developer. I'm a problem solver. I love turning ideas into simple tools that make life easier. I built this app because I kept running out of space while hidden junk piled up. So I made something that finds it and clears it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            if let mailto = URL(string: "mailto:bhathiyaapps@gmail.com?subject=Storage%20Cleaner%20feedback") {
                Link(destination: mailto) {
                    Label("bhathiyaapps@gmail.com", systemImage: "envelope")
                        .font(.caption)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
    }
}

// MARK: - Support (donations)

/// Where the "support" button sends people. This is the ONE place to edit.
///
/// Set `handle` to your Buy Me a Coffee username — the `buymeacoffee.com/___`
/// part. While it's left as the placeholder, the Support tab shows a friendly
/// "not set up yet" note instead of a dead button.
enum DonationConfig {
    /// Buy Me a Coffee handle — the buymeacoffee.com/___ part.
    static let handle = "bhathiya"

    static var isConfigured: Bool { handle != "your-handle" && !handle.isEmpty }
    static var url: URL? { URL(string: "https://www.buymeacoffee.com/\(handle)") }
}

struct SupportSettingsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("Support LeftSpace")
                .font(.title3.weight(.semibold))

            Text("LeftSpace is free. If it reclaimed some space for you, a small tip helps keep it maintained and improving.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if DonationConfig.isConfigured, let url = DonationConfig.url {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    if let buttonImage = AppArtwork.buyMeACoffeeButton {
                        Image(nsImage: buttonImage)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 48)
                    } else {
                        Label("Buy me a coffee", systemImage: "heart.fill")
                            .font(.headline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                    }
                }
                .buttonStyle(.plain)
                .help("Open buymeacoffee.com/\(DonationConfig.handle)")
            } else {
                Label("Donations aren't set up yet.", systemImage: "wrench.and.screwdriver")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer()

            if let mailto = URL(string: "mailto:bhathiyaapps@gmail.com?subject=Storage%20Cleaner%20feedback") {
                Link(destination: mailto) {
                    Label("bhathiyaapps@gmail.com", systemImage: "envelope")
                        .font(.caption)
                }
            }

            Text("Thank you 🙏")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
