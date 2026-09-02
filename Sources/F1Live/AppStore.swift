import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    @Published var useTwelveHourTime: Bool { didSet { defaults.set(useTwelveHourTime, forKey: "useTwelveHourTime") } }
    @Published var autoLive: Bool { didSet { defaults.set(autoLive, forKey: "autoLive") } }
    @Published var liveRefreshSeconds: Int { didSet { defaults.set(liveRefreshSeconds, forKey: "liveRefreshSeconds") } }
    @Published var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") } }
    @Published var notifications: Bool { didSet { defaults.set(notifications, forKey: "notifications") } }
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
        autoLive = defaults.object(forKey: "autoLive") as? Bool ?? true
        liveRefreshSeconds = defaults.object(forKey: "liveRefreshSeconds") as? Int ?? 12
        refreshMinutes = defaults.object(forKey: "refreshMinutes") as? Int ?? 15
        notifications = defaults.object(forKey: "notifications") as? Bool ?? true
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
    }

    var leadMinutes: [Int] {
        notifyLeadMinutes.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { (1...1_440).contains($0) }.uniqued().sorted(by: >)
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
    private let api: F1API
    private var started = false
    private var manualLiveChoice = false
    private var clockTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var settingsSubscriptions: Set<AnyCancellable> = []
    private var lastRaceID: String?

    init(settings: SettingsStore, api: F1API = F1API()) {
        self.settings = settings
        self.api = api
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
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let fresh = try await api.loadDashboard(refreshMinutes: settings.refreshMinutes, force: force, now: now)
            let raceChanged = fresh.race?.id != lastRaceID
            data = fresh
            settings.migrateLegacyFavoriteIfNeeded(from: fresh.standings)
            if raceChanged {
                lastRaceID = fresh.race?.id
                live = LiveTimingState()
                liveError = nil
                manualLiveChoice = false
            }
            applyAutoLive()
            if settings.notifications { await NotificationScheduler.schedule(data: fresh, settings: settings, now: now) }
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
    var weekend: WeekendStatus { race?.weekendStatus(at: now) ?? WeekendStatus(label: "FORMULA 1", kind: .idle, session: nil) }
    var activeFeedSession: RaceSession? { race?.liveFeedSession(at: now) }
    var menuBarTitle: String {
        if race?.liveFeedSession(at: now) != nil { return "F1 LIVE" }
        if let next = race?.nextSession(at: now) { return "F1 \(F1Formatting.countdown(to: next.startAt, from: now, compact: true))" }
        if let race { return "F1 \(F1Formatting.countdown(to: race.raceStartAt, from: now, compact: true))" }
        return isLoading ? "F1 …" : "F1"
    }

    var tooltip: String {
        guard let race else { return errorMessage ?? "F1 Live" }
        if let session = race.liveFeedSession(at: now) { return "\(race.name) — \(session.name) live" }
        if let next = race.nextSession(at: now) {
            return "\(race.name) — \(next.name) in \(F1Formatting.countdown(to: next.startAt, from: now))"
        }
        return race.name
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

    private func tick() {
        now = Date()
        applyAutoLive()
    }

    private func applyAutoLive() {
        guard settings.autoLive, !manualLiveChoice else { return }
        liveMode = race?.liveFeedSession(at: now)?.key == "race"
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
        if settings.notifications, let data {
            Task { await NotificationScheduler.schedule(data: data, settings: settings, now: now) }
        } else if !settings.notifications {
            NotificationScheduler.clear()
        }
    }

    private func pollLiveIfNeeded(force: Bool = false) async {
        guard liveMode, let session = activeFeedSession, let key = session.sessionKey, !isPollingLive else { return }
        if !force, let last = live.lastPollAt, now.timeIntervalSince(last) < TimeInterval(max(5, settings.liveRefreshSeconds) - 1) { return }
        isPollingLive = true
        defer { isPollingLive = false }
        let includeSlow = live.drivers.isEmpty || live.lastPollAt == nil || now.timeIntervalSince(live.lastPollAt!) >= 55
        do {
            let batch = try await api.loadLive(sessionKey: key, refreshSeconds: settings.liveRefreshSeconds, currentLap: live.currentLap, includeSlow: includeSlow, now: now)
            live.merge(batch, polledAt: Date())
            liveError = live.consecutiveEmptyPolls >= 3 ? "No timing data in the last few polls." : nil
        } catch {
            liveError = error.localizedDescription
        }
    }
}

enum NotificationScheduler {
    private static var hasApplicationBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    @MainActor
    static func schedule(data: DashboardData, settings: SettingsStore, now: Date) async {
        guard hasApplicationBundle else { return }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        center.removeAllPendingNotificationRequests()

        let sessions = ([data.race].compactMap { $0 } + data.upcoming).flatMap(\.sessions)
            .filter { $0.startAt > now && settings.includes($0) }
        var requests: [(String, Date, String, String)] = []
        for session in sessions {
            for lead in settings.leadMinutes {
                let fireAt = session.startAt.addingTimeInterval(-TimeInterval(lead) * .minute)
                if fireAt > now {
                    requests.append(("\(session.id)-lead-\(lead)-\(Int(session.startAt.timeIntervalSince1970))", fireAt, "\(session.name) in \(lead) minutes", "Get ready for the next Formula 1 session."))
                }
            }
            requests.append(("\(session.id)-start-\(Int(session.startAt.timeIntervalSince1970))", session.startAt, "\(session.name) is starting", "Open F1 Live from the menu bar for the latest session status."))
            if session.endAt > now {
                requests.append(("\(session.id)-end-\(Int(session.endAt.timeIntervalSince1970))", session.endAt, "\(session.name) scheduled finish", "Results and standings will refresh automatically."))
            }
        }

        for request in requests.sorted(by: { $0.1 < $1.1 }).prefix(60) {
            let content = UNMutableNotificationContent()
            content.title = request.2
            content.body = request.3
            content.sound = .default
            let interval = request.1.timeIntervalSince(now)
            guard interval > 1 else { continue }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "f1live.\(request.0)", content: content, trigger: trigger))
        }
    }

    static func clear() {
        guard hasApplicationBundle else { return }
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
