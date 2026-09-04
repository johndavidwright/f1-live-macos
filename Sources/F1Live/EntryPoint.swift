import AppKit
import Foundation
import SwiftUI

@main
enum EntryPoint {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--self-test") {
            do {
                try await SelfTests.run()
                print("Self-tests passed (core, login items, live timing, notifications, F1 Fantasy, and support links).")
            } catch {
                fputs("Self-test failed: \(error)\n", stderr)
                Foundation.exit(1)
            }
            return
        }

        if CommandLine.arguments.contains("--api-smoke-test") {
            do {
                let api = F1API()
                let data = try await api.loadDashboard(refreshMinutes: 15, force: true)
                guard let race = data.race else { throw SelfTestError.failed("API returned no current race") }
                var liveSummary = ""
                if data.raceIndex > 0,
                   let historical = data.races[data.raceIndex - 1].raceSession,
                   let key = historical.sessionKey {
                    let sampleAt = historical.startAt.addingTimeInterval(60 * .minute)
                    let batch = try await api.loadLive(sessionKey: key, refreshSeconds: 12, currentLap: 1, includeSlow: true, now: sampleAt)
                    guard !(batch.drivers ?? [:]).isEmpty, !batch.positions.isEmpty else {
                        throw SelfTestError.failed("historical live feed returned no drivers or positions")
                    }
                    liveSummary = "; \(batch.positions.count) live positions sampled"
                }
                print("API smoke test passed: \(race.season) round \(race.round), \(race.name); \(data.standings.count) drivers; \(race.sessions.count) sessions\(liveSummary).")
            } catch {
                fputs("API smoke test failed: \(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
            return
        }

        if CommandLine.arguments.contains("--preview-window") {
            let previewDefaults = UserDefaults(suiteName: "F1LivePreview.\(ProcessInfo.processInfo.processIdentifier)")!
            previewDefaults.set(false, forKey: "notifications")
            previewDefaults.set(false, forKey: "fantasyTeamLockReminders")
            previewDefaults.set(true, forKey: "showFantasyLock")
            let settings = SettingsStore(defaults: previewDefaults)
            let store = AppStore(settings: settings)
            let updates = UpdateController()
            let view = DashboardView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(updates)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: DashboardView.windowWidth, height: DashboardView.windowHeight),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "F1 Live Preview"
            window.contentViewController = NSHostingController(rootView: view)
            window.center()
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            store.start()
            NSApp.run()
            previewDefaults.removePersistentDomain(forName: "F1LivePreview.\(ProcessInfo.processInfo.processIdentifier)")
            return
        }

        F1LiveApp.main()
    }
}

enum SelfTestError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return message } }
}

@MainActor
enum SelfTests {
    static func run() async throws {
        let start = Date(timeIntervalSince1970: 10_000)
        let session = RaceSession(key: "race", shortName: "RACE", name: "Race", group: "Race", startAt: start, endAt: start.addingTimeInterval(100), dateOnly: false, exactEnd: true, sessionKey: 42)
        try check(session.state(at: start.addingTimeInterval(-3_601)) == .upcoming, "far-future session state")
        try check(session.state(at: start.addingTimeInterval(-60)) == .soon, "soon session state")
        try check(session.state(at: start) == .live, "live session state")
        try check(session.state(at: start.addingTimeInterval(100)) == .done, "finished session state")

        let race = fixtureRace(start: start)
        let finish = race.raceSession!.endAt
        try check(F1API.currentRaceIndex(in: [race], at: finish.addingTimeInterval(.day - 1)) == 0, "post-race visibility")
        try check(F1API.currentRaceIndex(in: [race], at: finish.addingTimeInterval(.day)) == -1, "season completion")

        let exactStart = race.raceStartAt.addingTimeInterval(120)
        let refined = F1API.refine(race, with: [OpenF1Session(sessionKey: 99, meetingKey: 10, type: "Race", name: "Race", startAt: exactStart, endAt: exactStart.addingTimeInterval(7_200))])
        try check(refined.raceSession?.sessionKey == 99 && refined.raceSession?.exactEnd == true, "OpenF1 schedule refinement")

        var timing = LiveTimingState()
        let newer = Date(timeIntervalSince1970: 20_000)
        timing.merge(LiveBatch(positions: [TimedPosition(driverNumber: 1, position: 2, at: newer)], intervals: [], drivers: nil, pits: nil, currentLap: nil, raceControl: nil), polledAt: newer)
        timing.merge(LiveBatch(positions: [TimedPosition(driverNumber: 1, position: 8, at: start)], intervals: [], drivers: nil, pits: nil, currentLap: nil, raceControl: nil), polledAt: newer)
        try check(timing.rows.first?.position == 2, "out-of-order live timing")

        try check(LiveTimingState.gapText("1.2", leader: false) == "+1.200", "numeric gap formatting")
        try check(CircuitMaps.filename(for: race) == "monza-7.svg", "circuit map lookup")
        try check(
            F1Formatting.countdown(to: start.addingTimeInterval(.day + 3 * .hour), from: start, compact: true) == "1d 3h",
            "compact countdown includes hours"
        )

        let suiteName = "F1LiveSelfTests.\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("Verstappen", forKey: "highlightDriver")
        let settings = SettingsStore(defaults: defaults)
        let drivers = [
            DriverStanding(position: 1, points: 250, wins: 6, driverID: "norris", code: "NOR", givenName: "Lando", familyName: "Norris", constructorID: "mclaren", constructorName: "McLaren"),
            DriverStanding(position: 3, points: 183, wins: 1, driverID: "hamilton", code: "HAM", givenName: "Lewis", familyName: "Hamilton", constructorID: "ferrari", constructorName: "Ferrari"),
            DriverStanding(position: 6, points: 112, wins: 1, driverID: "max_verstappen", code: "VER", givenName: "Max", familyName: "Verstappen", constructorID: "red_bull", constructorName: "Red Bull")
        ]
        settings.migrateLegacyFavoriteIfNeeded(from: drivers)
        try check(settings.isFavorite("max_verstappen"), "legacy favorite migration")
        settings.setFavorite("norris", enabled: true)
        try check(settings.favoriteDriverIDs == Set(["norris", "max_verstappen"]), "multiple driver favorites")
        defaults.removePersistentDomain(forName: suiteName)

        let freshSuiteName = "F1LiveFreshInstallTests.\(ProcessInfo.processInfo.processIdentifier)"
        let freshDefaults = UserDefaults(suiteName: freshSuiteName)!
        freshDefaults.removePersistentDomain(forName: freshSuiteName)
        let freshSettings = SettingsStore(defaults: freshDefaults)
        freshSettings.migrateLegacyFavoriteIfNeeded(from: drivers)
        try check(freshSettings.favoriteDriverIDs == Set(["hamilton"]), "Lewis Hamilton is the first-run favorite")
        freshDefaults.removePersistentDomain(forName: freshSuiteName)

        try LoginItemSelfTests.run()
        try LiveTimingSelfTests.run()
        try await MenuBarSelfTests.sessionEndRestoresCountdown()
        try await F1APISelfTests.run()
        try await OpenF1AuthSelfTests.run()
        try await NotificationSelfTests.run()
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        if !condition() { throw SelfTestError.failed(label) }
    }

    private static func fixtureRace(start: Date) -> Race {
        Race(
            season: "2026", round: 13, name: "Italian Grand Prix", wikiURL: nil,
            circuitID: "monza", circuitName: "Autodromo Nazionale di Monza", circuitURL: nil,
            locality: "Monza", country: "Italy", latitude: nil, longitude: nil,
            sessions: [RaceSession(key: "race", shortName: "RACE", name: "Race", group: "Race", startAt: start, endAt: start.addingTimeInterval(7_200), dateOnly: false, exactEnd: false, sessionKey: nil)], meetingKey: nil
        )
    }
}
