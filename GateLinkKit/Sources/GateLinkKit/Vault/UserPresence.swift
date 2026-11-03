import Foundation
import LocalAuthentication

/// Confirms the person at the Mac is the owner before secrets are read.
public protocol UserPresenceVerifier: Sendable {
    /// Returns false when the user cancels or fails verification.
    func verify(reason: String) async -> Bool
}

/// Touch ID, Apple Watch, or the login password as a fallback.
public struct LocalAuthenticationVerifier: UserPresenceVerifier {
    public init() {}

    public func verify(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        // Without Touch ID or a passcode there is nothing to verify against;
        // the Keychain access list still protects the data.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return true
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
