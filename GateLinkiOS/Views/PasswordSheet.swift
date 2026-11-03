import GateLinkKit
import SwiftUI

/// Sets the VPN password for the selected account. Passwords AutoFill works here.
struct PasswordSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var showsPassword = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Group {
                            if showsPassword {
                                TextField("VPN password", text: $password)
                            } else {
                                SecureField("VPN password", text: $password)
                            }
                        }
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        Button {
                            showsPassword.toggle()
                        } label: {
                            Image(systemName: showsPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showsPassword ? "Hide password" : "Show password")
                    }
                } footer: {
                    if let account = model.account {
                        Text("For \(account.issuer) (\(account.username)). It is saved in your Keychain; GateLink adds the current code when it logs in.")
                    }
                }
            }
            .navigationTitle("VPN Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            saving = true
                            if await model.savePassword(password) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(password.isEmpty || saving || model.account == nil)
                }
            }
        }
        .onDisappear {
            // Never keep a typed password around.
            password = ""
            showsPassword = false
        }
    }
}
