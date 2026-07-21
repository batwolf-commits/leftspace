import Foundation
import UserNotifications

/// How often to remind the user to clear out cache/leftovers.
///
/// Recommendation baked into the UI: **Weekly** is the sweet spot — caches rebuild
/// slowly, so daily is noisy, while monthly lets tens of gigabytes pile back up
/// (as this machine showed). Weekly keeps things tidy without nagging.
enum ReminderFrequency: String, CaseIterable, Identifiable {
    case daily
    case twiceWeekly
    case weekly
    case biweekly
    case monthly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily:       return "Every day"
        case .twiceWeekly: return "Twice a week"
        case .weekly:      return "Every week"
        case .biweekly:    return "Every 2 weeks"
        case .monthly:     return "Every month"
        }
    }

    /// One-line guidance shown under each choice.
    var hint: String {
        switch self {
        case .daily:       return "Best if you install/build a lot daily. Can feel frequent."
        case .twiceWeekly: return "Mondays & Thursdays. Good for heavy developer use."
        case .weekly:      return "Recommended — tidy without nagging."
        case .biweekly:    return "Light-touch. Every fortnight."
        case .monthly:     return "Minimal. Space can build up between reminders."
        }
    }

    var isRecommended: Bool { self == .weekly }
}

/// Schedules the recurring local notification that reminds the user to scan.
///
/// Uses `UNUserNotificationCenter`. Requires the app to run as a signed bundle
/// (it does) — notifications will not appear when run via `swift run`. All pending
/// reminders are cleared and re-added on every settings change so there is never a
/// stale schedule.
@MainActor
final class ReminderScheduler {
    static let shared = ReminderScheduler()

    private let center = UNUserNotificationCenter.current()
    private let idPrefix = "com.storagecleaner.cache-reminder"

    private init() {}

    /// Ask for permission if we don't already have it. Returns whether we may post.
    func requestAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }

    var authorizationStatus: UNAuthorizationStatus {
        get async { await center.notificationSettings().authorizationStatus }
    }

    /// Apply the current preference. Clears existing reminders first; if disabled,
    /// leaves nothing scheduled.
    func reschedule(enabled: Bool, frequency: ReminderFrequency, hour: Int, minute: Int) async {
        await removeAll()
        guard enabled else { return }
        guard await requestAuthorization() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Time to free up space"
        content.body = "Scan your Mac for caches and leftovers you can safely clear."
        content.sound = .default

        for (index, trigger) in triggers(for: frequency, hour: hour, minute: minute).enumerated() {
            let request = UNNotificationRequest(
                identifier: "\(idPrefix).\(index)",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    func removeAll() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Build the trigger(s) for a frequency. Calendar triggers repeat at a fixed
    /// time; "twice a week" needs two, and "every 2 weeks" isn't expressible as a
    /// repeating calendar match, so it uses a 14-day interval trigger.
    private func triggers(for frequency: ReminderFrequency, hour: Int, minute: Int) -> [UNNotificationTrigger] {
        func calendar(weekday: Int? = nil, day: Int? = nil) -> UNCalendarNotificationTrigger {
            var dc = DateComponents()
            dc.hour = hour
            dc.minute = minute
            dc.weekday = weekday
            dc.day = day
            return UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
        }

        switch frequency {
        case .daily:
            return [calendar()]
        case .weekly:
            return [calendar(weekday: 2)]                 // Monday
        case .twiceWeekly:
            return [calendar(weekday: 2), calendar(weekday: 5)] // Mon & Thu
        case .monthly:
            return [calendar(day: 1)]                     // 1st of the month
        case .biweekly:
            return [UNTimeIntervalNotificationTrigger(timeInterval: 14 * 24 * 3600, repeats: true)]
        }
    }
}
