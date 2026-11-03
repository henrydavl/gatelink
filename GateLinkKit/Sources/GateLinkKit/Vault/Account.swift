import Foundation

/// A saved VPN account. This part is not secret and is stored as plain JSON so
/// the account list loads without an unlock prompt.
public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Shown as the account title, e.g. "Example VPN".
    public var issuer: String
    /// The account label from the QR code, e.g. "jane@example.com".
    public var label: String
    /// The VPN login name sent to the gateway.
    public var username: String
    public var digits: Int
    public var period: Int
    public var algorithm: OTPAlgorithm
    /// Whether a VPN password is saved in the Keychain, so the UI can say so
    /// without reading the secret.
    public var hasPassword: Bool

    public init(
        id: UUID = UUID(),
        issuer: String,
        label: String,
        username: String,
        digits: Int = 6,
        period: Int = 30,
        algorithm: OTPAlgorithm = .sha1,
        hasPassword: Bool = false
    ) {
        self.id = id
        self.issuer = issuer
        self.label = label
        self.username = username
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
        self.hasPassword = hasPassword
    }
}

/// The protected part of an account, stored in the Keychain.
public struct AccountSecret: Codable, Equatable, Sendable {
    /// Base32 TOTP seed.
    public var otpSecret: String
    public var vpnPassword: String?

    public init(otpSecret: String, vpnPassword: String? = nil) {
        self.otpSecret = otpSecret
        self.vpnPassword = vpnPassword
    }

    public func makeTOTP(for account: Account) throws -> TOTP {
        try TOTP(base32Secret: otpSecret, digits: account.digits, period: account.period, algorithm: account.algorithm)
    }
}

/// A new account built from a QR code or manual input, not yet saved.
public struct AccountDraft: Equatable, Sendable {
    public var account: Account
    public var secret: AccountSecret

    public init(account: Account, secret: AccountSecret) {
        self.account = account
        self.secret = secret
    }

    public init(uri: OTPAuthURI, username: String? = nil) {
        let label = uri.account ?? ""
        account = Account(
            issuer: uri.issuer ?? "VPN",
            label: label,
            username: Self.trimmed(username) ?? label,
            digits: uri.digits,
            period: uri.period,
            algorithm: uri.algorithm
        )
        secret = AccountSecret(otpSecret: uri.secret)
    }

    /// Accepts either an `otpauth://` URI or a raw Base32 secret.
    public static func fromManualInput(_ text: String, issuer: String?, username: String?) throws -> AccountDraft {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            throw GateLinkError("Enter an otpauth:// URI or a secret key.")
        }
        if input.lowercased().hasPrefix("otpauth") {
            var draft = AccountDraft(uri: try OTPAuthURI.parse(input), username: username)
            if let issuer = trimmed(issuer) { draft.account.issuer = issuer }
            return draft
        }

        _ = try Base32.decode(input)
        let name = trimmed(username) ?? ""
        return AccountDraft(
            account: Account(issuer: trimmed(issuer) ?? "VPN", label: name, username: name),
            secret: AccountSecret(otpSecret: OTPAuthURI.normalizedSecret(input))
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
