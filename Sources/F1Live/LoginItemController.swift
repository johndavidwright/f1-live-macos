import Foundation
import ServiceManagement

@MainActor
protocol LoginItemServicing {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
private struct SystemLoginItemService: LoginItemServicing {
    var status: SMAppService.Status { SMAppService.mainApp.status }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class LoginItemController: ObservableObject {
    private let service: any LoginItemServicing

    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var errorMessage: String?
    let isAvailable: Bool

    init(service: (any LoginItemServicing)? = nil, isAppBundle: Bool = Bundle.main.bundleURL.pathExtension == "app") {
        self.service = service ?? SystemLoginItemService()
        isAvailable = isAppBundle
        refreshStatus()
    }

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    var statusMessage: String {
        guard isAvailable else {
            return "Open the installed F1 Live app to change this setting."
        }
        switch status {
        case .requiresApproval:
            return "macOS needs your approval. Enable F1 Live in Login Items in System Settings."
        default:
            // A main app can report .notFound before its first registration.
            return "Automatically open F1 Live in your menu bar when you sign in."
        }
    }

    func refreshStatus() {
        // macOS owns this preference; do not keep a separate UserDefaults copy.
        let newStatus = isAvailable ? service.status : .notRegistered
        if status != newStatus { errorMessage = nil }
        status = newStatus
    }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable else { return }
        errorMessage = nil
        refreshStatus()
        guard enabled != isEnabled || (!enabled && requiresApproval) else { return }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            refreshStatus()
            // The approval instructions are more useful than a launch-denied error.
            if !(enabled && requiresApproval) {
                errorMessage = "Couldn’t turn Open at Login \(enabled ? "on" : "off"). \(error.localizedDescription)"
            }
            return
        }
        refreshStatus()
    }

    func openSystemSettings() {
        guard isAvailable else { return }
        service.openSystemSettings()
    }
}
