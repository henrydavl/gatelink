import Foundation

/// Names shared by the iOS app and its Packet Tunnel extension.
enum TunnelShared {
    /// startVPNTunnel(options:) keys: the app logs in, the extension tunnels.
    static let hostKey = "host"
    static let cookieKey = "cookie"
    static let fingerprintKey = "fingerprint"

    /// The extension leaves its last failure here; iOS reports only a generic error.
    static let appGroup = "group.com.example.gatelink"
    static let lastErrorKey = "lastError"

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// The message GLOpenConnect wrote into an error buffer.
    static func string(_ buffer: [CChar]) -> String {
        buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
