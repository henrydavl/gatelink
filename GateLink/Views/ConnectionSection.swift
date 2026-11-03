import GateLinkKit
import SwiftUI

/// Status line, credential form and the Connect / Cancel / Disconnect button.
struct ConnectionSection: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var phase: VPNPhase { model.session.phase }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(statusText, systemImage: statusSymbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(statusColor)

            if !phase.isConnected {
                form
                    .disabled(phase.isBusy)
            }

            primaryButton
                .controlSize(.large)
                .disabled(phase == .disconnecting)

            if let feedback {
                if isError {
                    ErrorCallout(message: feedback)
                } else {
                    Text(feedback)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(16)
    }

    /// Disconnect is a gray button with a red label; a solid red one is too loud.
    /// It is not the Return-key default: macOS draws the default button blue,
    /// and Return should never drop the VPN.
    @ViewBuilder
    private var primaryButton: some View {
        let button = Button {
            Task { await model.primaryAction() }
        } label: {
            Text(buttonTitle)
                .frame(maxWidth: .infinity)
        }
        if phase.isConnected {
            button.buttonStyle(.bordered).foregroundStyle(.red)
        } else {
            button.buttonStyle(.borderedProminent).tint(buttonTint).keyboardShortcut(.defaultAction)
        }
    }

    private var form: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text("Portal").gridColumnAlignment(.trailing)
                TextField("Portal", text: $model.gateway, prompt: Text("vpn.example.com"))
                    .labelsHidden()
                    .textContentType(.URL)
            }
            GridRow {
                Text("Username")
                TextField("Username", text: $model.username, prompt: Text("VPN username"))
                    .labelsHidden()
            }
            GridRow {
                Text("Password")
                HStack {
                    Text(hasPassword ? "Saved in Keychain" : "Not set")
                        .foregroundStyle(hasPassword ? Color.secondary : Color.orange)
                    Spacer()
                    Button(hasPassword ? "Change…" : "Set…") {
                        openWindow(id: WindowID.password)
                        NSApp.activate()
                    }
                    .disabled(model.account == nil)
                }
            }
        }
        .font(.callout)
    }

    private var hasPassword: Bool {
        model.account?.hasPassword == true
    }

    private var statusText: String {
        switch phase {
        case .idle, .failed: "Not connected"
        case .authenticating: "Logging in…"
        case .connecting: "Starting the tunnel…"
        case .connected(let since):
            "Connected to \(model.session.gateway ?? model.gateway) since \(since.formatted(date: .omitted, time: .shortened))"
        case .reconnecting(let attempt): "Connection lost. Reconnecting (attempt \(attempt))…"
        case .disconnecting: "Disconnecting…"
        }
    }

    private var statusSymbol: String {
        switch phase {
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .idle: "circle"
        default: "arrow.triangle.2.circlepath"
        }
    }

    private var statusColor: Color {
        switch phase {
        case .connected: .green
        case .idle, .failed: .secondary
        default: .accentColor
        }
    }

    private var buttonTitle: String {
        switch phase {
        case .connected: "Disconnect"
        case .authenticating, .connecting, .reconnecting: "Cancel"
        case .disconnecting: "Disconnecting…"
        case .idle, .failed: "Connect"
        }
    }

    private var buttonTint: Color {
        switch phase {
        case .authenticating, .connecting, .reconnecting, .disconnecting, .connected: .gray
        case .idle, .failed: .accentColor
        }
    }

    private var feedback: String? {
        if case .failed(let reason) = phase, model.message == nil { return reason }
        return model.message
    }

    private var isError: Bool {
        if case .failed = phase, model.message == nil { return true }
        guard let message = model.message else { return false }
        return !(message.hasPrefix("Added") || message.hasPrefix("Deleted") || message.hasPrefix("Code copied") || message.hasPrefix("Password saved")
            || message.hasPrefix("GateLink needs") || message.hasPrefix("The tunnel helper was removed")
            || message.hasSuffix("is up to date.") || message.hasPrefix("Update cancelled"))
    }
}

/// An error message in a soft red box, calmer than red text.
struct ErrorCallout: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }
}
