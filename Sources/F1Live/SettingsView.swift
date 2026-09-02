import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("Display") {
                Picker("Time format", selection: $settings.useTwelveHourTime) {
                    Text("24-hour").tag(false)
                    Text("12-hour").tag(true)
                }
                Toggle("Switch to live timing when a race starts", isOn: $settings.autoLive)
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
    }

    private func favoriteBinding(for driver: DriverStanding) -> Binding<Bool> {
        Binding(
            get: { settings.isFavorite(driver.id) },
            set: { settings.setFavorite(driver.id, enabled: $0) }
        )
    }
}
