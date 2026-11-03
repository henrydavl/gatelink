import Foundation

/// An `otpauth://totp/...` URI: the payload of a 2FA QR code, or what a user
/// pastes when setting up an account by hand.
///
/// Format: `otpauth://totp/Issuer:account?secret=BASE32&issuer=Issuer&digits=6&period=30&algorithm=SHA1`
public struct OTPAuthURI: Sendable, Equatable {
    public var secret: String
    public var issuer: String?
    public var account: String?
    public var digits: Int = 6
    public var period: Int = 30
    public var algorithm: OTPAlgorithm = .sha1

    public static func parse(_ text: String) throws -> OTPAuthURI {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GateLinkError("The otpauth URI is empty.") }
        if trimmed.lowercased().hasPrefix("otpauth-migration://") {
            throw GateLinkError("Google Authenticator export codes are not supported. Use the account's original setup QR code.")
        }
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "otpauth"
        else {
            throw GateLinkError("Not an otpauth:// URI.")
        }
        guard components.host?.lowercased() == "totp" else {
            throw GateLinkError("Only time-based codes (otpauth://totp/...) are supported.")
        }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name.lowercased()] = item.value
        }
        guard let rawSecret = query["secret"], !rawSecret.isEmpty else {
            throw GateLinkError("The otpauth URI has no secret.")
        }
        // Surface a bad secret now, at setup time, not at connect time.
        _ = try Base32.decode(rawSecret)

        // The label is "Issuer:account" or just "account".
        var label = components.path
        if label.hasPrefix("/") { label.removeFirst() }
        var labelIssuer: String?
        var account: String? = label
        if let colon = label.firstIndex(of: ":"), colon != label.startIndex {
            labelIssuer = label[..<colon].trimmingCharacters(in: .whitespaces)
            account = label[label.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        var uri = OTPAuthURI(secret: normalizedSecret(rawSecret))
        uri.issuer = nonEmpty(query["issuer"]) ?? nonEmpty(labelIssuer)
        uri.account = nonEmpty(account)
        uri.digits = positiveInt(query["digits"]) ?? 6
        uri.period = positiveInt(query["period"]) ?? 30
        uri.algorithm = OTPAlgorithm(rawValue: (query["algorithm"] ?? "").uppercased()) ?? .sha1
        return uri
    }

    public func makeTOTP() throws -> TOTP {
        try TOTP(base32Secret: secret, digits: digits, period: period, algorithm: algorithm)
    }

    static func normalizedSecret(_ secret: String) -> String {
        secret.uppercased().filter { $0 != " " && $0 != "-" }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func positiveInt(_ value: String?) -> Int? {
        guard let value, let number = Int(value), number > 0 else { return nil }
        return number
    }
}
