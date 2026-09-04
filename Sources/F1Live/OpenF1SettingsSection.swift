import SwiftUI

struct OpenF1SettingsSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var controller: OpenF1AccountController
    @State private var clientID = ""
    @State private var clientSecret = ""

    var body: some View {
        Section {
            Text("Optional: connect your own paid OpenF1 account for live timing.")
                .font(.callout)
            if !controller.requiresAuthorization { credentialFields }
            if controller.isBusy { ProgressView().controlSize(.small) }
            Label(controller.statusMessage,
                  systemImage: controller.errorMessage != nil ? "exclamationmark.triangle" : controller.isConnected ? "checkmark.circle" : "lock")
                .font(.caption)
                .foregroundStyle(controller.errorMessage != nil ? Color.orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !controller.isLoaded, controller.errorMessage != nil {
                Button(controller.requiresAuthorization ? "Authorize Saved Credentials" : "Retry Keychain Access") {
                    Task {
                        let authorized = await controller.authorizeSavedCredentials()
                        clientID = controller.clientID
                        if authorized { await store.openF1CredentialsChanged() }
                    }
                }
            }
            Link("Get OpenF1 credentials…", destination: SupportLinks.openF1Account)
                .font(.caption)
        } header: {
            Text("OpenF1 Live Timing")
        } footer: {
            Text("Use the personal API credentials provided by OpenF1. Your subscription is managed by OpenF1. F1 Live remains free, and credentials stay in this Mac’s Keychain.")
        }
        .disabled(controller.isBusy)
        .task {
            await controller.refreshStatus()
            clientID = controller.clientID
        }
        .onDisappear { clientSecret = "" }
    }

    private var credentialFields: some View {
        Group {
            TextField("Client ID", text: $clientID)
                .autocorrectionDisabled()
            SecureField("Client Secret", text: $clientSecret,
                        prompt: Text(controller.hasCredentials ? "Saved in Keychain" : "Enter your Client Secret"))
            HStack {
                Button("Save & Test Connection") {
                    Task {
                        let secret = clientSecret
                        clientSecret = ""
                        let saved = await controller.saveAndTest(clientID: clientID, clientSecret: secret)
                        if saved {
                            clientID = controller.clientID
                            await store.openF1CredentialsChanged()
                        }
                    }
                }
                .disabled(!canSave || controller.isBusy)
                Spacer()
                if controller.hasCredentials {
                    Button("Remove Credentials", role: .destructive) {
                        Task {
                            if await controller.removeCredentials() {
                                clientID = ""
                                clientSecret = ""
                                await store.openF1CredentialsChanged()
                            }
                        }
                    }
                    .disabled(controller.isBusy)
                }
            }
        }
    }

    private var canSave: Bool {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !id.isEmpty && (!clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (controller.hasCredentials && id == controller.clientID))
    }
}
