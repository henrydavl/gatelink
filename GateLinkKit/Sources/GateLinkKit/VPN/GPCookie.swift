import Foundation

/// The session details `openconnect --protocol=gp --authenticate` prints on
/// success: `COOKIE`, `HOST`, `CONNECT_URL`, `FINGERPRINT` and `RESOLVE`.
public struct GPCookie: Equatable, Sendable {
    /// The WebVPN session cookie, passed to the tunnel on stdin.
    public var cookie: String
    /// The gateway host for the tunnel.
    public var host: String
    public var connectURL: String?
    /// Server certificate pin, passed as `--servercert`.
    public var fingerprint: String?
    public var resolve: String?

    /// Parses the `KEY='value'` block. `fallbackHost` is used when the output
    /// has no `HOST` line.
    public static func parse(_ output: String, fallbackHost: String) throws -> GPCookie {
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
        return GPCookie(
            cookie: cookie,
            host: values["HOST"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackHost,
            connectURL: values["CONNECT_URL"],
            fingerprint: values["FINGERPRINT"],
            resolve: values["RESOLVE"]
        )
    }

    /// openconnect prints shell-style values such as `HOST='203.0.113.10'`.
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "'" || first == "\"" else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}
