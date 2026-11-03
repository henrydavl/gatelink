import GateLinkKit
import SwiftUI

/// The iPhone version of the menu bar popover: account and code, connection
/// form, and the Connect / Cancel / Disconnect button.
struct ContentView: View {
    @Bindable var model: AppModel
    @State private var addingAccount = false
    @State private var settingPassword = false
    @State private var confirmDelete = false

    private var phase: VPNPhase { model.session.phase }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let account = model.account {
                        AccountRow(model: model, account: account)
                    } else {
                        emptyState
                    }
                }

                Section {
                    Label(model.statusText, systemImage: model.statusSymbol)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(model.statusColor)
                    if !phase.isConnected {
                        form.disabled(phase.isBusy)
                    }
                }

                Section {
                    primaryButton
                        .disabled(phase == .disconnecting)
                    if let feedback = model.feedback {
                        if model.feedbackIsError {
                            ErrorCallout(message: feedback)
                        } else {
                            Text(feedback)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section {
                } footer: {
                    Text("GateLink \(model.version)")
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("GateLink")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addingAccount = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Account")
                }
                if model.account != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("Delete Account…", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More")
                    }
                }
            }
            .confirmationDialog("Delete \(model.account?.issuer ?? "")?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await model.deleteCurrentAccount() } }
            } message: {
                Text("The 2FA secret and saved password are removed from this iPhone.")
            }
            .sheet(isPresented: $addingAccount) { AddAccountSheet(model: model) }
            .sheet(isPresented: $settingPassword) { PasswordSheet(model: model) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No 2FA account yet")
                .font(.headline)
            Text("Add the QR code or secret key your VPN gave you.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Account…") { addingAccount = true }
                .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var form: some View {
        LabeledContent("Portal") {
            TextField("Portal", text: $model.gateway, prompt: Text("vpn.example.com"))
                .multilineTextAlignment(.trailing)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        LabeledContent("Username") {
            TextField("Username", text: $model.username, prompt: Text("VPN username"))
                .multilineTextAlignment(.trailing)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        LabeledContent("Password") {
            HStack(spacing: 12) {
                Text(hasPassword ? "Saved in Keychain" : "Not set")
                    .foregroundStyle(hasPassword ? Color.secondary : Color.orange)
                Button(hasPassword ? "Change…" : "Set…") { settingPassword = true }
                    .buttonStyle(.borderless)
                    .disabled(model.account == nil)
            }
        }
    }

    private var hasPassword: Bool {
        model.account?.hasPassword == true
    }

    /// Disconnect is a gray button with a red label; a solid red one is too loud.
    @ViewBuilder
    private var primaryButton: some View {
        let button = Button {
            Task { await model.primaryAction() }
        } label: {
            Text(model.buttonTitle)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        if phase.isConnected {
            button.buttonStyle(.bordered).foregroundStyle(.red)
        } else {
            button.buttonStyle(.borderedProminent).tint(model.buttonTint)
        }
    }
}

/// Issuer and username, the account switcher, and the code with copy and reveal.
private struct AccountRow: View {
    let model: AppModel
    let account: Account

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(account.issuer)
                        .font(.headline)
                        .lineLimit(1)
                    if model.vault.accounts.count > 1 {
                        accountSwitcher
                    }
                }
                Text(account.username.isEmpty ? account.label : account.username)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                Task { await model.copyCode() }
            } label: {
                CodeView(totp: model.revealed)
            }
            .buttonStyle(.borderless)
            .tint(.primary)
            .accessibilityHint("Copies the code")
            Button {
                Task { await model.copyCode() }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy code")
            Button {
                Task { await model.toggleReveal() }
            } label: {
                Image(systemName: model.revealed == nil ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(model.revealed == nil ? "Show code" : "Hide code")
        }
    }

    private var accountSwitcher: some View {
        Menu {
            Picker("Account", selection: Binding(
                get: { account.id },
                set: { id in
                    if let picked = model.vault.accounts.first(where: { $0.id == id }) { model.select(picked) }
                }
            )) {
                ForEach(model.vault.accounts) { other in
                    Text(other.issuer + (other.username.isEmpty ? "" : " (\(other.username))")).tag(other.id)
                }
            }
        } label: {
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
        }
        .disabled(!model.canSwitchAccount)
        .accessibilityLabel("Switch Account")
    }
}
