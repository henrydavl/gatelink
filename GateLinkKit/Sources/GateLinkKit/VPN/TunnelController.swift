import Foundation

public enum TunnelEvent: Equatable, Sendable {
    case output(String)
    /// openconnect reported that the tunnel carries traffic.
    case established
    /// The tunnel process ended. Always the last event.
    case exited(Int32)
    /// The tunnel failed with a readable reason. Always the last event.
    case failed(String)
    /// Someone stopped the tunnel outside GateLink, e.g. in iOS Settings.
    /// Always the last event; no reconnect follows.
    case stopped
}

/// Starts and stops the privileged tunnel.
public protocol TunnelController: Sendable {
    func start(host: String, fingerprint: String, cookie: String) async throws -> AsyncStream<TunnelEvent>
    func stop() async
}

#if os(macOS) // runs the tunnel through sudo; iOS uses a Packet Tunnel
/// Runs the tunnel through the root-owned `gatelink-tunnel` wrapper via
/// `sudo -n`. The wrapper builds the openconnect command line itself; the app
/// only passes a validated host and certificate pin, and the cookie on stdin.
/// stdin stays open as a lifeline: when this process exits, however it exits,
/// the wrapper sees EOF and stops the tunnel.
public actor HelperTunnelController: TunnelController {
    private let helperPath: String
    private let log: TunnelLog
    private var process: Process?
    private var input: Pipe?

    public init(helperPath: String = TunnelHelper.helperPath, log: TunnelLog = TunnelLog()) {
        self.helperPath = helperPath
        self.log = log
    }

    public func start(host: String, fingerprint: String, cookie: String) async throws -> AsyncStream<TunnelEvent> {
        if let process, process.isRunning {
            throw GateLinkError("A tunnel is already running.")
        }
        guard TunnelArgs.isValidHost(host), TunnelArgs.isValidFingerprint(fingerprint) else {
            throw GateLinkError("Refusing to start the tunnel with an invalid host or certificate pin.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", helperPath, "connect", "--host", host, "--fingerprint", fingerprint]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        let (stream, continuation) = AsyncStream<TunnelEvent>.makeStream()
        let reader = TunnelOutputReader(continuation: continuation, log: log)
        log.append("--- starting tunnel to \(host)")

        // Output and termination arrive on different threads; emit `.exited`
        // only after the last output line has been delivered.
        let finished = DispatchGroup()
        finished.enter()
        finished.enter()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                reader.flush()
                finished.leave()
            } else {
                reader.feed(data)
            }
        }
        process.terminationHandler = { _ in finished.leave() }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            throw GateLinkError("Could not start the tunnel helper: \(error.localizedDescription)")
        }

        let box = UncheckedBox(process)
        finished.notify(queue: .global()) {
            let status = box.value.terminationStatus
            reader.log.append("--- tunnel exited with code \(status)")
            continuation.yield(.exited(status))
            continuation.finish()
        }

        // The cookie goes to openconnect on stdin. Keep stdin open for the
        // life of the tunnel, as openconnect expects.
        try input.fileHandleForWriting.write(contentsOf: Data((cookie + "\n").utf8))
        self.process = process
        self.input = input
        return stream
    }

    public func stop() async {
        // The tunnel runs as root, so only the wrapper can signal it. It
        // checks that the PID belongs to its own openconnect first.
        _ = try? await ProcessRunner.run("/usr/bin/sudo", ["-n", helperPath, "stop"], timeout: 15)
        if let process, process.isRunning { process.terminate() }
        try? input?.fileHandleForWriting.close()
        process = nil
        input = nil
    }
}

/// Splits tunnel output into lines and reports the established marker once.
/// `readabilityHandler` calls for one handle are serialized, but the lock
/// keeps this safe if that ever changes.
private final class TunnelOutputReader: @unchecked Sendable {
    let log: TunnelLog
    private let continuation: AsyncStream<TunnelEvent>.Continuation
    private let lock = NSLock()
    private var pending = Data()
    private var established = false

    init(continuation: AsyncStream<TunnelEvent>.Continuation, log: TunnelLog) {
        self.continuation = continuation
        self.log = log
    }

    func feed(_ data: Data) {
        lock.withLock {
            pending.append(data)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                emit(line)
            }
        }
    }

    func flush() {
        lock.withLock {
            if !pending.isEmpty {
                emit(String(decoding: pending, as: UTF8.self))
                pending.removeAll()
            }
        }
    }

    private func emit(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        log.append(line)
        continuation.yield(.output(line))
        if !established, OpenConnectOutput.isEstablished(line) {
            established = true
            continuation.yield(.established)
        }
    }
}
#endif
