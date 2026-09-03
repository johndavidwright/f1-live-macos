import Foundation

@MainActor
enum NotificationSelfTests {
    static func run() async throws {
        try await firstUseAndOptIn()
        try await deniedAndExternalChanges()
        try await existingPreferences()
        try await errorsAndUnbundledExecution()
        try await cancelledAndOverlappingSchedules()
        try reminderPlanAndBugReport()
    }

    static func firstUseAndOptIn() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        try check(!fixture.settings.notifications, "new installations default to no notifications")
        await controller.refreshStatus()
        await controller.schedule(data: fixture.data, now: fixture.now)
        try check(fixture.service.permissionRequests == 0 && fixture.service.pending.isEmpty, "startup and scheduling never ask permission")
        try check(controller.needsIntroduction, "first-use permission needs an introduction")
        await controller.enableReminders()
        try check(fixture.service.permissionRequests == 1 && fixture.settings.notifications && controller.canSchedule, "explicit opt-in requests permission and enables reminders")
        await controller.schedule(data: fixture.data, now: fixture.now)
        try check(fixture.service.pending.count == 4, "selected lead times, start, and finish are scheduled")
        controller.disableReminders()
        try check(!fixture.settings.notifications && fixture.service.pending.isEmpty, "disabling removes all pending reminders")
    }

    static func deniedAndExternalChanges() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.service.permissionAfterRequest = .denied
        await fixture.controller.enableReminders()
        try check(fixture.controller.isBlocked && !fixture.controller.canSchedule && !fixture.settings.notifications, "denied permission is displayed without enabling reminders")
        await fixture.controller.enableReminders()
        try check(fixture.service.permissionRequests == 1, "denied permission is not requested repeatedly")
        fixture.controller.openSystemSettings()
        try check(fixture.service.openSettingsCalls == 1, "permission recovery opens System Settings")
        fixture.service.currentPermission.authorization = .authorized
        await fixture.controller.refreshStatus()
        try check(fixture.controller.canSchedule && !fixture.settings.notifications, "external approval does not override an explicit off preference")
        await fixture.controller.enableReminders()
        await fixture.controller.schedule(data: fixture.data, now: fixture.now)
        fixture.service.currentPermission.authorization = .denied
        await fixture.controller.schedule(data: fixture.data, now: fixture.now)
        try check(fixture.controller.isBlocked && fixture.service.pending.isEmpty, "external revocation stops reminders")
        fixture.service.currentPermission = NotificationPermission(authorization: .authorized, alertsEnabled: false)
        await fixture.controller.refreshStatus()
        try check(fixture.controller.statusMessage.contains("banners are off"), "disabled banners have clear guidance")
    }

    static func existingPreferences() async throws {
        let legacy = Fixture()
        defer { legacy.cleanUp() }
        legacy.service.currentPermission.authorization = .authorized
        await legacy.controller.refreshStatus()
        try check(legacy.settings.notifications && legacy.service.permissionRequests == 0, "existing authorized users retain implicit default-on reminders")
        let disabled = Fixture()
        defer { disabled.cleanUp() }
        disabled.settings.notifications = false
        disabled.service.currentPermission.authorization = .authorized
        await disabled.controller.refreshStatus()
        try check(!disabled.settings.notifications, "explicitly disabled reminders stay disabled")
    }

    static func errorsAndUnbundledExecution() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.service.failPermissionRequest = true
        await fixture.controller.enableReminders()
        try check(fixture.controller.errorMessage != nil && !fixture.settings.notifications && !fixture.controller.isRequesting, "permission errors are recoverable")
        fixture.service.failPermissionRequest = false
        await fixture.controller.enableReminders()
        fixture.service.failAdding = true
        await fixture.controller.schedule(data: fixture.data, now: fixture.now)
        try check(fixture.controller.errorMessage != nil, "scheduling failures are reported")
        let unavailableService = FakeNotificationService()
        let unavailable = NotificationController(settings: fixture.settings, service: unavailableService, isAppBundle: false)
        await unavailable.refreshStatus()
        await unavailable.enableReminders()
        await unavailable.schedule(data: fixture.data, now: fixture.now)
        unavailable.clear()
        unavailable.openSystemSettings()
        try check(!unavailable.canSchedule && unavailableService.serviceCalls == 0, "command-line self-tests cannot change real notifications")
    }

    static func cancelledAndOverlappingSchedules() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.service.currentPermission.authorization = .authorized
        await fixture.controller.refreshStatus()
        fixture.service.beforeAdd = { fixture.controller.disableReminders() }
        await fixture.controller.schedule(data: fixture.data, now: fixture.now)
        try check(fixture.service.pending.isEmpty, "an in-flight add cannot resurrect disabled reminders")

        await fixture.controller.enableReminders()
        fixture.service.beforeAdd = { await fixture.controller.schedule(data: fixture.data, now: fixture.now) }
        await fixture.controller.schedule(data: fixture.data, now: fixture.now)
        try check(fixture.service.pending.count == 4, "overlapping scheduling passes leave exactly one current set")
    }

    static func reminderPlanAndBugReport() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.settings.notifyLeadMinutes = "30, 30, invalid, -1, 15, 2000"
        let reminders = NotificationScheduler.reminders(data: fixture.data, settings: fixture.settings, now: fixture.now)
        try check(reminders.count == 4 && reminders.allSatisfy { $0.fireAt > fixture.now }, "invalid and duplicate lead times are filtered")
        fixture.settings.notifyRace = false
        try check(NotificationScheduler.reminders(data: fixture.data, settings: fixture.settings, now: fixture.now).isEmpty, "unselected session types are excluded")
        let url = SupportLinks.bugReportURL(version: "0.2.2 (4) & test", macOS: "macOS 14")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        try check(url.scheme == "https" && url.host == "github.com" && url.path == "/johndavidwright/f1-live-macos/issues/new", "bug reports open the correct GitHub draft")
        try check(components.queryItems?.count == 1 && components.queryItems?.first?.value?.contains("0.2.2 (4) & test") == true, "bug-report metadata is safely encoded")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        if !condition() { throw SelfTestError.failed(label) }
    }

    @MainActor
    private final class Fixture {
        let suite = "F1LiveNotificationTests.\(UUID())"
        let defaults: UserDefaults
        let settings: SettingsStore
        let service = FakeNotificationService()
        let controller: NotificationController
        let now = Date(timeIntervalSince1970: 10_000)
        let data: DashboardData

        init() {
            defaults = UserDefaults(suiteName: suite)!
            settings = SettingsStore(defaults: defaults)
            controller = NotificationController(settings: settings, service: service, isAppBundle: true)
            let race = Race(season: "2026", round: 13, name: "Italian Grand Prix", wikiURL: nil, circuitID: "monza", circuitName: "Monza", circuitURL: nil, locality: "Monza", country: "Italy", latitude: nil, longitude: nil, sessions: [RaceSession(key: "race", shortName: "RACE", name: "Race", group: "Race", startAt: now.addingTimeInterval(.hour), endAt: now.addingTimeInterval(3 * .hour), dateOnly: false, exactEnd: true, sessionKey: 42)], meetingKey: nil)
            data = DashboardData(races: [race], raceIndex: 0, standings: [], qualifying: nil, raceDistance: nil, stale: false, lastUpdatedAt: now)
        }

        func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    }
}

@MainActor
private final class FakeNotificationService: NotificationServicing {
    var currentPermission = NotificationPermission(authorization: .notDetermined)
    var permissionAfterRequest = NotificationPermission.Authorization.authorized
    var permissionRequests = 0
    var openSettingsCalls = 0
    var serviceCalls = 0
    var failPermissionRequest = false
    var failAdding = false
    var pending: [String: SessionReminder] = [:]
    var beforeAdd: (() async -> Void)?

    func permission() async -> NotificationPermission { serviceCalls += 1; return currentPermission }
    func requestPermission() async throws {
        serviceCalls += 1
        permissionRequests += 1
        if failPermissionRequest { throw SelfTestError.failed("Simulated permission error") }
        currentPermission.authorization = permissionAfterRequest
    }
    func add(_ reminder: SessionReminder) async throws {
        serviceCalls += 1
        if failAdding { throw SelfTestError.failed("Simulated scheduling error") }
        let action = beforeAdd
        beforeAdd = nil
        await action?()
        pending[reminder.id] = reminder
    }
    func removeAllPending() { serviceCalls += 1; pending.removeAll() }
    func removePending(ids: [String]) { serviceCalls += 1; for id in ids { pending.removeValue(forKey: id) } }
    func openSystemSettings() -> Bool { serviceCalls += 1; openSettingsCalls += 1; return true }
}
