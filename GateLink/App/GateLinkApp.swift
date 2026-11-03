import GateLinkKit
import SwiftUI

enum WindowID {
    static let addAccount = "add-account"
    static let requirements = "requirements"
    static let password = "password"
}

@main
struct GateLinkApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            Image(systemName: model.session.phase.menuBarSymbol)
                .accessibilityLabel("GateLink")
        }
        .menuBarExtraStyle(.window)

        Window("Add Account", id: WindowID.addAccount) {
            AddAccountView(model: model)
        }
        .windowResizability(.contentSize)

        // A real window, not the popover: the popover closes when the
        // Passwords AutoFill picker takes focus, so AutoFill never lands.
        Window("VPN Password", id: WindowID.password) {
            PasswordView(model: model)
        }
        .windowResizability(.contentSize)

        Window("Requirements", id: WindowID.requirements) {
            RequirementsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

extension VPNPhase {
    var menuBarSymbol: String {
        switch self {
        case .connected: "checkmark.shield.fill"
        case .authenticating, .connecting, .reconnecting, .disconnecting: "shield.lefthalf.filled"
        case .failed: "exclamationmark.shield"
        case .idle: "shield"
        }
    }
}
