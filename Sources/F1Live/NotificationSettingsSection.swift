import SwiftUI

struct NotificationSettingsSection: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var controller: NotificationController

    var body: some View {
        Section {
            Toggle("Session reminders", isOn: Binding(
                get: { settings.notifications },
                set: { enabled in
                    if !enabled { controller.disableReminders(for: .sessions) }
                    else { Task { await controller.enableReminders(for: .sessions) } }
                }
            ))
            .disabled(!controller.isAvailable || controller.permission == nil || controller.isRequesting)

            TextField("Minutes before", text: $settings.notifyLeadMinutes)
                .disabled(!settings.notifications || !controller.canSchedule)
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
            .disabled(!settings.notifications || !controller.canSchedule)

            Divider()

            Toggle("F1 Fantasy team-lock reminders", isOn: Binding(
                get: { settings.fantasyTeamLockReminders },
                set: { enabled in
                    if !enabled { controller.disableReminders(for: .fantasyTeamLock) }
                    else { Task { await controller.enableReminders(for: .fantasyTeamLock) } }
                }
            ))
            .disabled(!controller.isAvailable || controller.permission == nil || controller.isRequesting)

            Text("Arrives 24 hours and 1 hour before teams lock. The deadline is Qualifying on normal weekends and the Sprint on Sprint weekends.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if controller.shouldShowSystemSettings && controller.isAvailable {
                Button("Open System Settings…") { controller.openSystemSettings() }
            }
            if let error = controller.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(controller.statusMessage)
                .foregroundStyle(controller.isBlocked ? Color.orange : Color.secondary)
        }
    }
}
