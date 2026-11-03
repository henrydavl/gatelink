import Darwin
import Foundation

/// Logs in to a GlobalProtect gateway and returns the session cookie.
public protocol VPNAuthenticator: Sendable {
    /// `credential` is the password with the 6-digit OTP appended.
    func authenticate(gateway: String, username: String, credential: String) async throws -> GPCookie
}

/// Runs `openconnect --protocol=gp --authenticate` inside a pseudo-terminal.
///
/// openconnect reads the password from a terminal; a plain pipe fails with
/// "Inappropriate ioctl for device". The gateway takes a single credential
/// prompt answered with the password immediately followed by the OTP, and
/// `--usergroup=gateway` forces gateway login (the portal endpoint loops with
/// HTTP 512).
///
/// `--cafile` points at the macOS root bundle: the bundled OpenSSL engine has
/// no CA store of its own. shortcut: roots trusted only in the Keychain (a
/// private corporate CA) are not seen; pass a CA file if a gateway needs one.
public struct OpenConnectAuthenticator: VPNAuthenticator {
    public var executableURL: URL
    public var timeout: TimeInterval

    public init(executableURL: URL, timeout: TimeInterval = 90) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    public func authenticate(gateway: String, username: String, credential: String) async throws -> GPCookie {
        let arguments = [
            "--protocol=gp", "--usergroup=gateway", "--cafile=/etc/ssl/cert.pem",
            "-u", username, "--authenticate", gateway,
        ]
        let transcript = try await PTYLogin.run(
            executableURL: executableURL,
            arguments: arguments,
            credential: credential,
            timeout: timeout
        )

        if let cookie = try? GPCookie.parse(transcript) {
            return cookie
        }
        if OpenConnectOutput.isIncompatibleEngine(transcript) {
            let detail = OpenConnectOutput.firstError(in: transcript).map { ": \($0)" } ?? "."
            throw GateLinkError("The bundled OpenConnect is incompatible with this macOS\(detail)")
        }
        if let detail = OpenConnectOutput.firstError(in: transcript) {
            throw GateLinkError("Login failed: \(detail)")
        }
        throw GateLinkError("Login failed. Check the username, password and OTP.")
    }
}

/// Drives one interactive login in a PTY.
enum PTYLogin {
    static func run(
        executableURL: URL,
        arguments: [String],
        credential: String,
        timeout: TimeInterval
    ) async throws -> String {
        let session = try PTYSession(executableURL: executableURL, arguments: arguments)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try session.interact(credential: credential, timeout: timeout)
                    })
                }
            }
        } onCancel: {
            session.cancel()
        }
    }
}

/// One child process attached to a PTY. `interact` runs on a single
/// background thread; `cancel` only sets a flag and signals the child.
final class PTYSession: @unchecked Sendable {
    private let process = Process()
    private let master: Int32
    private let cancelled = AtomicFlag()

    init(executableURL: URL, arguments: [String]) throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw GateLinkError("Could not open a terminal for the login (errno \(errno)).")
        }

        // Turn echo off before the child starts so the credential can never be
        // echoed back into the transcript.
        var attributes = termios()
        if tcgetattr(slave, &attributes) == 0 {
            attributes.c_lflag &= ~tcflag_t(ECHO | ECHONL)
            tcsetattr(slave, TCSANOW, &attributes)
        }

        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        process.environment = environment

        do {
            try process.run()
        } catch {
            close(master)
            close(slave)
            throw GateLinkError("Could not start OpenConnect: \(error.localizedDescription)")
        }
        // Only the child keeps the slave open, so reads on the master end once
        // the child exits.
        close(slave)
        self.master = master
    }

    func cancel() {
        cancelled.set()
        if process.isRunning { process.terminate() }
    }

    /// Answers the first credential prompt and returns the full transcript
    /// with the credential redacted.
    func interact(credential: String, timeout: TimeInterval) throws -> String {
        defer { close(master) }
        let deadline = Date().addingTimeInterval(timeout)
        var transcript = Data()
        var answeredAt: Int?
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            if cancelled.isSet {
                stop()
                throw CancellationError()
            }
            if Date() >= deadline {
                stop()
                throw GateLinkError("Login timed out after \(Int(timeout)) seconds. Check the gateway and try again.")
            }

            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }

            let count = read(master, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                break   // EIO: the child closed the terminal
            }
            if count == 0 { break }
            transcript.append(contentsOf: chunk[0..<count])

            let pending = String(decoding: transcript[(answeredAt ?? 0)...], as: UTF8.self)
            guard OpenConnectOutput.endsWithCredentialPrompt(pending) else { continue }
            if answeredAt != nil {
                stop()
                throw GateLinkError("Login failed: the gateway asked for the password again. Check the password and OTP.")
            }
            try write(credential + "\n")
            // Echo is off, so record the Enter ourselves; otherwise the next
            // line (e.g. COOKIE=...) would run on from the prompt.
            transcript.append(UInt8(ascii: "\n"))
            answeredAt = transcript.count
        }

        process.waitUntilExit()
        if cancelled.isSet { throw CancellationError() }
        return String(decoding: transcript, as: UTF8.self)
            .replacingOccurrences(of: credential, with: "••••••")
    }

    private func write(_ text: String) throws {
        var bytes = Array(text.utf8)
        defer { for index in bytes.indices { bytes[index] = 0 } }
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                throw GateLinkError("Could not send the credential to OpenConnect (errno \(errno)).")
            }
            offset += written
        }
    }

    private func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
