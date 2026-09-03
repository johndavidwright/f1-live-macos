import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var updates: UpdateController
    @StateObject private var loginItem = LoginItemController()

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Open at Login",
                    isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { loginItem.setEnabled($0) }
                    )
                )
                .disabled(!loginItem.isAvailable)

                if loginItem.requiresApproval {
                    Button("Open Login Items Settings…") { loginItem.openSystemSettings() }
                }
                if let errorMessage = loginItem.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("General")
            } footer: {
                Text(loginItem.statusMessage)
            }

            Section("Display") {
                Picker("Time format", selection: $settings.useTwelveHourTime) {
                    Text("24-hour").tag(false)
                    Text("12-hour").tag(true)
                }
                Toggle("Switch to live timing when a race starts", isOn: $settings.autoLive)
            }

            Section("Updates") {
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                Toggle(
                    "Automatically download and install updates",
                    isOn: Binding(
                        get: { updates.automaticallyDownloadsUpdates },
                        set: { updates.setAutomaticallyDownloadsUpdates($0) }
                    )
                )
                .disabled(!updates.allowsAutomaticUpdates)

                HStack {
                    Button("Check for Updates…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                    Spacer()
                    Text(updates.versionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if let standings = store.data?.standings, !standings.isEmpty {
                    ScrollView {
                        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], alignment: .leading, spacing: 8) {
                            ForEach(standings) { driver in
                                Toggle(isOn: favoriteBinding(for: driver)) {
                                    HStack(spacing: 7) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color(hex: TeamColours.hex(constructorID: driver.constructorID, name: driver.constructorName)))
                                            .frame(width: 4, height: 24)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(driver.fullName).lineLimit(1)
                                            Text("P\(driver.position) · \(driver.code)").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 245)

                    HStack {
                        Text("\(settings.favoriteDriverIDs.count) selected")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear Favorites") { settings.clearFavorites() }
                            .disabled(settings.favoriteDriverIDs.isEmpty)
                    }
                    .font(.caption)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading drivers…").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Favorite Drivers")
            } footer: {
                Text("Favorites are highlighted in the standings. Selected drivers outside the top five are appended to the list.")
            }

            Section("Refresh") {
                Stepper("Live timing: every \(settings.liveRefreshSeconds) seconds", value: $settings.liveRefreshSeconds, in: 5...120)
                Stepper("Calendar and standings: every \(settings.refreshMinutes) minutes", value: $settings.refreshMinutes, in: 5...720, step: 5)
            }

            Section("Notifications") {
                Toggle("Session notifications", isOn: $settings.notifications)
                TextField("Minutes before", text: $settings.notifyLeadMinutes)
                    .disabled(!settings.notifications)
                    .help("Comma-separated values, such as 60,30,15")
                Grid(alignment: .leading) {
                    GridRow {
                        Toggle("Race", isOn: $settings.notifyRace)
                        Toggle("Qualifying", isOn: $settings.notifyQualifying)
                    }
                    GridRow {
                        Toggle("Sprint", isOn: $settings.notifySprint)
                        Toggle("Practice", isOn: $settings.notifyPractice)
                    }
                }
                .disabled(!settings.notifications)
            }

            Section {
                Button("Refresh Now") { Task { await store.refresh() } }
                Button("Quit F1 Live") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 680)
        .navigationTitle("F1 Live Settings")
        .onAppear { loginItem.refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refreshStatus()
        }
    }

    private func favoriteBinding(for driver: DriverStanding) -> Binding<Bool> {
        Binding(
            get: { settings.isFavorite(driver.id) },
            set: { settings.setFavorite(driver.id, enabled: $0) }
        )
    }
}
