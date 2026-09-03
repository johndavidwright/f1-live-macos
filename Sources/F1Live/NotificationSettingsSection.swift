import SwiftUI

struct NotificationSettingsSection: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var controller: NotificationController
    @State private var showingIntroduction = false

    var body: some View {
        Section {
            Toggle("Session reminders", isOn: Binding(
                get: { settings.notifications && controller.canSchedule },
                set: { enabled in
                    if !enabled { controller.disableReminders() }
                    else if controller.needsIntroduction { showingIntroduction = true }
                    else { Task { await controller.enableReminders() } }
                }
            ))
            .disabled(!controller.isAvailable || controller.permission == nil || controller.isRequesting)

            if controller.isRequesting {
                ProgressView("Waiting for notification permission…").controlSize(.small)
            }
            if controller.permission != nil && !controller.needsIntroduction && controller.isAvailable {
                Button("Open System Settings…") { controller.openSystemSettings() }
            }
            if let error = controller.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

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
        } header: {
            Text("Notifications")
        } footer: {
            Text(controller.statusMessage)
                .foregroundStyle(controller.isBlocked ? Color.orange : Color.secondary)
        }
        .sheet(isPresented: $showingIntroduction) {
            VStack(alignment: .leading, spacing: 16) {
                Label("Session reminders", systemImage: "bell.badge")
                    .font(.title2.weight(.semibold))
                Text("F1 Live can remind you before your selected sessions, when they start, and at their scheduled finish.")
                Text("You choose the sessions and reminder times. macOS will ask whether to allow notifications and sounds; you can change your choice later in Settings.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Not Now") { showingIntroduction = false }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Continue") {
                        showingIntroduction = false
                        Task { await controller.enableReminders() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 400)
        }
    }
}
