import Foundation

@MainActor
enum LiveTimingRegressionSelfTests {
    static func run() async throws {
        try await joiningMidraceAndRecoveringAfterSleep()
        try await partialFailuresPreserveTiming()
        try await initialDetailFailureStillShowsTower()
        try await cancellationAndAccessRestrictionsRetireBatch()
        try await raceControlUsesRecognizedEvents()
        try await extendedRaceUsesCompletionSignals()
        try await delayedRaceReconnectsAutomatically()
    }

    static func joiningMidraceAndRecoveringAfterSleep() async throws {
        let stub = LiveTimingFeedStub()
        let api = makeAPI(stub)
        var state = LiveTimingState()
        let first = try await api.loadLive(sessionKey: 42, refreshSeconds: 12, currentLap: 0, now: sampleTime)
        state.merge(first, polledAt: sampleTime)
        try check(state.rows.map(\.number) == [1, 44], "a midrace join includes an unchanged leader and excludes future records")
        try check(state.rows[1].position == 2, "out-of-order history keeps the latest position")
        try check(state.lastPositionPollAt == sampleTime, "successful position queries record their query time")

        let nextTime = sampleTime.addingTimeInterval(12)
        let next = try await api.loadLive(sessionKey: 42, refreshSeconds: 12, currentLap: state.currentLap,
                                          details: state.detailsNeedingRefresh(at: nextTime), positionSince: state.lastPositionPollAt, now: nextTime)
        state.merge(next, polledAt: nextTime)
        try check(state.rows.count == 2 && state.rows.first?.number == 1, "incremental polling retains drivers absent from the response")
        let queries = await stub.requestedURLs.filter { $0.lastPathComponent == "position" }
        try check(query("date>", in: queries[0]) == nil, "the initial request covers the full session")
        try check(query("date>", in: queries[1]) == iso(sampleTime.addingTimeInterval(-29)), "later requests overlap the last successful query")

        // The feed changes early in an hour-long outage. A window relative to
        // the wake time would permanently miss these position changes.
        await stub.setBody("position", positions(after: sampleTime.addingTimeInterval(60)))
        await stub.fail("position", code: 500)
        let failedAt = sampleTime.addingTimeInterval(2_400)
        let failed = try await api.loadLive(sessionKey: 42, refreshSeconds: 12, currentLap: state.currentLap,
                                            details: [], positionSince: state.lastPositionPollAt, now: failedAt)
        state.merge(failed, polledAt: failedAt)
        try check(state.lastPositionPollAt == nextTime, "a failed position request cannot advance its recovery cursor")
        try check(state.rows.first?.number == 1 && failed.warning != nil, "a position failure retains last-known rows and reports a warning")

        await stub.recover("position")
        let resumedAt = sampleTime.addingTimeInterval(3_600)
        let resumed = try await api.loadLive(sessionKey: 42, refreshSeconds: 12, currentLap: state.currentLap,
                                             details: [], positionSince: state.lastPositionPollAt, now: resumedAt)
        state.merge(resumed, polledAt: resumedAt)
        try check(state.rows.first?.number == 44 && state.rows.count == 2, "recovery includes changes older than twenty minutes")
        try check(resumed.warning == nil && state.lastPositionPollAt == resumedAt, "successful recovery clears the warning and advances the cursor")
    }

    static func partialFailuresPreserveTiming() async throws {
        for endpoint in ["drivers", "pit", "laps", "race_control", "intervals"] {
            for malformed in [false, true] {
                let stub = LiveTimingFeedStub()
                let api = makeAPI(stub)
                var state = LiveTimingState()
                state.merge(try await api.loadLive(sessionKey: 42, refreshSeconds: 12, currentLap: 0, now: sampleTime), polledAt: sampleTime)
                if malformed { await stub.setBody(endpoint, "{invalid JSON}") }
                else { await stub.fail(endpoint, code: 500) }
                let nextTime = sampleTime.addingTimeInterval(60)
                await stub.setBody("position", positions(after: nextTime))
                let batch = try await api.loadLive(sessionKey: 42, refreshSeconds: 12, currentLap: state.currentLap,
                                                   details: state.detailsNeedingRefresh(at: nextTime), positionSince: state.lastPositionPollAt, now: nextTime)
                state.merge(batch, polledAt: nextTime)
                try check(state.rows.first?.number == 44 && batch.warning != nil, "\(endpoint) failures preserve fresh positions and show a warning")
                try check(state.drivers[44]?.acronym == "HAM" && state.pits[44]?.count == 1 && state.currentLap == 17,
                          "failed or malformed detail responses preserve previous details")
                try check(state.status.label == "RED FLAG", "unavailable control data preserves the previous track status")

                let failedDetail: LiveDetail? = ["drivers": .drivers, "pit": .pits, "laps": .laps][endpoint]
                let retryTime = nextTime.addingTimeInterval(12)
                let toRetry = state.detailsNeedingRefresh(at: retryTime)
                try check(toRetry == (failedDetail.map { Set([$0]) } ?? []), "only the failed slow endpoint is immediately retried")
                await stub.setBody(endpoint, LiveTimingFeedStub.bodies[endpoint]!)
                await stub.recover(endpoint)
                await stub.clearRequests()
                let recovered = try await api.loadLive(sessionKey: 42, refreshSeconds: 12, currentLap: state.currentLap,
                                                       details: toRetry, positionSince: state.lastPositionPollAt, now: retryTime)
                state.merge(recovered, polledAt: retryTime)
                try check(recovered.warning == nil && state.detailsNeedingRefresh(at: retryTime).isEmpty, "\(endpoint) recovery clears warnings and restores its cadence")
                let requested = await stub.requestedURLs.map(\.lastPathComponent)
                try check(!requested.contains("drivers") || failedDetail == .drivers, "successful driver metadata is not repeatedly requested")
                try check(!requested.contains("pit") || failedDetail == .pits, "successful pit data is not repeatedly requested")
                try check(!requested.contains("laps") || failedDetail == .laps, "successful lap data is not repeatedly requested")
            }
        }
    }

    static func initialDetailFailureStillShowsTower() async throws {
        let stub = LiveTimingFeedStub()
        await stub.fail("pit", code: 500)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "F1LivePartialTiming.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "autoLive")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cache)
        }
        let store = AppStore(settings: SettingsStore(defaults: defaults), api: makeAPI(stub, cache: cache))
        store.tick(at: sampleTime)
        await store.refresh()
        store.liveMode = true
        await store.pollLiveIfNeeded()
        try check(store.live.rows.count == 2 && store.liveWarning?.contains("pit stops") == true,
                  "an initial pit outage shows the tower with a partial-data warning")
        await stub.clearRequests()
        await stub.setBody("position", positions(after: sampleTime.addingTimeInterval(12)))
        store.tick(at: sampleTime.addingTimeInterval(12))
        await store.pollLiveIfNeeded()
        try check(store.live.rows.first?.number == 44 && store.liveWarning?.contains("pit stops") == true,
                  "fast timing keeps updating during the detail outage")
        let requested = await stub.requestedURLs.map(\.lastPathComponent)
        try check(requested.contains("pit") && !requested.contains("drivers") && !requested.contains("laps"),
                  "the app retries the failed detail without repeating successful metadata")
        await stub.recover("pit")
        store.tick(at: sampleTime.addingTimeInterval(24))
        await store.pollLiveIfNeeded()
        try check(store.liveWarning == nil && store.live.pits[44]?.count == 1,
                  "recovering the pit endpoint updates the displayed count and clears the warning")
    }

    static func cancellationAndAccessRestrictionsRetireBatch() async throws {
        for cancelled in [false, true] {
            let stub = LiveTimingFeedStub()
            if cancelled { await stub.cancel("pit") }
            else { await stub.fail("pit", code: 403) }
            do {
                _ = try await makeAPI(stub).loadLive(sessionKey: 42, refreshSeconds: 12, currentLap: 0, now: sampleTime)
                throw SelfTestError.failed("cancelled or unauthorized connections cannot return a partial batch")
            } catch is CancellationError {
                try check(cancelled, "only cancellation produces CancellationError")
            } catch let error as F1APIError {
                try check(!cancelled && error == .openF1AccessRestricted, "access errors retain their account guidance")
            }
        }
    }

    static func raceControlUsesRecognizedEvents() async throws {
        let stub = LiveTimingFeedStub()
        let api = makeAPI(stub)
        let red = "{\"category\":\"Flag\",\"flag\":\"RED\",\"scope\":\"Track\",\"date\":\"2026-09-06T13:40:00Z\"}"
        for category in ["Other", "CarEvent", "SafetyCar"] {
            await stub.setBody("race_control", "[\(red),{\"category\":\"\(category)\",\"message\":\"CAR 44 (HAM) - SAFETY CAR INFRINGEMENT - NOTED\",\"date\":\"2026-09-06T13:44:00Z\"}]")
            let batch = try await api.loadLive(sessionKey: 42, refreshSeconds: 12, currentLap: 0, details: [], now: sampleTime)
            try check(batch.raceControl?.label == "RED FLAG", "steward notices cannot replace a red flag")
        }

        let cases: [(String, String, String)] = [
            ("SafetyCar", "SAFETY CAR DEPLOYED", "SAFETY CAR"),
            ("SafetyCar", "SAFETY CAR IN THIS LAP", "SC ENDING"),
            ("SafetyCar", "SAFETY CAR IN PIT LANE", "RUNNING"),
            ("SafetyCar", "VIRTUAL SAFETY CAR DEPLOYED", "VIRTUAL SAFETY CAR"),
            ("SafetyCar", "VIRTUAL SAFETY CAR ENDING", "VSC ENDING"),
            ("SafetyCar", "VIRTUAL SAFETY CAR ENDED", "RUNNING"),
            ("SessionStatus", "SESSION RESUMED", "RUNNING"),
            ("SessionStatus", "SESSION FINISHED", "SESSION FINISHED")
        ]
        for (category, message, expected) in cases {
            // Deliberately return events out of order: timestamps, rather
            // than array order, determine which control event wins.
            await stub.setBody("race_control", "[{\"category\":\"\(category)\",\"message\":\"\(message)\",\"date\":\"2026-09-06T13:44:00Z\"},\(red)]")
            let batch = try await api.loadLive(sessionKey: 42, refreshSeconds: 12, currentLap: 0, details: [], now: sampleTime)
            try check(batch.raceControl?.label == expected && batch.raceControl?.at == sampleTime.addingTimeInterval(-60), "recognized \(message) event retains its timestamp")
        }
        var state = LiveTimingState()
        state.merge(LiveBatch(positions: [], intervals: [], drivers: nil, pits: nil, currentLap: nil,
                              raceControl: RaceControlStatus(label: "RED FLAG", kind: "stopped", at: sampleTime)), polledAt: sampleTime)
        await stub.setBody("race_control", "[{\"category\":\"Other\",\"message\":\"TRACK LIMITS - NOTED\"}]")
        let unrelated = try await api.loadLive(sessionKey: 42, refreshSeconds: 12, currentLap: 0, details: [], now: sampleTime)
        state.merge(unrelated, polledAt: sampleTime)
        try check(state.status.label == "RED FLAG", "unrelated messages do not invent a green track status")
        state.merge(LiveBatch(positions: [], intervals: [], drivers: nil, pits: nil, currentLap: nil,
                              raceControl: RaceControlStatus(label: "RUNNING", kind: "green", at: sampleTime.addingTimeInterval(-60))), polledAt: sampleTime)
        try check(state.status.label == "RED FLAG", "older control responses cannot roll back current track status")
    }

    static func extendedRaceUsesCompletionSignals() async throws {
        let stub = LiveTimingFeedStub()
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "F1LiveExtendedRace.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "autoLive")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cache)
        }
        let store = AppStore(settings: SettingsStore(defaults: defaults), api: makeAPI(stub, cache: cache))
        let overrun = sampleTime.addingTimeInterval(3 * .hour)
        store.tick(at: overrun)
        await store.refresh()
        store.liveMode = true
        try check(store.activeFeedSession?.sessionKey == 42, "a cold launch can connect more than thirty minutes after the timetable end")
        await store.pollLiveIfNeeded()
        try check(store.live.rows.count == 2 && store.live.status.kind == "stopped", "a long red flag still receives timing")
        try check(store.menuBarTitle == "F1 LIVE" && store.weekend.kind == .live, "an extended race remains live in the menu bar and overview")
        let raceFixture = store.race!
        await store.refresh()
        try check(store.race?.id == raceFixture.id && store.menuBarTitle == "F1 LIVE", "refreshing the calendar cannot retire a running delayed race")

        let resumedAt = overrun.addingTimeInterval(12)
        await stub.setBody("race_control", "[{\"category\":\"SessionStatus\",\"message\":\"SESSION RESUMED\",\"date\":\"\(iso(resumedAt))\"}]")
        store.tick(at: resumedAt)
        await store.pollLiveIfNeeded()
        try check(store.live.status.kind == "green", "race control refreshes on fast polls without waiting for metadata")

        let finishedAt = resumedAt.addingTimeInterval(12)
        await stub.setBody("race_control", "[{\"category\":\"SessionStatus\",\"message\":\"SESSION FINISHED\",\"date\":\"\(iso(finishedAt))\"}]")
        store.tick(at: finishedAt)
        await store.pollLiveIfNeeded()
        try check(store.live.status.kind == "finished" && store.menuBarTitle != "F1 LIVE", "an actual finish clears the live label")
        store.tick(at: finishedAt.addingTimeInterval(30 * .minute))
        try check(store.activeFeedSession?.sessionKey == 42, "the post-race buffer follows the actual finish")
        store.tick(at: finishedAt.addingTimeInterval(30 * .minute + 1))
        try check(store.activeFeedSession == nil, "polling ends after the actual finish buffer")
        try check(store.race == nil, "the dashboard leaves the last race after the actual finish buffer")
        store.tick(at: finishedAt.addingTimeInterval(30 * .minute + 2))
        await store.refresh()
        let requestsBefore = await stub.requestedURLs.count
        await store.pollLiveIfNeeded()
        let requestsAfter = await stub.requestedURLs.count
        try check(store.activeFeedSession == nil && requestsAfter == requestsBefore, "state resets and dashboard refreshes cannot restart a completed session")

        // A fresh process has no remembered finish. The first control request
        // must recover it from history even when it is over forty-five minutes old.
        let cold = AppStore(settings: SettingsStore(defaults: defaults), api: makeAPI(stub, cache: cache))
        cold.tick(at: finishedAt.addingTimeInterval(.hour))
        await cold.refresh()
        cold.liveMode = true
        await cold.pollLiveIfNeeded()
        try check(cold.activeFeedSession == nil && cold.menuBarTitle != "F1 LIVE", "a late cold launch discovers the historical finish and stops")

        store.tick(at: date("2026-09-06T19:00:01Z"))
        try check(store.race?.liveFeedSession(at: store.now) == nil, "a missing completion signal has a finite fallback")
        do {
            var race = raceFixture
            let start = race.sessions[0].startAt
            race.sessions.insert(RaceSession(key: "sprint", shortName: "SPRINT", name: "Sprint", group: "Sprint",
                                             startAt: start.addingTimeInterval(-3 * .hour), endAt: start.addingTimeInterval(-2 * .hour),
                                             dateOnly: false, exactEnd: true, sessionKey: 41), at: 0)
            try check(race.liveFeedSession(at: start.addingTimeInterval(1))?.sessionKey == 42, "a later session supersedes a sprint overrun")
            race.sessions.removeLast()
            try check(race.liveFeedSession(at: start.addingTimeInterval(4 * .hour)) == nil, "expired older sessions do not restart")
            race.sessions[0].dateOnly = true
            try check(race.liveFeedSession(at: sampleTime) == nil, "date-only sessions never start a feed")
        }
    }

    static func delayedRaceReconnectsAutomatically() async throws {
        let stub = LiveTimingFeedStub()
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "F1LiveDelayedAutoLive.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cache)
        }
        let api = makeAPI(stub, cache: cache)
        let store = AppStore(settings: SettingsStore(defaults: defaults), api: api)
        let overrun = sampleTime.addingTimeInterval(3 * .hour)
        store.tick(at: overrun)
        await store.refresh()
        try check(store.race == nil && store.activeFeedSession?.sessionKey == 42,
                  "a cold launch can discover a possible overrun after the estimated recap window")
        // Save only to the isolated memory store after loading the fixture;
        // no token or network request is needed to exercise automatic selection.
        try await api.openF1Auth.save(clientID: "test-client", clientSecret: "test-secret")
        await store.openF1Account.refreshStatus()
        store.tick(at: overrun)
        try check(store.liveMode, "automatic live timing reconnects before the first overrun poll")
    }

    private static func makeAPI(_ stub: LiveTimingFeedStub, cache: URL? = nil) -> F1API {
        F1API(client: CachedHTTPClient(transport: { try await stub.respond($0.url!) }, cacheDirectory: cache,
                                      auth: OpenF1Authentication(storage: MemoryOpenF1Credentials())))
    }

    private static func positions(after time: Date) -> String {
        "[{\"driver_number\":1,\"position\":2,\"date\":\"\(iso(time))\"},{\"driver_number\":44,\"position\":1,\"date\":\"\(iso(time))\"}]"
    }

    private static let sampleTime = date("2026-09-06T13:45:00Z")
    private static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private static func iso(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }
    private static func query(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        if !condition() { throw SelfTestError.failed(label) }
    }
}

private actor LiveTimingFeedStub {
    private var responses = bodies
    private var failures: [String: Int] = [:]
    private var cancellations: Set<String> = []
    private(set) var requestedURLs: [URL] = []

    func setBody(_ endpoint: String, _ body: String) { responses[endpoint] = body }
    func fail(_ endpoint: String, code: Int) { failures[endpoint] = code }
    func cancel(_ endpoint: String) { cancellations.insert(endpoint) }
    func recover(_ endpoint: String) { failures[endpoint] = nil }
    func clearRequests() { requestedURLs = [] }

    func respond(_ url: URL) throws -> (Data, URLResponse) {
        requestedURLs.append(url)
        let endpoint = url.lastPathComponent
        if cancellations.contains(endpoint) { throw CancellationError() }
        let code = failures[endpoint] ?? 200
        let body = url.host == "api.jolpi.ca" && endpoint == "races" ? Self.calendar : responses[endpoint] ?? "[]"
        var data = Data(body.utf8)
        if endpoint == "position", let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let lower = items.first { $0.name == "date>" }?.value.flatMap { ISO8601DateFormatter().date(from: $0) }
            let upper = items.first { $0.name == "date<" }?.value.flatMap { ISO8601DateFormatter().date(from: $0) }
            data = try JSONSerialization.data(withJSONObject: rows.filter {
                guard let text = $0["date"] as? String, let date = ISO8601DateFormatter().date(from: text) else { return true }
                return (lower == nil || date > lower!) && (upper == nil || date < upper!)
            })
        }
        return (data, HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }

    static let bodies = [
        "position": """
        [{"driver_number":1,"position":1,"date":"2026-09-06T13:00:00Z"},
         {"driver_number":44,"position":2,"date":"2026-09-06T13:44:00Z"},
         {"driver_number":44,"position":3,"date":"2026-09-06T13:43:00Z"},
         {"driver_number":77,"position":4,"date":"2026-09-06T18:45:00Z"}]
        """,
        "intervals": """
        [{"driver_number":1,"interval":null,"gap_to_leader":null,"date":"2026-09-06T13:45:00Z"},
         {"driver_number":44,"interval":1.2,"gap_to_leader":1.2,"date":"2026-09-06T13:45:00Z"}]
        """,
        "drivers": "[{\"driver_number\":1,\"name_acronym\":\"VER\"},{\"driver_number\":44,\"name_acronym\":\"HAM\"}]",
        "pit": "[{\"driver_number\":44,\"lap_number\":12,\"pit_duration\":22.5}]",
        "laps": "[{\"lap_number\":17}]",
        "race_control": "[{\"category\":\"Flag\",\"flag\":\"RED\",\"scope\":\"Track\",\"date\":\"2026-09-06T13:40:00Z\"}]",
        "sessions": """
        [{"session_key":42,"meeting_key":10,"session_type":"Race","session_name":"Race",
          "date_start":"2026-09-06T13:00:00Z","date_end":"2026-09-06T15:00:00Z"}]
        """
    ]
    private static let calendar = """
    {"MRData":{"RaceTable":{"Races":[{
      "season":"2026","round":"14","raceName":"Italian Grand Prix",
      "Circuit":{"circuitId":"monza","circuitName":"Monza","Location":{"locality":"Monza","country":"Italy"}},
      "date":"2026-09-06","time":"13:00:00Z"
    }]}}}
    """
}
