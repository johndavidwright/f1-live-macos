import Foundation

enum MenuBarSelfTests {
    @MainActor
    static func sessionEndRestoresCountdown() async throws {
        // Exercise the menu bar through a clock tick, without a network refresh
        // or credentials. OpenF1 supplies an exact end; Jolpica alone estimates it.
        for exactEnd in [true, false] {
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let suiteName = "F1LiveMenuBarTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer {
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: cache)
            }
            let client = CachedHTTPClient(transport: { request in
                let url = request.url!
                let body: String
                if url.host == "api.jolpi.ca", url.path.contains("/races") { body = calendar }
                else if url.host == "api.openf1.org" { body = exactEnd ? sessions : "[]" }
                else { body = "[]" }
                return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, cacheDirectory: cache, auth: OpenF1Authentication(storage: MemoryOpenF1Credentials()))
            let store = AppStore(settings: SettingsStore(defaults: defaults), api: F1API(client: client))
            let start = date("2026-09-04T14:00:00Z")
            let finish = start.addingTimeInterval((exactEnd ? 60 : 65) * .minute)
            store.tick(at: start.addingTimeInterval(-1))
            await store.refresh()
            try check(store.race?.sessions.first?.exactEnd == exactEnd, "fixture uses the expected session end source")
            try check(store.menuBarTitle != "F1 LIVE", "menu bar does not label a future session live")

            for time in [start, finish.addingTimeInterval(-1)] {
                store.tick(at: time)
                try check(store.menuBarTitle == "F1 LIVE", "menu bar stays live through the final second of FP2")
                try check(store.tooltip == "Italian Grand Prix — Practice 2 live", "tooltip identifies the active session")
            }
            store.tick(at: finish)
            let countdown = exactEnd ? "F1 19h 30m" : "F1 19h 25m"
            try check(store.menuBarTitle == countdown, "menu bar returns to the FP3 countdown exactly when FP2 ends")
            try check(store.tooltip.hasPrefix("Italian Grand Prix — Practice 3 in "), "tooltip also moves to the next session")
            if exactEnd {
                try check(store.activeFeedSession?.key == "fp2", "late timing data can still arrive after the menu bar stops saying live")
            }
            store.tick(at: finish.addingTimeInterval(20 * .minute))
            try check(store.menuBarTitle != "F1 LIVE", "the timing-feed buffer never reactivates the live label")
            store.tick(at: date("2026-09-05T10:30:00Z"))
            try check(store.menuBarTitle == "F1 LIVE" && store.tooltip == "Italian Grand Prix — Practice 3 live",
                      "the next session becomes live when it starts")
        }
    }

    private static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw SelfTestError.failed(message) }
    }

    private static let calendar = """
    {"MRData":{"RaceTable":{"Races":[{
      "season":"2026","round":"14","raceName":"Italian Grand Prix",
      "Circuit":{"circuitId":"monza","circuitName":"Monza","Location":{"locality":"Monza","country":"Italy"}},
      "date":"2026-09-06","time":"13:00:00Z",
      "SecondPractice":{"date":"2026-09-04","time":"14:00:00Z"},
      "ThirdPractice":{"date":"2026-09-05","time":"10:30:00Z"}
    }]}}}
    """
    private static let sessions = """
    [{"session_key":11355,"meeting_key":1293,"session_type":"Practice","session_name":"Practice 2",
      "date_start":"2026-09-04T14:00:00Z","date_end":"2026-09-04T15:00:00Z"},
     {"session_key":11356,"meeting_key":1293,"session_type":"Practice","session_name":"Practice 3",
      "date_start":"2026-09-05T10:30:00Z","date_end":"2026-09-05T11:30:00Z"}]
    """
}
