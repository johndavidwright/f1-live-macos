import AppKit
import Foundation
import Sparkle

@MainActor
final class UpdateController: ObservableObject {
    private let controller: SPUStandardUpdaterController
    private var observations: [NSKeyValueObservation] = []

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var allowsAutomaticUpdates = false

    let isAvailable: Bool

    init(startingUpdater: Bool? = nil) {
        let runsFromAppBundle = Bundle.main.bundleURL.pathExtension == "app"
        isAvailable = startingUpdater ?? runsFromAppBundle
        controller = SPUStandardUpdaterController(
            startingUpdater: isAvailable,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        observeUpdaterState()
        refreshState()
    }

    var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
    }

    func checkForUpdates() {
        guard isAvailable, controller.updater.canCheckForUpdates else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isAvailable else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
        refreshState()
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard isAvailable else { return }
        controller.updater.automaticallyDownloadsUpdates = enabled
        refreshState()
    }

    private func observeUpdaterState() {
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refreshState() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refreshState() }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refreshState() }
            },
            updater.observe(\.allowsAutomaticUpdates, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refreshState() }
            }
        ]
    }

    private func refreshState() {
        canCheckForUpdates = isAvailable && controller.updater.canCheckForUpdates
        automaticallyChecksForUpdates = isAvailable && controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = isAvailable && controller.updater.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = isAvailable && controller.updater.allowsAutomaticUpdates
    }
}
