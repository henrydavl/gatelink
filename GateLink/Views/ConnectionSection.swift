import GateLinkKit
import SwiftUI

/// Status line, credential form and the Connect / Cancel / Open GlobalProtect button.
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

    @ViewBuilder
    private var primaryButton: some View {
        let button = Button {
            Task { await model.primaryAction() }
        } label: {
            Text(model.buttonTitle)
                .frame(maxWidth: .infinity)
        }
        if phase.isConnected {
            button.buttonStyle(.bordered)
        } else {
            button.buttonStyle(.borderedProminent).tint(model.buttonTint).keyboardShortcut(.defaultAction)
        }
    }

    private var form: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text("Username").gridColumnAlignment(.trailing)
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
