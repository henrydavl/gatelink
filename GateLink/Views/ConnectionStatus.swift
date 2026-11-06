import GateLinkKit
import SwiftUI

/// How the connection phase and messages read.
extension AppModel {
    private var phase: VPNPhase { session.phase }

    var statusText: String {
        switch phase {
        case .idle, .failed: "Not connected"
        case .authenticating: "Logging in…"
        case .connecting: "Waiting for GlobalProtect…"
        case .connected: "Connected through GlobalProtect"
        }
    }

    var statusSymbol: String {
        switch phase {
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .idle: "circle"
        case .authenticating, .connecting: "arrow.triangle.2.circlepath"
        }
    }

    var statusColor: Color {
        switch phase {
        case .connected: .green
        case .idle, .failed: .secondary
        case .authenticating, .connecting: .accentColor
        }
    }

    var buttonTitle: String {
        switch phase {
        case .connected: "Open GlobalProtect"
        case .authenticating, .connecting: "Cancel"
        case .idle, .failed: "Connect"
        }
    }

    var buttonTint: Color {
        switch phase {
        case .authenticating, .connecting, .connected: .gray
        case .idle, .failed: .accentColor
        }
    }

    var feedback: String? {
        if case .failed(let reason) = phase, message == nil { return reason }
        return message
    }

    var feedbackIsError: Bool {
        if case .failed = phase, message == nil { return true }
        guard let message = message else { return false }
        return !(message.hasPrefix("Added") || message.hasPrefix("Deleted") || message.hasPrefix("Code copied") || message.hasPrefix("Password saved")
            || message.hasSuffix("is up to date.") || message.hasPrefix("Update cancelled"))
    }
}
