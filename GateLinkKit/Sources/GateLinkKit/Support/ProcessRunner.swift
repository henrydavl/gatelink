import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    /// stdout and stderr, interleaved.
    public var output: String
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
