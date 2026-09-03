import Testing
@testable import F1Live

@Test func sessionStateBoundaries() {
    let start = fixtureDate(10_000)
    let session = RaceSession(key: "race", shortName: "RACE", name: "Race", group: "Race", startAt: start, endAt: start.addingTimeInterval(100), dateOnly: false, exactEnd: true, sessionKey: 42)

    #expect(session.state(at: start.addingTimeInterval(-3_601)) == .upcoming)
    #expect(session.state(at: start.addingTimeInterval(-60)) == .soon)
    #expect(session.state(at: start) == .live)
    #expect(session.state(at: start.addingTimeInterval(100)) == .done)
}

@Test func currentRaceStaysVisibleForOneDay() {
    let race = makeRace(start: fixtureDate(10_000))
    let finish = race.raceSession!.endAt
    #expect(F1API.currentRaceIndex(in: [race], at: finish.addingTimeInterval(.day - 1)) == 0)
    #expect(F1API.currentRaceIndex(in: [race], at: finish.addingTimeInterval(.day)) == -1)
}

@Test func openF1RefinementAddsExactEndAndSessionKey() {
    let race = makeRace(start: fixtureDate(10_000))
    let exactStart = race.raceStartAt.addingTimeInterval(120)
    let live = OpenF1Session(sessionKey: 99, meetingKey: 10, type: "Race", name: "Race", startAt: exactStart, endAt: exactStart.addingTimeInterval(7_200))
    let refined = F1API.refine(race, with: [live])

    #expect(refined.raceSession?.sessionKey == 99)
    #expect(refined.raceSession?.startAt == exactStart)
    #expect(refined.raceSession?.exactEnd == true)
    #expect(refined.meetingKey == 10)
}

@Test func liveStateRejectsOlderRows() {
    let newer = fixtureDate(20_000)
    let older = fixtureDate(10_000)
    var state = LiveTimingState()
    state.merge(LiveBatch(positions: [TimedPosition(driverNumber: 1, position: 2, at: newer)], intervals: [], drivers: nil, pits: nil, currentLap: nil, raceControl: nil), polledAt: newer)
    state.merge(LiveBatch(positions: [TimedPosition(driverNumber: 1, position: 8, at: older)], intervals: [], drivers: nil, pits: nil, currentLap: nil, raceControl: nil), polledAt: newer)

    #expect(state.rows.first?.position == 2)
}

@Test func gapFormatting() {
    #expect(LiveTimingState.gapText(nil, leader: true) == "LEADER")
    #expect(LiveTimingState.gapText("1.2", leader: false) == "+1.200")
    #expect(LiveTimingState.gapText("1 LAP", leader: false) == "1 LAP")
    #expect(LiveTimingState.gapText(nil, leader: false) == "—")
}

@Test func knownCircuitMap() {
    #expect(CircuitMaps.filename(for: makeRace(start: fixtureDate(10_000))) == "monza-7.svg")
}

@Test func compactCountdownIncludesHours() {
    let start = fixtureDate(10_000)
    #expect(F1Formatting.countdown(to: start.addingTimeInterval(.day + 3 * .hour), from: start, compact: true) == "1d 3h")
}

@Test @MainActor func loginItemSettingsFollowSystemState() throws {
    try LoginItemSelfTests.run()
}

@Test func liveDetailsKeepRefreshing() throws { try LiveTimingSelfTests.detailRefreshCadence() }
@Test func liveFeedDetectsEmptyAndRepeatedResponses() throws { try LiveTimingSelfTests.emptyAndRepeatedResponses() }
@Test func liveFeedHandlesTimestamps() throws { try LiveTimingSelfTests.timestampHandling() }
@Test @MainActor func notificationsRequireOptIn() async throws { try await NotificationSelfTests.firstUseAndOptIn() }
@Test @MainActor func notificationsReflectSystemPermissions() async throws { try await NotificationSelfTests.deniedAndExternalChanges() }
@Test @MainActor func notificationsPreserveExistingPreferences() async throws { try await NotificationSelfTests.existingPreferences() }
@Test @MainActor func notificationErrorsAndUnbundledExecution() async throws { try await NotificationSelfTests.errorsAndUnbundledExecution() }
@Test @MainActor func notificationCancellationAndReplacement() async throws { try await NotificationSelfTests.cancelledAndOverlappingSchedules() }
@Test @MainActor func reminderPlanAndSupportLink() throws { try NotificationSelfTests.reminderPlanAndBugReport() }
