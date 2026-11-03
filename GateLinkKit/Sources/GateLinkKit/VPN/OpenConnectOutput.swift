import Foundation

/// Heuristics for reading openconnect's human-readable output.
public enum OpenConnectOutput {
    /// Lines openconnect prints once the tunnel carries traffic.
    public static func isEstablished(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("configured as")
            || lower.contains("connected as")
            || lower.contains("esp session established")
    }

    /// True when the text ends with a credential prompt waiting for input,
    /// e.g. `Password: `. Only the last line counts, so a URL or log line that
    /// mentions "login" earlier does not trigger an answer.
    public static func endsWithCredentialPrompt(_ text: String) -> Bool {
        let lastLine = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? text
        return lastLine.wholeMatch(of: #/(?i).*(password|passcode|login)[^:]*:\s*/#) != nil
    }

    /// dyld errors mean the bundled engine was built for a newer macOS.
    public static func isIncompatibleEngine(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("symbol not found") || lower.contains("dyld") || lower.contains("built for macos")
    }

    /// The first line that looks like an error, shortened for display.
    public static func firstError(in text: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if isFailureLine(line) {
                return line.count > 160 ? String(line.prefix(160)) + "…" : line
            }
        }
        return nil
    }

    public static func isFailureLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["sudo:", "failed", "error", "denied", "unexpected", "permission denied",
                "operation not permitted", "cannot", "symbol not found", "dyld"]
            .contains { lower.contains($0) }
    }
}
