import AppKit
import Foundation
import UserNotifications

struct NotificationPermission: Equatable {
    enum Authorization { case notDetermined, denied, authorized, provisional, unavailable }
    var authorization: Authorization
    var alertsEnabled = true
    var canSchedule: Bool { authorization == .authorized || authorization == .provisional }
}

struct SessionReminder {
    let id: String
    let fireAt: Date
    let title: String
    let body: String
}

enum ReminderPreference: Equatable {
    case sessions
    case fantasyTeamLock
}

@MainActor
protocol NotificationServicing {
    func permission() async -> NotificationPermission
    func requestPermission() async throws
    func add(_ reminder: SessionReminder) async throws
    func removeAllPending()
    func removePending(ids: [String])
    func openSystemSettings() -> Bool
}

@MainActor
private struct SystemNotificationService: NotificationServicing {
    func permission() async -> NotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let authorization: NotificationPermission.Authorization
        switch settings.authorizationStatus {
        case .notDetermined: authorization = .notDetermined
        case .denied: authorization = .denied
        case .authorized: authorization = .authorized
        case .provisional: authorization = .provisional
        default: authorization = .unavailable
        }
        return NotificationPermission(authorization: authorization, alertsEnabled: settings.alertSetting == .enabled)
    }

    func requestPermission() async throws {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func add(_ reminder: SessionReminder) async throws {
        let interval = reminder.fireAt.timeIntervalSinceNow
        guard interval > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
    }

    func removeAllPending() { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }
    func removePending(ids: [String]) { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids) }
    func openSystemSettings() -> Bool {
        if let notifications = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
           NSWorkspace.shared.open(notifications) {
            return true
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else { return false }
        return NSWorkspace.shared.open(url)
    }
}

@MainActor
final class NotificationController: ObservableObject {
    private let settings: SettingsStore
    private let service: any NotificationServicing
    private var scheduleID = UUID()
    private var permissionRevision = 0
    private var pendingPreference: ReminderPreference?
    let isAvailable: Bool

    @Published private(set) var permission: NotificationPermission?
    @Published private(set) var isRequesting = false
    @Published private(set) var errorMessage: String?

    init(settings: SettingsStore, service: (any NotificationServicing)? = nil, isAppBundle: Bool = Bundle.main.bundleURL.pathExtension == "app") {
        self.settings = settings
        self.service = service ?? SystemNotificationService()
        isAvailable = isAppBundle
    }

    var canSchedule: Bool { isAvailable && permission?.canSchedule == true }
    var needsIntroduction: Bool { permission?.authorization == .notDetermined }
    var isBlocked: Bool { permission?.authorization == .denied }
    var shouldShowSystemSettings: Bool {
        guard let permission else { return false }
        switch permission.authorization {
        case .denied, .unavailable: return true
        case .authorized, .provisional: return !permission.alertsEnabled
        case .notDetermined: return false
        }
    }

    var statusMessage: String {
        guard isAvailable else { return "Open the installed F1 Live app to enable reminders." }
        guard let permission else { return "Checking notification permission…" }
        switch permission.authorization {
        case .notDetermined:
            return "Enable a reminder to choose whether F1 Live can send notifications."
        case .denied:
            return "Blocked by macOS. Open System Settings → Notifications → F1 Live and allow notifications."
        case .unavailable:
            return "Notification permission is unavailable. Check System Settings → Notifications → F1 Live."
        case .authorized, .provisional:
            if !permission.alertsEnabled {
                return "Notifications are allowed, but banners are off. You can change this in System Settings → Notifications → F1 Live."
            }
            return settings.hasReminderSelections ? "Reminders are enabled for your selections." : "Reminders are off."
        }
    }

    func refreshStatus() async {
        guard isAvailable else { return }
        permissionRevision += 1
        let revision = permissionRevision
        let latest = await service.permission()
        guard revision == permissionRevision else { return }
        if permission != latest { errorMessage = nil }
        permission = latest
        settings.applyNotificationDefaultIfNeeded(authorized: latest.canSchedule)
        if latest.canSchedule, let pendingPreference {
            self.pendingPreference = nil
            setPreference(pendingPreference, enabled: true)
        }
    }

    // Called only after the user turns on a reminder preference.
    func enableReminders(for preference: ReminderPreference = .sessions) async {
        guard isAvailable, !isRequesting else { return }
        isRequesting = true
        errorMessage = nil
        defer { isRequesting = false }
        await refreshStatus()
        let wasNotDetermined = needsIntroduction
        do {
            if wasNotDetermined {
                try await service.requestPermission()
                await refreshStatus()
            }
            if canSchedule {
                setPreference(preference, enabled: true)
            } else if !wasNotDetermined && shouldShowSystemSettings {
                pendingPreference = preference
                openSystemSettings()
            }
        } catch {
            errorMessage = "Couldn’t request notification permission. \(error.localizedDescription)"
        }
    }

    func disableReminders(for preference: ReminderPreference = .sessions) {
        if pendingPreference == preference { pendingPreference = nil }
        setPreference(preference, enabled: false)
        clear()
    }

    private func setPreference(_ preference: ReminderPreference, enabled: Bool) {
        switch preference {
        case .sessions: settings.notifications = enabled
        case .fantasyTeamLock: settings.fantasyTeamLockReminders = enabled
        }
    }

    func openSystemSettings() {
        guard isAvailable else { return }
        if !service.openSystemSettings() {
            errorMessage = "Open System Settings manually, then choose Notifications → F1 Live."
        }
    }

    func clear() {
        scheduleID = UUID()
        guard isAvailable else { return }
        service.removeAllPending()
    }

    func schedule(data: DashboardData, now: Date) async {
        guard isAvailable else { return }
        let revision = UUID()
        scheduleID = revision
        await refreshStatus()
        guard scheduleID == revision else { return }
        guard settings.hasReminderSelections, canSchedule else { clear(); return }
        let reminders = NotificationScheduler.reminders(data: data, settings: settings, now: now)
        service.removeAllPending()
        errorMessage = nil
        for reminder in reminders {
            guard scheduleID == revision, settings.hasReminderSelections else { return }
            // Unique batch IDs let an in-flight, cancelled request be removed
            // without deleting its replacement from a newer scheduling pass.
            let request = SessionReminder(id: "f1live.\(revision).\(reminder.id)", fireAt: reminder.fireAt, title: reminder.title, body: reminder.body)
            do {
                try await service.add(request)
            } catch {
                if scheduleID == revision { errorMessage = "Some reminders couldn’t be scheduled. Try Refresh Now." }
            }
            if scheduleID != revision || !settings.hasReminderSelections {
                service.removePending(ids: [request.id])
                return
            }
        }
    }
}

@MainActor
enum NotificationScheduler {
    static func reminders(data: DashboardData, settings: SettingsStore, now: Date) -> [SessionReminder] {
        let races = [data.race].compactMap { $0 } + data.upcoming
        var requests: [SessionReminder] = []
        if settings.notifications {
            let sessions = races.flatMap(\.sessions)
                .filter { $0.startAt > now && settings.includes($0) }
            for session in sessions {
                for lead in settings.leadMinutes {
                    let fireAt = session.startAt.addingTimeInterval(-TimeInterval(lead) * .minute)
                    if fireAt > now {
                        requests.append(SessionReminder(id: "\(session.id)-lead-\(lead)", fireAt: fireAt, title: "\(session.name) in \(lead) minutes", body: "Get ready for the next Formula 1 session."))
                    }
                }
                requests.append(SessionReminder(id: "\(session.id)-start", fireAt: session.startAt, title: "\(session.name) is starting", body: "Open F1 Live from the menu bar for the latest session status."))
                requests.append(SessionReminder(id: "\(session.id)-end", fireAt: session.endAt, title: "\(session.name) scheduled finish", body: "Results and standings will refresh automatically."))
            }
        }
        if settings.fantasyTeamLockReminders {
            for race in races {
                guard let deadline = race.fantasyLockSession, deadline.startAt > now else { continue }
                for lead in [1_440, 60] {
                    let fireAt = deadline.startAt.addingTimeInterval(-TimeInterval(lead) * .minute)
                    let leadText = lead == 1_440 ? "24 hours" : "1 hour"
                    requests.append(SessionReminder(
                        id: "fantasy-\(race.id)-lead-\(lead)",
                        fireAt: fireAt,
                        title: "F1 Fantasy locks in \(leadText)",
                        body: "Set your team for the \(race.name) before \(deadline.name) begins."
                    ))
                }
            }
        }
        return Array(requests.filter { $0.fireAt.timeIntervalSince(now) > 1 }.sorted { $0.fireAt < $1.fireAt }.prefix(60))
    }
}
