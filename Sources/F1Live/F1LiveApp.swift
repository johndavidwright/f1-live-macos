import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

struct F1LiveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: SettingsStore
    @StateObject private var store: AppStore

    init() {
        let settings = SettingsStore()
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: AppStore(settings: settings))
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView()
                .environmentObject(store)
                .environmentObject(settings)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.activeFeedSession != nil ? "flag.checkered.2.crossed" : "stopwatch")
                Text(store.menuBarTitle).monospacedDigit()
            }
                .onAppear { store.start() }
                .help(store.tooltip)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(store: AppStore, settings: SettingsStore) {
        let sourceWindow = NSApp.keyWindow
        let sourceScreen = sourceWindow?.screen ?? NSScreen.main

        if let sourceWindow, sourceWindow !== window {
            sourceWindow.orderOut(nil)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.present(store: store, settings: settings, on: sourceScreen)
        }
    }

    private func present(store: AppStore, settings: SettingsStore, on screen: NSScreen?) {
        let settingsWindow: NSWindow
        if let window {
            settingsWindow = window
        } else {
            let view = SettingsView()
                .environmentObject(store)
                .environmentObject(settings)
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            created.title = "F1 Live Settings"
            created.contentViewController = NSHostingController(rootView: view)
            created.isReleasedWhenClosed = false
            created.delegate = self
            window = created
            settingsWindow = created
        }

        center(settingsWindow, on: screen ?? NSScreen.main)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    private func center(_ window: NSWindow, on screen: NSScreen?) {
        guard let screen else {
            window.center()
            return
        }

        let visibleFrame = screen.visibleFrame
        let windowFrame = window.frame
        window.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - windowFrame.width / 2,
            y: visibleFrame.midY - windowFrame.height / 2
        ))
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
