import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    /// stdout and stderr, interleaved.
    public var output: String

    /// The user cancelled the macOS administrator prompt (AppleScript error -128).
    public var cancelledPrompt: Bool { status != 0 && output.contains("-128") }
}

/// Runs short-lived commands (helper probes, `osascript`) and collects output.
public enum ProcessRunner {
    public static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 30
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw GateLinkError("Could not start \(executable): \(error.localizedDescription)")
        }

        let box = UncheckedBox(process)
        let finished = AtomicFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if !finished.isSet, box.value.isRunning { box.value.terminate() }
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                box.value.waitUntilExit()
                finished.set()
                continuation.resume(returning: ProcessResult(
                    status: box.value.terminationStatus,
                    output: String(decoding: data, as: UTF8.self)
                ))
            }
        }
    }

    /// Runs `command` as root behind the macOS administrator prompt.
    public static func runAsAdministrator(
        _ command: [String],
        prompt: String? = nil,
        timeout: TimeInterval = 300
    ) async throws -> ProcessResult {
        let shell = command.map(shellQuoted).joined(separator: " ")
        var script = "do shell script \"\(appleScriptEscaped(shell))\""
        if let prompt { script += " with prompt \"\(appleScriptEscaped(prompt))\"" }
        script += " with administrator privileges"
        return try await run("/usr/bin/osascript", ["-e", script], timeout: timeout)
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Carries a non-Sendable reference into a closure whose callers already
/// serialize access to it.
final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A thread-safe boolean flag.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool { lock.withLock { flag } }

    func set() { lock.withLock { flag = true } }
}
