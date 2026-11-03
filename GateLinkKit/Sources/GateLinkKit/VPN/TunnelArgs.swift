import Foundation

/// Validation for values that cross from the app into the root helper.
///
/// `scripts/gatelink-tunnel` repeats these checks as root. Checking here too
/// gives a clear message before anything privileged runs.
public enum TunnelArgs {
    /// A DNS name or IPv4 literal; never an option or a path.
    public static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("-") else { return false }
        return host.wholeMatch(of: #/[A-Za-z0-9](?:[A-Za-z0-9.\-]{0,251}[A-Za-z0-9])?/#) != nil
    }

    /// `sha256:...` or `pin-sha256:<base64>` as printed by openconnect.
    public static func isValidFingerprint(_ fingerprint: String) -> Bool {
        guard !fingerprint.isEmpty, fingerprint.count <= 200, !fingerprint.hasPrefix("-") else { return false }
        return fingerprint.wholeMatch(of: #/[A-Za-z0-9:._+\/=\-]+/#) != nil
    }

    /// A PID that is safe to signal: a number above 1.
    public static func tunnelPID(from text: String) -> Int32? {
        guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
        return pid
    }
}
