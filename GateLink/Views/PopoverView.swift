import GateLinkKit
import SwiftUI

/// The menu bar popover: account and code, connection form, footer.
struct PopoverView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let account = model.account {
                AccountRow(model: model, account: account, openWindow: open)
            } else {
                emptyState
            }
            Divider()
            ConnectionSection(model: model)
            Divider()
            footer
        }
        .frame(width: 340)
        .background(GeometryReader { FitWindowToContent(height: $0.size.height) })
    }

    private var header: some View {
        HStack {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.tint)
                .font(.title3)
            Text("GateLink")
                .font(.headline)
            Spacer()
            Button {
                open(WindowID.addAccount)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add Account")
            .accessibilityLabel("Add Account")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No 2FA account yet")
                .font(.headline)
            Text("Add the QR code or secret key your VPN gave you.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Account…") { open(WindowID.addAccount) }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Text("v\(model.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            UpdateBadge(model: model)
            Spacer()
            Toggle("Open at Login", isOn: Binding(
                get: { model.openAtLogin },
                set: { model.setOpenAtLogin($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            Button("Quit") { model.quit() }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
    }
}

private struct AccountRow: View {
    let model: AppModel
    let account: Account
    let openWindow: (String) -> Void
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.issuer)
                    .font(.headline)
                    .lineLimit(1)
                Text(account.username.isEmpty ? account.label : account.username)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if model.vault.accounts.count > 1 {
                accountSwitcher
            }
            Spacer(minLength: 8)
            Button {
                Task { await model.copyCode() }
            } label: {
                CodeView(totp: model.revealed)
            }
            .buttonStyle(.plain)
            .help("Copy code")
            Button {
                Task { await model.copyCode() }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy code")
            .accessibilityLabel("Copy code")
            Button {
                Task { await model.toggleReveal() }
            } label: {
                Image(systemName: model.revealed == nil ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .help(model.revealed == nil ? "Show code" : "Hide code")
            .accessibilityLabel(model.revealed == nil ? "Show code" : "Hide code")

            Menu {
                Button("Requirements…") { openWindow(WindowID.requirements) }
                Button("Check for Updates") { Task { await model.checkForUpdate() } }
                    .disabled(model.updateStep != nil)
                Divider()
                Button("Delete Account…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .confirmationDialog("Delete \(account.issuer)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await model.deleteCurrentAccount() } }
        } message: {
            Text("The 2FA secret and saved password are removed from this Mac.")
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
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "chevron.up.chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!model.canSwitchAccount)
        .help(model.canSwitchAccount ? "Switch Account" : "Disconnect to switch accounts")
        .accessibilityLabel("Switch Account")
    }
}

/// The menu bar window grows with its content but never shrinks, so when the
/// form hides on connect the content floats in empty space. Resize the window
/// to the content, keeping its top edge under the menu bar.
private struct FitWindowToContent: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window, height > 0 else { return }
            var frame = window.frame
            let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: frame.width, height: height)).height
            guard abs(frame.height - target) > 0.5 else { return }
            frame.origin.y += frame.height - target
            frame.size.height = target
            window.setFrame(frame, display: true)
        }
    }
}

/// Beside the version: a button to install a newer release, then its progress.
private struct UpdateBadge: View {
    let model: AppModel

    var body: some View {
        if let step = model.updateStep {
            HStack(spacing: 4) {
                switch step {
                case .downloading(let fraction):
                    ProgressView(value: fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                    Text("Downloading \(Int(fraction * 100))%")
                case .verifying:
                    ProgressView().controlSize(.mini)
                    Text("Verifying…")
                case .installing:
                    ProgressView().controlSize(.mini)
                    Text("Installing…")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let update = model.availableUpdate {
            Button {
                Task { await model.installUpdate() }
            } label: {
                Label("Update to v\(update.version)", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help(installHelp(update))
            .contextMenu {
                Button("Release Notes") { model.openReleaseNotes() }
            }
        }
    }

    private func installHelp(_ update: AppUpdate) -> String {
        var text = "Download, verify and install GateLink \(update.version), then reopen."
        if model.session.phase.isConnected || model.session.phase.isBusy {
            text += " Installing disconnects the VPN."
        }
        let notes = update.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.isEmpty ? text : text + "\n\n" + notes
    }
}
