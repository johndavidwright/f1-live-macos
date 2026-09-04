import Combine
import Foundation

@MainActor
final class OpenF1AccountController: ObservableObject {
    @Published private(set) var clientID = ""
    @Published private(set) var hasCredentials = false
    @Published private(set) var isBusy = false
    @Published private(set) var isLoaded = false
    @Published private(set) var isConnected = false
    @Published private(set) var requiresAuthorization = false
    @Published private(set) var errorMessage: String?
    private let api: F1API

    init(api: F1API) { self.api = api }

    var statusMessage: String {
        if requiresAuthorization { return "Your credentials are still saved. Authorize access to resume live timing." }
        if let errorMessage { return errorMessage }
        if isBusy { return "Checking OpenF1…" }
        if !isLoaded { return "Checking saved credentials…" }
        if isConnected { return "Connected to OpenF1. Credentials are stored in macOS Keychain." }
        if hasCredentials { return "Credentials saved in macOS Keychain. Test the connection to check access." }
        return "Not connected. All features except live timing work without an OpenF1 account."
    }

    func refreshStatus() async {
        guard !isBusy else { return }
        await readStatus()
    }

    func authorizeSavedCredentials() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        var authorized = false
        do {
            try await api.openF1Auth.authorizeSavedCredentials()
            await readStatus()
            authorized = hasCredentials
            if authorized {
                try await api.testOpenF1Connection()
                await readStatus()
            }
        } catch {
            await readStatus()
            errorMessage = Self.message(for: error)
            isConnected = false
        }
        return authorized
    }

    // Save first so a temporary network outage doesn't lose what the user
    // entered. The result says whether callers should refresh the feed.
    func saveAndTest(clientID: String, clientSecret: String) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        var saved = false
        do {
            try await api.openF1Auth.save(clientID: clientID, clientSecret: clientSecret)
            saved = true
            try await api.testOpenF1Connection()
            await readStatus()
        } catch {
            await readStatus()
            errorMessage = Self.message(for: error)
            isConnected = false
        }
        return saved
    }

    func removeCredentials() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            try await api.openF1Auth.remove()
            await readStatus()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    private func readStatus() async {
        do {
            let status = try await api.openF1Auth.status()
            clientID = status.clientID ?? ""
            hasCredentials = status.clientID != nil
            isConnected = status.connected
            errorMessage = status.error
            isLoaded = true
            requiresAuthorization = false
        } catch {
            errorMessage = Self.message(for: error)
            isConnected = false
            isLoaded = false
            hasCredentials = false
            clientID = ""
            requiresAuthorization = (error as? OpenF1AuthError) == .keychainAuthorizationRequired
        }
    }

    private static func message(for error: Error) -> String {
        // Never display response bodies, request descriptions, or credentials.
        if let error = error as? OpenF1AuthError { return error.localizedDescription }
        if let error = error as? F1APIError { return error.localizedDescription }
        if error is CancellationError { return "The connection check was cancelled. Please try again." }
        return OpenF1AuthError.connection.localizedDescription
    }
}
