import Foundation
import KeychainSupport
import LocalAuthentication
import Security

typealias F1HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

enum F1HTTP {
    static func transport() -> F1HTTPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "F1Live-macOS/1.0"]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        return { try await session.data(for: $0) }
    }

    // In particular, a redirect from /token must never forward its POST body
    // (or a timing request's Authorization header) to another destination.
    final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func isOpenF1(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "api.openf1.org" && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }
}

struct OpenF1Credentials: Codable, Sendable {
    let clientID: String
    let clientSecret: String
}

protocol OpenF1CredentialStorage: Sendable {
    func read(allowingInteraction: Bool) throws -> OpenF1Credentials?
    func save(_ credentials: OpenF1Credentials) throws
    func remove() throws
}

struct OpenF1Keychain: OpenF1CredentialStorage {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.nocram.f1live.macos.openf1",
         kSecAttrAccount as String: "personal-credentials",
         kSecAttrSynchronizable as String: false]
    }

    func read(allowingInteraction: Bool) throws -> OpenF1Credentials? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = !allowingInteraction
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = F1CopyKeychainItem(query as CFDictionary, allowingInteraction, &result)
        if status == errSecItemNotFound { return nil }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            throw OpenF1AuthError.keychainAuthorizationRequired
        }
        guard status == errSecSuccess, let data = result as? Data,
              let credentials = try? JSONDecoder().decode(OpenF1Credentials.self, from: data) else {
            throw OpenF1AuthError.keychain
        }
        return credentials
    }

    func save(_ credentials: OpenF1Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query.merging(attributes) { _, new in new }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw OpenF1AuthError.keychain }
        } else if status != errSecSuccess { throw OpenF1AuthError.keychain }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OpenF1AuthError.keychain }
    }
}

enum OpenF1AuthError: LocalizedError, Equatable {
    case missingCredentials, rejectedCredentials, accessDenied, invalidToken, keychainAuthorizationRequired, keychain, unavailable, connection

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Enter your OpenF1 Client ID and Client Secret."
        case .rejectedCredentials: return "OpenF1 rejected these credentials. Check your Client ID and Client Secret in Settings."
        case .accessDenied: return "OpenF1 refused this account’s access. Check that your OpenF1 subscription includes live timing."
        case .invalidToken: return "OpenF1 returned an invalid sign-in response. Please try again later."
        case .keychainAuthorizationRequired: return "Live timing is paused. Choose Authorize Saved Credentials in Settings to allow access to macOS Keychain."
        case .keychain: return "Couldn’t access OpenF1 credentials in macOS Keychain. Unlock your keychain and try again."
        case .unavailable: return "OpenF1 sign-in is unavailable right now. Your credentials are still saved; please try again later."
        case .connection: return "Couldn’t reach OpenF1. Check your connection and try again."
        }
    }
}

struct OpenF1AccountStatus: Sendable {
    let clientID: String?
    let connected: Bool
    let error: String?
}

actor OpenF1Authentication {
    private let storage: any OpenF1CredentialStorage
    private let transport: F1HTTPTransport
    private let clock: @Sendable () -> Date
    private var loaded = false
    private var credentials: OpenF1Credentials?
    private var token: Token?
    private var pending: (id: UUID, task: Task<Token, Error>)?
    private var failure: (error: OpenF1AuthError, retryAt: Date)?
    private var verified = false
    private(set) var revision = 0

    init(storage: any OpenF1CredentialStorage = OpenF1Keychain(), transport: F1HTTPTransport? = nil,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.storage = storage
        self.transport = transport ?? F1HTTP.transport()
        self.clock = clock
    }

    func status() throws -> OpenF1AccountStatus {
        try loadCredentials()
        return OpenF1AccountStatus(clientID: credentials?.clientID, connected: verified && failure == nil,
                                  error: failure?.error.localizedDescription)
    }

    func save(clientID: String, clientSecret: String) throws {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        var secret = clientSecret
        if secret.isEmpty {
            try loadCredentials()
            if id == credentials?.clientID { secret = credentials?.clientSecret ?? "" }
        }
        guard !id.isEmpty, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenF1AuthError.missingCredentials
        }
        let replacement = OpenF1Credentials(clientID: id, clientSecret: secret)
        try storage.save(replacement)
        reset()
        credentials = replacement
        loaded = true
    }

    func remove() throws {
        try storage.remove()
        reset()
        credentials = nil
        loaded = true
    }

    func prepareConnectionTest() {
        reset()
    }

    // Only the explicit Settings action may ask macOS to display approval UI.
    func authorizeSavedCredentials() throws {
        try loadCredentials(allowingInteraction: true)
    }

    func markVerified(revision expected: Int) throws {
        guard revision == expected, credentials != nil else { throw CancellationError() }
        verified = true
        failure = nil
    }

    func markAccessDenied(revision expected: Int) {
        guard revision == expected else { return }
        verified = false
        failure = (.accessDenied, clock().addingTimeInterval(5 * .minute))
    }

    func authorization(for url: URL) async throws -> (token: String?, revision: Int) {
        guard F1HTTP.isOpenF1(url), url.path.hasPrefix("/v1/") else { return (nil, revision) }
        try loadCredentials()
        let expected = revision
        guard let credentials else { return (nil, expected) }
        if let failure, clock() < failure.retryAt { throw failure.error }
        if let token, clock() < token.refreshAt { return (token.value, expected) }
        let current: (id: UUID, task: Task<Token, Error>)
        if let pending { current = pending }
        else {
            let transport = transport
            let clock = clock
            current = (UUID(), Task { try await Self.fetchToken(credentials, transport: transport, now: clock()) })
            pending = current
        }
        do {
            let fresh = try await current.task.value
            try Task.checkCancellation()
            guard revision == expected else { throw CancellationError() }
            token = fresh
            failure = nil
            if pending?.id == current.id { pending = nil }
            return (fresh.value, expected)
        } catch {
            guard revision == expected else { throw CancellationError() }
            if pending?.id == current.id { pending = nil }
            if let error = error as? OpenF1AuthError {
                failure = (error, clock().addingTimeInterval(5 * .minute))
                verified = false
            }
            throw error
        }
    }

    func invalidateToken(_ rejected: String, revision expected: Int) {
        guard revision == expected, token?.value == rejected else { return }
        token = nil
        verified = false
    }

    private func loadCredentials(allowingInteraction: Bool = false) throws {
        guard !loaded else { return }
        if !allowingInteraction, let failure {
            if failure.error == .keychainAuthorizationRequired { throw failure.error }
            if failure.error == .keychain, clock() < failure.retryAt { throw failure.error }
        }
        do {
            credentials = try storage.read(allowingInteraction: allowingInteraction)
            loaded = true
            failure = nil
        } catch {
            let reason = error as? OpenF1AuthError ?? .keychain
            failure = (reason, clock().addingTimeInterval(5 * .minute))
            throw reason
        }
    }

    private func reset() {
        revision += 1
        pending?.task.cancel()
        pending = nil
        token = nil
        failure = nil
        verified = false
    }

    private struct Token: Sendable {
        let value: String
        let refreshAt: Date
    }

    private static func fetchToken(_ credentials: OpenF1Credentials, transport: F1HTTPTransport, now: Date) async throws -> Token {
        var request = URLRequest(url: URL(string: "https://api.openf1.org/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // OpenF1 calls these client credentials, but /token expects the form
        // fields username/password (see OpenF1's own Python client).
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed)! }
        request.httpBody = Data("username=\(encode(credentials.clientID))&password=\(encode(credentials.clientSecret))".utf8)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw OpenF1AuthError.connection }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw OpenF1AuthError.invalidToken }
        if [400, 401, 403, 422].contains(http.statusCode) { throw OpenF1AuthError.rejectedCredentials }
        guard (200..<300).contains(http.statusCode) else { throw OpenF1AuthError.unavailable }
        guard data.count <= 16_384, let result = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !result.accessToken.isEmpty,
              result.accessToken.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/=").contains($0) }),
              result.expiresIn.isFinite, result.expiresIn > 0,
              result.tokenType?.lowercased() == "bearer" || result.tokenType == nil else { throw OpenF1AuthError.invalidToken }
        return Token(value: result.accessToken, refreshAt: now.addingTimeInterval(result.expiresIn - min(60, result.expiresIn / 10)))
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Double
        let tokenType: String?
        enum CodingKeys: String, CodingKey { case accessToken = "access_token", expiresIn = "expires_in", tokenType = "token_type" }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try values.decode(String.self, forKey: .accessToken)
            tokenType = try values.decodeIfPresent(String.self, forKey: .tokenType)
            if let number = try? values.decode(Double.self, forKey: .expiresIn) { expiresIn = number }
            else {
                let text = try values.decode(String.self, forKey: .expiresIn)
                guard let number = Double(text) else { throw OpenF1AuthError.invalidToken }
                expiresIn = number
            }
        }
    }
}
