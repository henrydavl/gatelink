import Foundation

/// A failure with a message that is safe to show to the user as is.
///
/// Messages never contain secrets (seed, password, OTP or session cookie).
public struct GateLinkError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
