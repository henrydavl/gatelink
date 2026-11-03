import GateLinkKit
import SwiftUI

/// Sets the VPN password for the selected account. A regular window, so the
/// Passwords app can AutoFill it.
struct PasswordView: View {
    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var password = ""
    @State private var showsPassword = false
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("VPN Password")
                .font(.title2.bold())

            if let account = model.account {
                Text("For \(account.issuer) (\(account.username)). It is saved in your Keychain; GateLink adds the current code when it logs in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Group {
                    if showsPassword {
                        TextField("Password", text: $password, prompt: Text("VPN password"))
                    } else {
                        SecureField("Password", text: $password, prompt: Text("VPN password"))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                Button {
                    showsPassword.toggle()
                } label: {
                    Image(systemName: showsPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(showsPassword ? "Hide password" : "Show password")
                .accessibilityLabel(showsPassword ? "Hide password" : "Show password")
            }

            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        saving = true
                        if await model.savePassword(password) { close() }
                        saving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || saving || model.account == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onDisappear {
            // Also when closed with the title bar button: never keep a typed password around.
            password = ""
            showsPassword = false
        }
    }

    private func close() {
        dismissWindow(id: WindowID.password)
    }
}
