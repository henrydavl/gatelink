import GateLinkKit
import SwiftUI

/// Status line, credential form and the Connect / Cancel / Disconnect button.
struct ConnectionSection: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var phase: VPNPhase { model.session.phase }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.statusText, systemImage: model.statusSymbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(model.statusColor)

            if !phase.isConnected {
                form
                    .disabled(phase.isBusy)
            }

            primaryButton
                .controlSize(.large)
                .disabled(phase == .disconnecting)

            if let feedback = model.feedback {
                if model.feedbackIsError {
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
            Text(model.buttonTitle)
                .frame(maxWidth: .infinity)
        }
        if phase.isConnected {
            button.buttonStyle(.bordered).foregroundStyle(.red)
        } else {
            button.buttonStyle(.borderedProminent).tint(model.buttonTint).keyboardShortcut(.defaultAction)
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
}
