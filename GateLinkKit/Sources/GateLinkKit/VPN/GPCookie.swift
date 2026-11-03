import Foundation

/// The session details `openconnect --protocol=gp --authenticate` prints on
/// success. GateLink uses `COOKIE` and `FINGERPRINT`; the tunnel always goes to
/// the portal name the user entered.
public struct GPCookie: Equatable, Sendable {
    /// The WebVPN session cookie, passed to the tunnel on stdin.
    public var cookie: String
    /// Server certificate pin, passed as `--servercert`.
    public var fingerprint: String?

    public init(cookie: String, fingerprint: String?) {
        self.cookie = cookie
        self.fingerprint = fingerprint
    }

    /// Parses the `KEY='value'` block.
    public static func parse(_ output: String) throws -> GPCookie {
        var values: [String: String] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let equals = line.firstIndex(of: "="), equals != line.startIndex else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).uppercased()
            let value = unquote(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
            values[key] = value
        }

        guard let cookie = values["COOKIE"], !cookie.isEmpty else {
            throw GateLinkError("The gateway did not return a session cookie. Wrong password or OTP?")
        }
        return GPCookie(cookie: cookie, fingerprint: values["FINGERPRINT"])
    }

    /// openconnect prints shell-style values such as `HOST='203.0.113.10'`.
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "'" || first == "\"" else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}
