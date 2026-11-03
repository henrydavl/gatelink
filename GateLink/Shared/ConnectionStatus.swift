import GateLinkKit
import SwiftUI

/// How the connection phase and messages read, on macOS and iOS alike.
extension AppModel {
    private var phase: VPNPhase { session.phase }

    var statusText: String {
        switch phase {
        case .idle, .failed: "Not connected"
        case .authenticating: "Logging in…"
        case .connecting: "Starting the tunnel…"
        case .connected(let since):
            "Connected to \(session.gateway ?? gateway) since \(since.formatted(date: .omitted, time: .shortened))"
        case .reconnecting(let attempt): "Connection lost. Reconnecting (attempt \(attempt))…"
        case .disconnecting: "Disconnecting…"
        }
    }

    var statusSymbol: String {
        switch phase {
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .idle: "circle"
        default: "arrow.triangle.2.circlepath"
        }
    }

    var statusColor: Color {
        switch phase {
        case .connected: .green
        case .idle, .failed: .secondary
        default: .accentColor
        }
    }

    var buttonTitle: String {
        switch phase {
        case .connected: "Disconnect"
        case .authenticating, .connecting, .reconnecting: "Cancel"
        case .disconnecting: "Disconnecting…"
        case .idle, .failed: "Connect"
        }
    }

    var buttonTint: Color {
        switch phase {
        case .authenticating, .connecting, .reconnecting, .disconnecting, .connected: .gray
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
            || message.hasPrefix("GateLink needs") || message.hasPrefix("The tunnel helper was removed")
            || message.hasSuffix("is up to date.") || message.hasPrefix("Update cancelled"))
    }
}
