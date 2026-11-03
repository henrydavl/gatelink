import CryptoKit
import Foundation

public enum OTPAlgorithm: String, Codable, Sendable, CaseIterable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"
}

/// Time-based one-time password generator (RFC 6238 on top of RFC 4226).
public struct TOTP: Sendable, Equatable {
    public let digits: Int
    public let period: Int
    public let algorithm: OTPAlgorithm
    private let secret: Data

    public init(secret: Data, digits: Int = 6, period: Int = 30, algorithm: OTPAlgorithm = .sha1) throws {
        guard !secret.isEmpty else { throw GateLinkError("The secret key is empty.") }
        guard (6...8).contains(digits) else { throw GateLinkError("Codes must have 6 to 8 digits.") }
        guard period > 0 else { throw GateLinkError("The code period must be positive.") }
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }

    public init(base32Secret: String, digits: Int = 6, period: Int = 30, algorithm: OTPAlgorithm = .sha1) throws {
        try self.init(secret: Base32.decode(base32Secret), digits: digits, period: period, algorithm: algorithm)
    }

    /// The RFC 6238 time step that contains `date`.
    public func counter(at date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970)) / UInt64(period)
    }

    public func code(at date: Date = .now) -> String {
        code(forCounter: counter(at: date))
    }

    /// Seconds until the code shown at `date` rolls over (1...period).
    public func secondsRemaining(at date: Date = .now) -> Int {
        period - Int(UInt64(max(0, date.timeIntervalSince1970)) % UInt64(period))
    }

    /// The first instant of the time step after the one containing `date`.
    public func nextRollover(after date: Date) -> Date {
        Date(timeIntervalSince1970: TimeInterval((counter(at: date) + 1) * UInt64(period)))
    }

    public func code(forCounter counter: UInt64) -> String {
        var bigEndian = counter.bigEndian
        let message = Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size)
        let key = SymmetricKey(data: secret)
        let hash: [UInt8] = switch algorithm {
        case .sha1: Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }

        // Dynamic truncation, RFC 4226 section 5.3.
        let offset = Int(hash[hash.count - 1] & 0x0F)
        let binary = (UInt32(hash[offset] & 0x7F) << 24)
            | (UInt32(hash[offset + 1]) << 16)
            | (UInt32(hash[offset + 2]) << 8)
            | UInt32(hash[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        let value = String(binary % modulus)
        return String(repeating: "0", count: digits - value.count) + value
    }
}
