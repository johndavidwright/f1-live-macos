import Foundation

enum LiveTimingSelfTests {
    static func run() throws {
        try detailRefreshCadence()
        try emptyAndRepeatedResponses()
        try timestampHandling()
    }

    static func detailRefreshCadence() throws {
        let start = Date(timeIntervalSince1970: 10_000)
        var state = LiveTimingState()
        var detailPolls: [Int] = []
        for second in stride(from: 0, through: 144, by: 12) {
            let time = start.addingTimeInterval(TimeInterval(second))
            let includeDetails = state.needsDetailRefresh(at: time)
            if includeDetails { detailPolls.append(second) }
            state.merge(batch(at: time, details: includeDetails, lap: second / 12 + 1), polledAt: time, includedDetails: includeDetails)
        }
        try check(detailPolls == [0, 60, 120], "fast polls do not postpone detail refreshes")
        try check(state.currentLap == 11 && state.pits[44]?.count == 11, "lap counts and pits continue updating")
        try check(state.status.label == "CONTROL 11", "race-control messages continue updating")
        try check(state.lastDetailPollAt == start.addingTimeInterval(120), "detail timestamp is independent of last poll")
        try check(state.lastPollAt == start.addingTimeInterval(144), "fast polling keeps its own timestamp")
        try check(state.needsDetailRefresh(at: start.addingTimeInterval(600)), "details refresh after sleep or an outage")
    }

    static func emptyAndRepeatedResponses() throws {
        let start = Date(timeIntervalSince1970: 10_000)
        var state = LiveTimingState()
        state.merge(batch(at: start), polledAt: start)
        let empty = LiveBatch(positions: [], intervals: [], drivers: nil, pits: nil, currentLap: nil, raceControl: nil)
        for second in [12, 24, 36] { state.merge(empty, polledAt: start.addingTimeInterval(TimeInterval(second))) }
        try check(state.rows.count == 1 && state.consecutiveEmptyPolls == 3, "empty responses are detected without discarding last-known rows")
        try check(state.lastUpdateAt == start, "empty responses do not refresh the data timestamp")
        try check(state.freshnessWarning(at: start.addingTimeInterval(36), refreshSeconds: 12) != nil, "three empty replies produce a warning")

        state.merge(batch(at: start), polledAt: start.addingTimeInterval(72))
        try check(state.freshnessWarning(at: start.addingTimeInterval(72), refreshSeconds: 12) != nil, "repeated historical rows do not hide a stale feed")
        try check(state.freshnessWarning(at: start.addingTimeInterval(72), refreshSeconds: 120) == nil, "freshness threshold accounts for slower user polling")
        let resumed = start.addingTimeInterval(84)
        state.merge(batch(at: resumed), polledAt: resumed)
        try check(state.freshnessWarning(at: resumed, refreshSeconds: 12) == nil, "fresh data clears stale warnings")
        try check(state.freshnessWarning(at: resumed.addingTimeInterval(61), refreshSeconds: 12) != nil, "clock alone detects a silent feed")
    }

    static func timestampHandling() throws {
        let start = Date(timeIntervalSince1970: 10_000)
        var state = LiveTimingState()
        state.merge(batch(at: start), polledAt: start)
        let newer = start.addingTimeInterval(20)
        state.merge(LiveBatch(positions: [TimedPosition(driverNumber: 44, position: 1, at: newer)], intervals: [], drivers: nil, pits: nil, currentLap: nil, raceControl: nil), polledAt: newer)
        try check(state.rows.first?.updatedAt == newer && state.lastUpdateAt == newer, "old intervals do not mask newer positions")
        state.merge(batch(at: start), polledAt: newer.addingTimeInterval(1))
        try check(state.rows.first?.position == 1 && state.lastUpdateAt == newer, "older rows cannot roll back state")
        state.merge(batch(at: nil), polledAt: newer.addingTimeInterval(2))
        try check(state.rows.first?.position == 1 && state.lastUpdateAt == newer, "undated rows do not overwrite dated state")
        var undated = LiveTimingState()
        undated.merge(batch(at: nil), polledAt: start)
        try check(undated.lastUpdateAt == nil && undated.freshnessWarning(at: start, refreshSeconds: 12) != nil, "missing timestamps do not imply fresh timing")
    }

    private static func batch(at time: Date?, details: Bool = false, lap: Int = 1) -> LiveBatch {
        LiveBatch(
            positions: [TimedPosition(driverNumber: 44, position: 2, at: time)],
            intervals: [TimedInterval(driverNumber: 44, interval: "1.2", gapToLeader: "1.2", at: time)],
            drivers: details ? [44: LiveDriver(number: 44, acronym: "HAM", fullName: "Lewis Hamilton", teamName: "Ferrari", teamColour: "e8002d")] : nil,
            pits: details ? [44: PitSummary(count: lap)] : nil,
            currentLap: details ? lap : nil,
            raceControl: details ? RaceControlStatus(label: "CONTROL \(lap)", kind: "caution", at: time) : nil
        )
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        if !condition() { throw SelfTestError.failed(label) }
    }
}
