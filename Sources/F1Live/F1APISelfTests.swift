import Foundation

enum F1APISelfTests {
    static func run() async throws {
        try await accessRestrictionsAndRecovery()
        try await cachedSessionsSurviveAccessRestrictions()
        try await unavailableSessionsStillShowTheScheduledSession()
        try await otherHTTPResponses()
    }

    static func accessRestrictionsAndRecovery() async throws {
        for code in [401, 403] {
            let stub = StubHTTP(status: code)
            let clock = TestClock()
            let cache = temporaryCache()
            defer { try? FileManager.default.removeItem(at: cache) }
            let client = CachedHTTPClient(transport: { try await stub.get($0.url!) }, cacheDirectory: cache, clock: { clock.now }, auth: OpenF1Authentication(storage: MemoryOpenF1Credentials()))
            try await expectError(.openF1AccessRestricted) { _ = try await client.live(positionURL) }
            try await expectError(.openF1AccessRestricted) { _ = try await client.live(positionURL) }
            // The restriction is global, so a forced calendar refresh must
            // respect it too, without stopping unrelated Jolpica requests.
            try await expectError(.openF1AccessRestricted) {
                _ = try await client.get(sessionsURL, cacheKey: "sessions", ttl: 0, force: true)
            }
            let deniedRequests = await stub.requestCount
            try check(deniedRequests == 1, "access refusals pause all OpenF1 requests")
            let jolpica = URL(string: "https://api.jolpi.ca/ergast/f1/current/races/")!
            _ = try await client.get(jolpica, cacheKey: "races", ttl: 0, force: true)
            let requestsWithCalendar = await stub.requestCount
            try check(requestsWithCalendar == 2, "OpenF1 refusal does not block Jolpica")

            clock.advance(by: 300)
            await stub.respond(status: 200)
            let resumed = try await client.live(positionURL)
            try check(resumed == Data("[]".utf8), "live timing resumes after access is restored")
            let recoveredRequests = await stub.requestCount
            try check(recoveredRequests == 3, "request resumes when cooldown expires")
        }
    }

    static func cachedSessionsSurviveAccessRestrictions() async throws {
        let stub = StubHTTP(status: 200)
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let client = CachedHTTPClient(transport: { try await stub.get($0.url!) }, cacheDirectory: cache, auth: OpenF1Authentication(storage: MemoryOpenF1Credentials()))
        let fresh = try await client.get(sessionsURL, cacheKey: "sessions", ttl: 0, force: true)
        await stub.respond(status: 401)
        let stale = try await client.get(sessionsURL, cacheKey: "sessions", ttl: 0, force: true)
        try check(!fresh.stale && stale.stale && fresh.data == stale.data, "access refusal preserves cached sessions")
        let again = try await client.get(sessionsURL, cacheKey: "sessions", ttl: 0, force: true)
        let requests = await stub.requestCount
        try check(again.stale && requests == 2, "cached sessions remain available during cooldown")
        try await expectError(.openF1AccessRestricted) { _ = try await client.live(positionURL) }
    }

    static func unavailableSessionsStillShowTheScheduledSession() async throws {
        let calendar = """
        {"MRData":{"RaceTable":{"Races":[{
          "season":"2026","round":"14","raceName":"Italian Grand Prix",
          "Circuit":{"circuitId":"monza","circuitName":"Monza","Location":{"locality":"Monza","country":"Italy"}},
          "date":"2026-09-06","time":"13:00:00Z",
          "SecondPractice":{"date":"2026-09-04","time":"14:00:00Z"}
        }]}}}
        """
        let stub = StubHTTP(status: 401, calendar: calendar)
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let client = CachedHTTPClient(transport: { try await stub.get($0.url!) }, cacheDirectory: cache, auth: OpenF1Authentication(storage: MemoryOpenF1Credentials()))
        let api = F1API(client: client)
        // Check the first minute of the fixture's FP2, with no OpenF1 cache.
        let now = ISO8601DateFormatter().date(from: "2026-09-04T14:01:00Z")!
        let dashboard = try await api.loadDashboard(refreshMinutes: 15, now: now)
        try check(dashboard.liveUnavailableReason == F1APIError.openF1AccessRestricted.localizedDescription,
                  "missing session metadata preserves the access error")
        let active = dashboard.race?.liveFeedSession(at: now)
        try check(active?.key == "fp2" && active?.sessionKey == nil, "FP2 is recognized without an OpenF1 key")
        var dateOnlyRace = dashboard.race!
        dateOnlyRace.sessions = dateOnlyRace.sessions.map { session in
            var session = session
            session.dateOnly = true
            return session
        }
        try check(dateOnlyRace.liveFeedSession(at: now) == nil, "date-only sessions are not labelled live")
    }

    static func otherHTTPResponses() async throws {
        for code in [404, 429, 500] {
            let stub = StubHTTP(status: code)
            let client = CachedHTTPClient(transport: { try await stub.get($0.url!) }, auth: OpenF1Authentication(storage: MemoryOpenF1Credentials()))
            if code == 404 {
                let empty = try await client.live(positionURL)
                try check(empty == Data("[]".utf8), "missing feed still means an empty response")
            } else {
                try await expectError(.httpStatus(service: "OpenF1", code: code)) { _ = try await client.live(positionURL) }
                let requests = await stub.requestCount
                try check(requests == (code == 429 ? 2 : 1), "only rate limits get an immediate retry")
            }
        }
    }

    private static let positionURL = URL(string: "https://api.openf1.org/v1/position?session_key=11355")!
    private static let sessionsURL = URL(string: "https://api.openf1.org/v1/sessions?year=2026")!

    private static func temporaryCache() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("F1LiveHTTPTests-\(UUID().uuidString)")
    }

    private static func expectError(_ expected: F1APIError, operation: () async throws -> Void) async throws {
        do {
            try await operation()
            throw SelfTestError.failed("expected \(expected)")
        } catch let error as F1APIError {
            try check(error == expected, "HTTP error classification: \(error)")
        }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        if !condition() { throw SelfTestError.failed(label) }
    }
}

private actor StubHTTP {
    private var status: Int
    private let calendar: String
    private(set) var requestCount = 0

    init(status: Int, calendar: String = "[]") {
        self.status = status
        self.calendar = calendar
    }

    func respond(status: Int) { self.status = status }

    func get(_ url: URL) throws -> (Data, URLResponse) {
        requestCount += 1
        let code = url.host == "api.openf1.org" ? status : 200
        let body = url.host == "api.jolpi.ca" && (url.path.hasSuffix("/races") || url.path.hasSuffix("/races/")) ? calendar
            : (code == 200 ? "[]" : "{\"detail\":\"Live F1 session in progress. Global API access is restricted to authenticated users.\"}")
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 10_000)
    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }
    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        instant.addTimeInterval(seconds)
    }
}
