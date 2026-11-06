public enum VPNPhase: Equatable, Sendable {
    case idle
    case authenticating
    case connecting
    case connected
    case failed(String)

    /// A login is in progress.
    public var isBusy: Bool {
        self == .authenticating || self == .connecting
    }

    public var isConnected: Bool { self == .connected }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// What one login needs. The OTP is generated from `totp` at the last moment.
public struct VPNCredentials: Sendable {
    public var username: String
    public var password: String
    public var totp: TOTP

    public init(username: String, password: String, totp: TOTP) {
        self.username = username
        self.password = password
        self.totp = totp
    }
}
