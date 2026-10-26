import AppKit
import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    @Published var useTwelveHourTime: Bool { didSet { defaults.set(useTwelveHourTime, forKey: "useTwelveHourTime") } }
    @Published var showFantasyLock: Bool { didSet { defaults.set(showFantasyLock, forKey: "showFantasyLock") } }
    @Published var autoLive: Bool { didSet { defaults.set(autoLive, forKey: "autoLive") } }
    @Published var liveRefreshSeconds: Int { didSet { defaults.set(liveRefreshSeconds, forKey: "liveRefreshSeconds") } }
    @Published var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") } }
    @Published var notifications: Bool { didSet { defaults.set(notifications, forKey: "notifications") } }
    @Published var fantasyTeamLockReminders: Bool { didSet { defaults.set(fantasyTeamLockReminders, forKey: "fantasyTeamLockReminders") } }
    @Published var notifyLeadMinutes: String { didSet { defaults.set(notifyLeadMinutes, forKey: "notifyLeadMinutes") } }
    @Published var notifyRace: Bool { didSet { defaults.set(notifyRace, forKey: "notifyRace") } }
    @Published var notifyQualifying: Bool { didSet { defaults.set(notifyQualifying, forKey: "notifyQualifying") } }
    @Published var notifySprint: Bool { didSet { defaults.set(notifySprint, forKey: "notifySprint") } }
    @Published var notifyPractice: Bool { didSet { defaults.set(notifyPractice, forKey: "notifyPractice") } }
    @Published private(set) var favoriteDriverIDs: Set<String> {
        didSet { defaults.set(favoriteDriverIDs.sorted(), forKey: "favoriteDriverIDs") }
    }
    private var needsFavoriteMigration: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        useTwelveHourTime = defaults.object(forKey: "useTwelveHourTime") as? Bool ?? false
        showFantasyLock = defaults.object(forKey: "showFantasyLock") as? Bool
            ?? (defaults.object(forKey: "fantasyTeamLockReminders") as? Bool ?? false)
        autoLive = defaults.object(forKey: "autoLive") as? Bool ?? true
        liveRefreshSeconds = defaults.object(forKey: "liveRefreshSeconds") as? Int ?? 12
        refreshMinutes = defaults.object(forKey: "refreshMinutes") as? Int ?? 15
        notifications = defaults.object(forKey: "notifications") as? Bool ?? false
        fantasyTeamLockReminders = defaults.object(forKey: "fantasyTeamLockReminders") as? Bool ?? false
        notifyLeadMinutes = defaults.string(forKey: "notifyLeadMinutes") ?? "30,15"
        notifyRace = defaults.object(forKey: "notifyRace") as? Bool ?? true
        notifyQualifying = defaults.object(forKey: "notifyQualifying") as? Bool ?? true
        notifySprint = defaults.object(forKey: "notifySprint") as? Bool ?? true
        notifyPractice = defaults.object(forKey: "notifyPractice") as? Bool ?? false
        if let storedFavorites = defaults.stringArray(forKey: "favoriteDriverIDs") {
            favoriteDriverIDs = Set(storedFavorites)
            needsFavoriteMigration = false
        } else {
            favoriteDriverIDs = []
            needsFavoriteMigration = true
        }
        // Preserve the previously visible Fantasy deadline once, then keep display
        // and notification preferences independent, including across launches.
        if defaults.object(forKey: "showFantasyLock") == nil {
            defaults.set(showFantasyLock, forKey: "showFantasyLock")
        }
    }

    var leadMinutes: [Int] {
        notifyLeadMinutes.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { (1...1_440).contains($0) }.uniqued().sorted(by: >)
    }

    var hasReminderSelections: Bool { notifications || fantasyTeamLockReminders }

    func applyNotificationDefaultIfNeeded(authorized: Bool) {
        guard defaults.object(forKey: "notifications") == nil else { return }
        // Preserve the old default-on behavior for users who already allowed
        // notifications, without opting new or previously denied users in.
        notifications = authorized
    }

    func includes(_ session: RaceSession) -> Bool {
        switch session.group {
        case "Race": return notifyRace
        case "Qualifying": return notifyQualifying
        case "Sprint": return notifySprint
        case "Practice": return notifyPractice
        default: return false
        }
    }

    func isFavorite(_ driverID: String) -> Bool {
        favoriteDriverIDs.contains(driverID)
    }

    func setFavorite(_ driverID: String, enabled: Bool) {
        if enabled { favoriteDriverIDs.insert(driverID) }
        else { favoriteDriverIDs.remove(driverID) }
    }

    func clearFavorites() {
        favoriteDriverIDs.removeAll()
    }

    func migrateLegacyFavoriteIfNeeded(from standings: [DriverStanding]) {
        guard needsFavoriteMigration else { return }
        needsFavoriteMigration = false
        let query = (defaults.string(forKey: "highlightDriver") ?? "Lewis Hamilton")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let driver = standings.first(where: {
            $0.driverID.lowercased() == query || $0.code.lowercased() == query ||
                $0.familyName.lowercased() == query || $0.fullName.lowercased().contains(query)
        }) {
            favoriteDriverIDs.insert(driver.id)
        } else {
            // Persist an explicit empty selection so migration is attempted once.
            defaults.set([String](), forKey: "favoriteDriverIDs")
        }
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var data: DashboardData?
    @Published private(set) var now = Date()
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var live = LiveTimingState()
    @Published private(set) var isPollingLive = false
    @Published private(set) var liveError: String?
    @Published var liveMode = false

    let settings: SettingsStore
    let notificationController: NotificationController
    let openF1Account: OpenF1AccountController
    private let api: F1API
    private var started = false
    private var manualLiveChoice = false
    private var clockTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var settingsSubscriptions: Set<AnyCancellable> = []
    private var lastRaceID: String?
    private var liveSessionKey: Int?
    private var completedLiveSessions: [Int: Date] = [:]
    private var refreshRequestedWhileLoading = false

    init(settings: SettingsStore, api: F1API = F1API()) {
        self.settings = settings
        self.api = api
        openF1Account = OpenF1AccountController(api: api)
        notificationController = NotificationController(settings: settings)
        settings.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] in self?.settingsDidChange() }
            .store(in: &settingsSubscriptions)
    }

    deinit {
        clockTask?.cancel()
        refreshTask?.cancel()
        liveTask?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.openF1Account.refreshStatus()
            await self.notificationController.refreshStatus()
            await self.refresh(force: false)
            while !Task.isCancelled {
                let minutes = max(5, self.settings.refreshMinutes)
                try? await Task.sleep(for: .seconds(minutes * 60))
                if !Task.isCancelled { await self.refresh(force: false) }
            }
        }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollLiveIfNeeded()
                try? await Task.sleep(for: .seconds(max(5, self.settings.liveRefreshSeconds)))
            }
        }
    }

    func refresh(force: Bool = true) async {
        guard !isLoading else {
            if force { refreshRequestedWhileLoading = true }
            return
        }
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            if refreshRequestedWhileLoading {
                refreshRequestedWhileLoading = false
                Task {
                    await self.refresh(force: true)
                    await self.pollLiveIfNeeded(force: true)
                }
            }
        }
        do {
            let fresh = try await api.loadDashboard(refreshMinutes: settings.refreshMinutes, force: force, now: now)
            updateDashboard(fresh)
            settings.migrateLegacyFavoriteIfNeeded(from: fresh.standings)
            synchronizeLiveSession()
            applyAutoLive()
            if settings.hasReminderSelections, let data { await notificationController.schedule(data: data, now: now) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleLive() {
        liveMode.toggle()
        manualLiveChoice = true
        if liveMode { Task { await pollLiveIfNeeded(force: true) } }
    }

    func setLiveMode(_ enabled: Bool) {
        liveMode = enabled
        manualLiveChoice = true
        if enabled { Task { await pollLiveIfNeeded(force: true) } }
    }

    var race: Race? { data?.race }
    var weekend: WeekendStatus {
        if let session = displayLiveSession, session.usesRaceControlEnd {
            return WeekendStatus(label: "\(session.shortName) LIVE", kind: .live, session: session)
        }
        if let session = race?.liveSession(at: now), session.usesRaceControlEnd,
           let key = session.sessionKey, completedLiveSessions[key] != nil {
            return WeekendStatus(label: "\(session.shortName) FINISHED", kind: .finished, session: session)
        }
        return race?.weekendStatus(at: now) ?? WeekendStatus(label: "FORMULA 1", kind: .idle, session: nil)
    }
    var activeFeedSession: RaceSession? {
        // A delayed race can still be running after the calendar's estimated
        // recap window. Keep discovering its feed even if the overview moved on.
        for race in data?.races.reversed() ?? [] {
            if let session = race.liveFeedSession(at: now, completedSessions: completedLiveSessions) { return session }
        }
        return nil
    }
    private var displayLiveSession: RaceSession? {
        if let scheduled = race?.liveSession(at: now) {
            if scheduled.usesRaceControlEnd, let key = scheduled.sessionKey, completedLiveSessions[key] != nil { return nil }
            return scheduled
        }
        // Extend the live label only when the feed has actually supplied data;
        // the calendar alone cannot distinguish an overrun from a finished race.
        if let session = activeFeedSession, session.usesRaceControlEnd,
           let key = session.sessionKey, completedLiveSessions[key] == nil,
           liveSessionKey == key, live.lastUpdateAt != nil || live.status.at != nil { return session }
        return nil
    }
    var liveWarning: String? {
        if let liveError { return liveError }
        if let session = activeFeedSession, session.sessionKey == nil {
            return data?.liveUnavailableReason ?? "OpenF1 session details are not available yet. They will refresh automatically."
        }
        return live.freshnessWarning(at: now, refreshSeconds: settings.liveRefreshSeconds)
    }
    private var nextMenuBarSession: (race: Race, session: RaceSession)? {
        // The dashboard briefly retains a finished race. The menu bar should
        // already count down to the next weekend, using the loaded calendar.
        for race in data?.races ?? [] {
            if let session = race.nextSession(at: now) { return (race, session) }
        }
        return nil
    }

    var menuBarTitle: String {
        // The post-session buffer collects late updates without extending the
        // live label once the session has actually finished.
        if displayLiveSession != nil { return "F1 LIVE" }
        if let next = nextMenuBarSession { return "F1 \(F1Formatting.countdown(to: next.session.startAt, from: now, compact: true))" }
        return isLoading ? "F1 …" : "F1"
    }

    var tooltip: String {
        if let race, let session = displayLiveSession { return "\(race.name) — \(session.name) live" }
        if let next = nextMenuBarSession {
            return "\(next.race.name) — \(next.session.name) in \(F1Formatting.countdown(to: next.session.startAt, from: now))"
        }
        return race?.name ?? errorMessage ?? "F1 Live"
    }

    func standingsView(limit: Int = 5) -> (top: [DriverStanding], favorites: [FavoriteStanding]) {
        let list = data?.standings ?? []
        let top = Array(list.prefix(limit))
        let topIDs = Set(top.map(\.id))
        let leaderPoints = list.first?.points ?? 0
        let favorites = list
            .filter { settings.isFavorite($0.id) && !topIDs.contains($0.id) }
            .map { FavoriteStanding(driver: $0, gapToLeader: max(0, leaderPoints - $0.points)) }
        return (top, favorites)
    }

    func tick(at time: Date = Date()) {
        now = time
        if let data { updateDashboard(data) }
        synchronizeLiveSession()
        applyAutoLive()
    }

    private func updateDashboard(_ snapshot: DashboardData) {
        let retainedRaceIndex = snapshot.races.firstIndex { race in
            guard let session = race.raceSession, let key = session.sessionKey else { return false }
            if let finishedAt = completedLiveSessions[key] {
                return now < finishedAt.addingTimeInterval(Race.postRaceWindow)
            }
            // Evidence from a running feed takes precedence over the timetable.
            return liveSessionKey == key && (live.lastUpdateAt != nil || live.status.at != nil)
                && race.liveFeedSession(at: now)?.sessionKey == key
        }
        let index = retainedRaceIndex ?? F1API.currentRaceIndex(in: snapshot.races, at: now, completedSessions: completedLiveSessions)
        let selectedRace = snapshot.races.indices.contains(index) ? snapshot.races[index] : nil
        if index == snapshot.raceIndex {
            data = snapshot
        } else {
            let previous = data?.race?.id == selectedRace?.id ? data : nil
            data = DashboardData(races: snapshot.races, raceIndex: index, standings: snapshot.standings,
                                 qualifying: previous?.qualifying, raceDistance: previous?.raceDistance,
                                 stale: snapshot.stale, lastUpdatedAt: snapshot.lastUpdatedAt,
                                 liveUnavailableReason: snapshot.liveUnavailableReason)
        }
        if selectedRace?.id != lastRaceID {
            lastRaceID = selectedRace?.id
            manualLiveChoice = false
            if selectedRace?.raceSession?.sessionKey == nil || selectedRace?.raceSession?.sessionKey != liveSessionKey {
                liveMode = false
            }
        }
    }

    private func synchronizeLiveSession() {
        let key = activeFeedSession?.sessionKey
        guard liveSessionKey != key else { return }
        liveSessionKey = key
        live = LiveTimingState()
        liveError = nil
    }

    private func applyAutoLive() {
        guard settings.autoLive, !manualLiveChoice else { return }
        liveMode = openF1Account.hasCredentials && activeFeedSession?.key == "race"
            && activeFeedSession?.sessionKey == race?.raceSession?.sessionKey
    }

    private func settingsDidChange() {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollLiveIfNeeded()
                try? await Task.sleep(for: .seconds(max(5, self.settings.liveRefreshSeconds)))
            }
        }
        if settings.hasReminderSelections, let data {
            Task { await notificationController.schedule(data: data, now: now) }
        } else {
            notificationController.clear()
        }
    }

    func refreshNotificationStatus() async {
        await notificationController.refreshStatus()
        if let data { await notificationController.schedule(data: data, now: now) }
    }

    func openF1CredentialsChanged() async {
        liveError = nil
        await refresh(force: true)
        await pollLiveIfNeeded(force: true)
    }

    func pollLiveIfNeeded(force: Bool = false) async {
        guard liveMode, let session = activeFeedSession, let key = session.sessionKey, !isPollingLive else { return }
        synchronizeLiveSession()
        if !force, let last = live.lastPollAt, now.timeIntervalSince(last) < TimeInterval(max(5, settings.liveRefreshSeconds) - 1) { return }
        isPollingLive = true
        defer { isPollingLive = false }
        let details = force ? Set(LiveDetail.allCases) : live.detailsNeedingRefresh(at: now)
        do {
            let polledAt = now
            let batch = try await api.loadLive(sessionKey: key, refreshSeconds: settings.liveRefreshSeconds, currentLap: live.currentLap,
                                             details: details, positionSince: live.positions.isEmpty ? nil : live.lastPositionPollAt, now: polledAt)
            guard !Task.isCancelled, liveSessionKey == key, activeFeedSession?.sessionKey == key else { return }
            live.merge(batch, polledAt: polledAt)
            if session.usesRaceControlEnd, live.status.kind == "finished", let finishedAt = live.status.at {
                // Keep completion outside LiveTimingState so expiring the
                // post-race buffer cannot reset it and restart the same feed.
                completedLiveSessions[key] = completedLiveSessions[key] ?? finishedAt
            }
            if let data { updateDashboard(data) }
            liveError = batch.warning
            await openF1Account.refreshStatus()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, liveSessionKey == key, activeFeedSession?.sessionKey == key else { return }
            liveError = error.localizedDescription
            await openF1Account.refreshStatus()
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
