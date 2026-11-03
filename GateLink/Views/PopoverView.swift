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

/// The current code with a countdown ring, or a masked placeholder.
private struct CodeView: View {
    let totp: TOTP?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                if let totp {
                    Text(Self.grouped(totp.code(at: context.date)))
                        .font(.system(.title3, design: .monospaced))
                        .contentTransition(.numericText())
                    Countdown(remaining: totp.secondsRemaining(at: context.date), period: totp.period)
                } else {
                    Text("••• •••")
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Code hidden")
                }
            }
        }
    }

    static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return code.prefix(3) + " " + code.suffix(3)
    }
}

private struct Countdown: View {
    let remaining: Int
    let period: Int

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(remaining) / CGFloat(period))
                .stroke(remaining <= 5 ? Color.orange : Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(remaining)")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel("\(remaining) seconds left")
    }
}
