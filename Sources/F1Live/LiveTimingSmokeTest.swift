import Foundation

enum LiveTimingSmokeTest {
    static func run() async throws {
        let api = F1API()
        report("Authorize saved OpenF1 credentials in the macOS prompt to start the live check.")
        // This explicitly requested diagnostic keeps the authorized credentials
        // in one process; an Allow-once approval need not persist across runs.
        try await api.openF1Auth.authorizeSavedCredentials()
        try await api.testOpenF1Connection()
        let dashboard = try await api.loadDashboard(refreshMinutes: 15, force: true)
        guard let race = dashboard.race, let session = race.liveFeedSession(at: Date()),
              session.usesRaceControlEnd, let key = session.sessionKey else {
            throw F1APIError.noData("No current race or sprint timing feed is available to test.")
        }
        report("Testing \(race.name), \(session.name), OpenF1 session \(key), across six polls at 12-second intervals.")
        var state = LiveTimingState()
        var firstUpdate: Date?
        var sawAdvance = false
        for sample in 0..<6 {
            if sample > 0 { try await Task.sleep(for: .seconds(12)) }
            let queriedAt = Date()
            let batch = try await api.loadLive(sessionKey: key, refreshSeconds: 12, currentLap: state.currentLap,
                                               details: state.detailsNeedingRefresh(at: queriedAt),
                                               positionSince: state.lastPositionPollAt, now: queriedAt)
            state.merge(batch, polledAt: queriedAt)
            if let warning = batch.warning { throw F1APIError.noData(warning) }
            guard !state.rows.isEmpty, !state.drivers.isEmpty, !state.intervals.isEmpty else {
                throw F1APIError.noData("The current timing feed did not provide drivers, positions, and race intervals.")
            }
            if let warning = state.freshnessWarning(at: Date(), refreshSeconds: 12) { throw F1APIError.noData(warning) }
            guard state.status.kind != "finished" else {
                throw F1APIError.noData("Race control reports that this session has finished; an ongoing-race check cannot complete.")
            }
            let missing = Set(state.drivers.keys).subtracting(state.positions.keys).sorted()
            guard missing.isEmpty else {
                throw F1APIError.noData("Timing positions are missing for driver numbers: \(missing.map(String.init).joined(separator: ", ")).")
            }
            guard let newest = state.lastUpdateAt else { throw F1APIError.noData("Timing timestamps are unavailable.") }
            if let firstUpdate { sawAdvance = sawAdvance || newest > firstUpdate }
            else { firstUpdate = newest }
            let age = max(0, Int(Date().timeIntervalSince(newest)))
            report("Poll \(sample + 1)/6: \(state.rows.count)/\(state.drivers.count) drivers; \(batch.positions.count) position records; \(batch.intervals.count) intervals; lap \(state.currentLap); \(state.status.label); newest timing \(age)s old; \(state.pits.values.reduce(0) { $0 + $1.count }) pit stops.")
        }
        guard sawAdvance else { throw F1APIError.noData("The feed responded, but timing timestamps never advanced during the live check.") }
        report("Live timing check passed: complete driver coverage, fresh advancing data, race control, and detail refreshes.")
    }

    private static func report(_ line: String) {
        FileHandle.standardOutput.write(Data("\(line)\n".utf8))
    }
}
