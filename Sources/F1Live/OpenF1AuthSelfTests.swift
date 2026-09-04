import Foundation

// Self-tests always use isolated storage and a simulated server. They never
// inspect the user's Keychain or send test credentials over the network.
final class MemoryOpenF1Credentials: OpenF1CredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: OpenF1Credentials?
    var failWrites = false
    var failReads = false
    var requiresApproval = false
    var approveInteraction = false
    private(set) var readInteractions: [Bool] = []
    private(set) var readCount = 0
    func read(allowingInteraction: Bool = false) throws -> OpenF1Credentials? {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        readInteractions.append(allowingInteraction)
        if failReads { throw OpenF1AuthError.keychain }
        if requiresApproval {
            guard allowingInteraction && approveInteraction else { throw OpenF1AuthError.keychainAuthorizationRequired }
            requiresApproval = false
        }
        return value
    }
    func save(_ credentials: OpenF1Credentials) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw OpenF1AuthError.keychain }
        value = credentials
    }
    func remove() throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw OpenF1AuthError.keychain }
        value = nil
    }
}

enum OpenF1AuthSelfTests {
    @MainActor
    static func run() async throws {
        try await optionalCredentialsAndHostIsolation()
        try await tokenRenewalAndRejectedAccess()
        try await saveTestRemoveAndFailures()
        try await concurrentRefreshAndRemoval()
        try await invalidTokenResponses()
        try await keychainRecovery()
        try await silentKeychainAndExplicitAuthorization()
        try await credentialsDuringDashboardRefresh()
    }

    static func optionalCredentialsAndHostIsolation() async throws {
        let server = AuthServer()
        let storage = MemoryOpenF1Credentials()
        let auth = OpenF1Authentication(storage: storage, transport: { try await server.send($0) })
        let client = CachedHTTPClient(transport: { try await server.send($0) }, auth: auth)
        _ = try await client.live(feedURL)
        var requests = await server.requests
        try check(requests.count == 1 && requests[0].value(forHTTPHeaderField: "Authorization") == nil,
                  "no credentials means no token requests or authorization headers")

        try await auth.save(clientID: "demo+id@example.test", clientSecret: "secret&=+ /é")
        _ = try await client.live(feedURL)
        requests = await server.requests
        let tokenRequest = requests.first { $0.url?.path == "/token" }!
        try check(tokenRequest.httpMethod == "POST" && tokenRequest.url?.query == nil,
                  "credentials travel in a POST body, never a URL")
        try check(String(data: tokenRequest.httpBody!, encoding: .utf8) == "username=demo%2Bid%40example.test&password=secret%26%3D%2B%20%2F%C3%A9",
                  "credential form encoding preserves special characters")
        try check(tokenRequest.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded",
                  "OpenF1 receives the expected form content type")
        try check(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer token-1", "feed receives the bearer token")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let sharedClient = CachedHTTPClient(transport: { try await server.send($0) }, cacheDirectory: cache, auth: auth)
        _ = try await sharedClient.get(URL(string: "https://api.jolpi.ca/ergast/f1/current/races/")!, cacheKey: "calendar", ttl: 0)
        requests = await server.requests
        try check(requests.last?.value(forHTTPHeaderField: "Authorization") == nil, "Jolpica never receives credentials")
        for text in ["http://api.openf1.org/v1/sessions", "https://api.openf1.org.evil.test/v1/sessions",
                     "https://api.openf1.org:8443/v1/sessions", "https://example.test/v1/sessions"] {
            let header = try await auth.authorization(for: URL(string: text)!)
            try check(header.token == nil, "only the exact HTTPS OpenF1 origin can receive a token")
        }
        // Exercise the actual session delegate's redirect decision, including
        // a 307 that would otherwise preserve the credential POST body.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: tokenRequest)
        let redirected = URLRequest(url: URL(string: "https://example.test/token")!)
        var allowed = true
        F1HTTP.NoRedirects().urlSession(session, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(url: tokenRequest.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!,
            newRequest: redirected) { allowed = $0 != nil }
        try check(!allowed, "redirects cannot forward credential bodies or bearer tokens")
    }

    static func tokenRenewalAndRejectedAccess() async throws {
        let server = AuthServer()
        let clock = AuthTestClock()
        let auth = OpenF1Authentication(storage: MemoryOpenF1Credentials(), transport: { try await server.send($0) }, clock: { clock.now })
        let client = CachedHTTPClient(transport: { try await server.send($0) }, clock: { clock.now }, auth: auth)
        await server.setFeedStatus(401)
        try await expect(F1APIError.openF1AccessRestricted) { _ = try await client.live(feedURL) }
        try await auth.save(clientID: "demo", clientSecret: "secret")
        await server.setFeedStatus(200)
        _ = try await client.live(feedURL)
        _ = try await client.live(feedURL)
        try await checkTokenCount(server, 1, "saving credentials clears anonymous cooldown and reuses a token")
        clock.advance(3_541)
        _ = try await client.live(feedURL)
        try await checkTokenCount(server, 2, "tokens renew before expiry")
        await server.rejectNextFeedRequest()
        _ = try await client.live(feedURL)
        try await checkTokenCount(server, 3, "a revoked token is refreshed once on HTTP 401")
        await server.setFeedStatus(401)
        try await expect(OpenF1AuthError.accessDenied) { _ = try await client.live(feedURL) }
        try await checkTokenCount(server, 4, "repeated unauthorized responses cannot loop forever")
        try await expect(OpenF1AuthError.accessDenied) { _ = try await client.live(feedURL) }
        try await checkTokenCount(server, 4, "refused account access backs off")
        await server.setFeedStatus(200)
        try await client.testOpenF1Connection()
        let status = try await auth.status()
        try check(status.connected, "an explicit connection test can recover immediately")
    }

    @MainActor
    static func saveTestRemoveAndFailures() async throws {
        let server = AuthServer()
        let storage = MemoryOpenF1Credentials()
        let auth = OpenF1Authentication(storage: storage, transport: { try await server.send($0) })
        let client = CachedHTTPClient(transport: { try await server.send($0) }, auth: auth)
        let controller = OpenF1AccountController(api: F1API(client: client))
        await controller.refreshStatus()
        try check(!controller.hasCredentials && !controller.isConnected, "new users stay disconnected")
        let saved = await controller.saveAndTest(clientID: "demo", clientSecret: "secret")
        try check(saved && controller.hasCredentials && controller.isConnected && !controller.isBusy, "save and test updates connection status")
        let stored = try storage.read()
        try check(stored?.clientID == "demo" && stored?.clientSecret == "secret", "credentials persist through the storage interface")
        // Reopen with the same storage: no secret is returned to the settings UI.
        let restarted = OpenF1Authentication(storage: storage, transport: { try await server.send($0) })
        let summary = try await restarted.status()
        try check(summary.clientID == "demo" && !summary.connected, "relaunch finds credentials without claiming they were tested")
        let retested = await controller.saveAndTest(clientID: "demo", clientSecret: "")
        try check(retested && controller.isConnected, "testing saved credentials does not require retyping the secret")

        await server.setTokenStatus(401)
        let rejected = await controller.saveAndTest(clientID: "demo", clientSecret: "wrong")
        try check(rejected && controller.hasCredentials && !controller.isConnected && controller.errorMessage == OpenF1AuthError.rejectedCredentials.localizedDescription,
                  "rejected credentials are clearly reported and remain removable")
        let countBefore = await server.tokenCount
        try await expect(OpenF1AuthError.rejectedCredentials) { _ = try await client.live(feedURL) }
        try await checkTokenCount(server, countBefore, "bad credentials do not add a token request to every poll")

        storage.failWrites = true
        let failedRemoval = await controller.removeCredentials()
        try check(!failedRemoval && controller.hasCredentials && controller.errorMessage == OpenF1AuthError.keychain.localizedDescription,
                  "Keychain failure cannot pretend credentials were removed")
        storage.failWrites = false
        let removed = await controller.removeCredentials()
        let remaining = try storage.read()
        try check(removed && !controller.hasCredentials && !controller.isConnected && remaining == nil,
                  "remove deletes persisted credentials and clears connection state")
        _ = try await client.live(feedURL)
        let requests = await server.requests
        try check(requests.last?.value(forHTTPHeaderField: "Authorization") == nil, "removal immediately stops sending bearer tokens")

        await server.setTokenStatus(503)
        _ = await controller.saveAndTest(clientID: "demo", clientSecret: "secret")
        try check(controller.hasCredentials && controller.errorMessage == OpenF1AuthError.unavailable.localizedDescription,
                  "an outage preserves saved credentials with a useful error")
    }

    static func concurrentRefreshAndRemoval() async throws {
        let server = AuthServer()
        await server.holdTokenResponses()
        let auth = OpenF1Authentication(storage: MemoryOpenF1Credentials(), transport: { try await server.send($0) })
        try await auth.save(clientID: "demo", clientSecret: "secret")
        let first = Task { try await auth.authorization(for: feedURL) }
        await server.waitForTokenRequest()
        let second = Task { try await auth.authorization(for: feedURL) }
        // Both callers share the pending exchange. Removing credentials while
        // it is suspended must prevent the response from resurrecting them.
        try await auth.remove()
        await server.releaseTokenResponses()
        do { _ = try await first.value; throw SelfTestError.failed("removed credentials returned a token") }
        catch is CancellationError {}
        _ = try? await second.value
        let after = try await auth.authorization(for: feedURL)
        try check(after.token == nil, "a late response cannot restore removed credentials")
        try await checkTokenCount(server, 1, "concurrent callers do not mint duplicate tokens")
    }

    static func invalidTokenResponses() async throws {
        for body in ["{}", "{\"access_token\":\"oops\\r\\nInjected: yes\",\"expires_in\":3600}",
                     "{\"access_token\":\"token\",\"expires_in\":0}",
                     "{\"access_token\":\"token\",\"expires_in\":\"NaN\"}"] {
            let auth = OpenF1Authentication(storage: MemoryOpenF1Credentials(), transport: { request in
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            try await auth.save(clientID: "demo", clientSecret: "secret")
            try await expect(OpenF1AuthError.invalidToken) { _ = try await auth.authorization(for: feedURL) }
        }
    }

    @MainActor
    static func keychainRecovery() async throws {
        let storage = MemoryOpenF1Credentials()
        storage.failReads = true
        let server = AuthServer()
        let auth = OpenF1Authentication(storage: storage, transport: { try await server.send($0) })
        let client = CachedHTTPClient(transport: { try await server.send($0) }, auth: auth)
        let controller = OpenF1AccountController(api: F1API(client: client))
        await controller.refreshStatus()
        await controller.refreshStatus()
        try check(!controller.isLoaded && storage.readCount == 1, "Keychain failures back off instead of repeatedly reading")
        storage.failReads = false
        _ = await controller.authorizeSavedCredentials()
        try check(controller.isLoaded && controller.errorMessage == nil && storage.readCount == 2, "explicit Keychain retry recovers immediately")
        storage.failWrites = true
        let saved = await controller.saveAndTest(clientID: "demo", clientSecret: "secret")
        try check(!saved && !controller.hasCredentials, "a failed Keychain write never reports saved credentials")
        try await checkTokenCount(server, 0, "failed persistence does not start a sign-in request")
    }

    @MainActor
    static func silentKeychainAndExplicitAuthorization() async throws {
        let storage = MemoryOpenF1Credentials()
        try storage.save(OpenF1Credentials(clientID: "saved-client", clientSecret: "saved-secret"))
        storage.requiresApproval = true
        let server = AuthServer()
        let clock = AuthTestClock()
        let auth = OpenF1Authentication(storage: storage, transport: { try await server.send($0) }, clock: { clock.now })
        let client = CachedHTTPClient(transport: { try await server.send($0) }, auth: auth)
        let controller = OpenF1AccountController(api: F1API(client: client))
        await controller.refreshStatus()
        try check(controller.requiresAuthorization && !controller.hasCredentials && !controller.isConnected,
                  "startup reports saved credentials awaiting approval without enabling live timing")
        try check(storage.readInteractions == [false], "startup reads never allow Keychain interaction")

        clock.advance(600)
        await controller.refreshStatus()
        try await expect(OpenF1AuthError.keychainAuthorizationRequired) { _ = try await client.live(feedURL) }
        try check(storage.readCount == 1, "polling waits for explicit approval even after the normal retry interval")
        try await checkTokenCount(server, 0, "unapproved credentials never start a token request")

        let dashboardServer = DashboardRefreshServer()
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = "F1LiveKeychainTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: cache)
        }
        let dashboardClient = CachedHTTPClient(transport: { try await dashboardServer.send($0) }, cacheDirectory: cache, auth: auth)
        let store = AppStore(settings: SettingsStore(defaults: defaults), api: F1API(client: dashboardClient))
        await store.openF1Account.refreshStatus()
        await store.refresh()
        try check(store.race?.name == "Italian Grand Prix" && !store.liveMode && store.errorMessage == nil,
                  "the free dashboard loads while Keychain authorization is pending")
        try check(store.data?.liveUnavailableReason == OpenF1AuthError.keychainAuthorizationRequired.localizedDescription,
                  "metadata failure explains how to resume timing")
        try check(storage.readCount == 1, "dashboard refresh cannot open another Keychain prompt")

        let denied = await controller.authorizeSavedCredentials()
        try check(!denied && controller.requiresAuthorization && !controller.isBusy,
                  "cancelled approval keeps timing paused and leaves an explicit retry available")
        await controller.refreshStatus()
        try check(storage.readInteractions == [false, true], "a cancelled approval never triggers an automatic interactive retry")
        storage.approveInteraction = true
        let authorized = await controller.authorizeSavedCredentials()
        try check(authorized && controller.isConnected && !controller.requiresAuthorization && controller.clientID == "saved-client",
                  "explicit approval reuses the saved credentials and verifies access")
        await controller.refreshStatus()
        _ = try await client.live(feedURL)
        try check(storage.readInteractions == [false, true, true], "approved credentials stay in memory during subsequent refreshes")
        try await checkTokenCount(server, 1, "explicit authorization tests the saved account once")
    }

    @MainActor
    static func credentialsDuringDashboardRefresh() async throws {
        let server = DashboardRefreshServer()
        let storage = MemoryOpenF1Credentials()
        let auth = OpenF1Authentication(storage: storage, transport: { try await server.send($0) })
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = "F1LiveAuthRefreshTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: cache)
        }
        let client = CachedHTTPClient(transport: { try await server.send($0) }, cacheDirectory: cache, auth: auth)
        let store = AppStore(settings: SettingsStore(defaults: defaults), api: F1API(client: client))
        let first = Task { await store.refresh() }
        await server.waitForFirstSessionRequest()
        try await auth.save(clientID: "demo", clientSecret: "secret")
        await store.openF1CredentialsChanged()
        await server.releaseFirstRequest()
        await first.value
        for _ in 0..<200 {
            if store.data?.race?.sessions.first(where: { $0.key == "fp2" })?.sessionKey == 99 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SelfTestError.failed("credentials saved during a refresh must trigger a fresh authenticated session lookup")
    }

    private static let feedURL = URL(string: "https://api.openf1.org/v1/position?session_key=11355")!
    private static func checkTokenCount(_ server: AuthServer, _ count: Int, _ label: String) async throws {
        let actual = await server.tokenCount
        try check(actual == count, label)
    }
    private static func expect<E: Error & Equatable>(_ expected: E, operation: () async throws -> Void) async throws {
        do { try await operation(); throw SelfTestError.failed("expected a classified error") }
        catch let error as E { try check(error == expected, "error has the expected category") }
    }
    private static func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
        if !value() { throw SelfTestError.failed(label) }
    }
}

private actor AuthServer {
    private(set) var requests: [URLRequest] = []
    private(set) var tokenCount = 0
    private var tokenStatus = 200
    private var feedStatus = 200
    private var rejectNext = false
    private var hold = false
    private var tokenWaiter: CheckedContinuation<Void, Never>?
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    func setTokenStatus(_ value: Int) { tokenStatus = value }
    func setFeedStatus(_ value: Int) { feedStatus = value }
    func rejectNextFeedRequest() { rejectNext = true }
    func holdTokenResponses() { hold = true }
    func waitForTokenRequest() async {
        if tokenCount == 0 { await withCheckedContinuation { arrivalWaiter = $0 } }
    }
    func releaseTokenResponses() { hold = false; tokenWaiter?.resume(); tokenWaiter = nil }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = request.url!
        let status: Int
        let body: String
        if url.path == "/token" {
            tokenCount += 1
            arrivalWaiter?.resume(); arrivalWaiter = nil
            if hold { await withCheckedContinuation { tokenWaiter = $0 } }
            status = tokenStatus
            body = "{\"access_token\":\"token-\(tokenCount)\",\"expires_in\":\"3600\",\"token_type\":\"bearer\"}"
        } else {
            status = rejectNext ? 401 : feedStatus
            rejectNext = false
            body = "[]"
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private final class AuthTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 10_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}

private actor DashboardRefreshServer {
    private var sessionRequests = 0
    private var responseWaiter: CheckedContinuation<Void, Never>?
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private let start = Date().addingTimeInterval(-60)
    func waitForFirstSessionRequest() async {
        if sessionRequests == 0 { await withCheckedContinuation { arrivalWaiter = $0 } }
    }
    func releaseFirstRequest() { responseWaiter?.resume(); responseWaiter = nil }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let stamp = ISO8601DateFormatter().string(from: start)
        let raceStamp = ISO8601DateFormatter().string(from: start.addingTimeInterval(.day))
        var status = 200
        let body: String
        if url.path == "/token" {
            body = "{\"access_token\":\"token\",\"expires_in\":3600}"
        } else if url.host == "api.openf1.org", url.path == "/v1/sessions" {
            sessionRequests += 1
            if sessionRequests == 1 {
                arrivalWaiter?.resume(); arrivalWaiter = nil
                await withCheckedContinuation { responseWaiter = $0 }
                status = 401
                body = "{}"
            } else {
                body = """
                [{"session_key":99,"meeting_key":1293,"session_type":"Practice","session_name":"Practice 2",
                  "date_start":"\(stamp)","date_end":"\(ISO8601DateFormatter().string(from: start.addingTimeInterval(.hour)))"}]
                """
            }
        } else if url.host == "api.jolpi.ca", url.path.contains("/races") {
            body = """
            {"MRData":{"RaceTable":{"Races":[{
              "season":"2026","round":"14","raceName":"Italian Grand Prix",
              "Circuit":{"circuitId":"monza","circuitName":"Monza","Location":{"locality":"Monza","country":"Italy"}},
              "date":"\(raceStamp.prefix(10))","time":"\(raceStamp.dropFirst(11))",
              "SecondPractice":{"date":"\(stamp.prefix(10))","time":"\(stamp.dropFirst(11))"}
            }]}}}
            """
        } else { body = "[]" }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
