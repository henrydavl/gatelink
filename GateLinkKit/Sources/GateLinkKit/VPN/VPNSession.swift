import Foundation
import Observation

public enum VPNPhase: Equatable, Sendable {
    case idle
    case authenticating
    case connecting
    case connected(since: Date)
    case reconnecting(attempt: Int)
    case disconnecting
    case failed(String)

    /// A connect, reconnect or disconnect is in progress.
    public var isBusy: Bool {
        switch self {
        case .authenticating, .connecting, .reconnecting, .disconnecting: true
        case .idle, .connected, .failed: false
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// What one login needs. The OTP is generated from `totp` at the last moment.
public struct VPNCredentials: Sendable {
    public var username: String
    public var password: String
    public var totp: TOTP

    public init(username: String, password: String, totp: TOTP) {
        self.username = username
        self.password = password
        self.totp = totp
    }
}

public struct ReconnectPolicy: Sendable {
    public var isEnabled = true
    /// Wait before each attempt; the attempt count is the array length.
    public var delays: [TimeInterval] = [2, 5, 10]

    public init(isEnabled: Bool = true, delays: [TimeInterval] = [2, 5, 10]) {
        self.isEnabled = isEnabled
        self.delays = delays
    }
}

/// Connection lifecycle: authenticate, start the tunnel, watch it, and
/// re-authenticate with a fresh OTP if it drops.
///
/// Every state change happens on the main actor. Work started for an earlier
/// attempt is tagged with a generation number and ignored once a newer
/// attempt, a cancel or a disconnect has begun.
@MainActor
@Observable
public final class VPNSession {
    /// Returns nil when the user cancels the unlock prompt.
    public typealias CredentialProvider = @MainActor () async throws -> VPNCredentials?

    public private(set) var phase: VPNPhase = .idle
    public private(set) var gateway: String?
    public var reconnectPolicy = ReconnectPolicy()

    @ObservationIgnored private let authenticator: VPNAuthenticator
    @ObservationIgnored private let tunnel: TunnelController
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private let establishTimeout: TimeInterval

    @ObservationIgnored private var credentials: CredentialProvider?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var establishTimer: Task<Void, Never>?
    @ObservationIgnored private var lastOTPCounter: UInt64?
    @ObservationIgnored private var failureDetail: String?
    @ObservationIgnored private var settleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        authenticator: VPNAuthenticator,
        tunnel: TunnelController,
        establishTimeout: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.authenticator = authenticator
        self.tunnel = tunnel
        self.establishTimeout = establishTimeout
        self.now = now
        self.sleep = sleep
    }

    // MARK: - Public API

    /// Connects and returns once connected or failed. Ignored while a connect
    /// is already in progress or the tunnel is up.
    public func connect(gateway: String, credentials: @escaping CredentialProvider) async {
        guard !phase.isBusy, !phase.isConnected else { return }
        guard TunnelArgs.isValidHost(gateway) else {
            transition(to: .failed("Enter a valid portal: a hostname or IPv4 address."))
            return
        }
        self.gateway = gateway
        self.credentials = credentials
        begin(attempt: 0, after: 0)
        await waitUntilSettled()
    }

    /// Stops a connect or reconnect in progress.
    public func cancel() async {
        guard phase.isBusy, phase != .disconnecting else { return }
        await tearDown(to: .idle)
    }

    public func disconnect() async {
        guard phase != .disconnecting, phase != .idle else { return }
        await tearDown(to: .idle)
    }

    /// Takes over a tunnel that is already up, such as an iOS VPN that kept
    /// running while the app was closed. A later drop reconnects as usual.
    public func attach(gateway: String, since: Date, events: AsyncStream<TunnelEvent>, credentials: @escaping CredentialProvider) {
        guard phase == .idle || phase.isFailed else { return }
        generation += 1
        let current = generation
        cancelTasks()
        self.gateway = gateway
        self.credentials = credentials
        transition(to: .connected(since: since))
        watcher = Task {
            for await event in events {
                guard current == generation else { return }
                await handle(event, attempt: 0, generation: current)
            }
        }
    }

    /// The VPN lives only as long as the app. Stops a tunnel that an older
    /// version left running after it quit.
    public func stopLeftoverTunnel() async {
        guard phase == .idle else { return }
        await tunnel.stop()
    }

    // MARK: - Attempts

    private func begin(attempt: Int, after delay: TimeInterval) {
        generation += 1
        let current = generation
        cancelTasks()
        transition(to: attempt == 0 ? .authenticating : .reconnecting(attempt: attempt))
        work = Task {
            if delay > 0 {
                do { try await sleep(delay) } catch { return }
            }
            await run(attempt: attempt, generation: current)
        }
    }

    private func run(attempt: Int, generation current: Int) async {
        failureDetail = nil
        do {
            guard let gateway, let credentials else { return }
            guard let login = try await credentials() else {
                throw GateLinkError(attempt == 0 ? "Unlock cancelled. VPN not connected." : "Unlock cancelled. Reconnect stopped.")
            }
            try ensureCurrent(current)
            let otp = try await freshCode(login.totp)
            try ensureCurrent(current)

            let cookie = try await authenticator.authenticate(
                gateway: gateway,
                username: login.username,
                credential: login.password + otp
            )
            try ensureCurrent(current)
            guard let fingerprint = cookie.fingerprint, TunnelArgs.isValidFingerprint(fingerprint) else {
                throw GateLinkError("The gateway did not return a valid certificate fingerprint; refusing to connect.")
            }

            if attempt == 0 { transition(to: .connecting) }
            // Tunnel to the validated portal name, not openconnect's HOST: that is the resolved
            // IP, which is IPv6 on NAT64 networks, and the root wrapper takes only names and IPv4.
            // shortcut: assumes the portal name reaches the gateway that issued the cookie;
            // pass RESOLVE through the wrapper if a round-robin gateway rejects it.
            let events = try await tunnel.start(host: gateway, fingerprint: fingerprint, cookie: cookie.cookie)
            guard current == generation else {
                await tunnel.stop()
                return
            }
            watch(events, attempt: attempt, generation: current)
        } catch is CancellationError {
            // A cancel, disconnect or newer attempt took over.
        } catch {
            guard current == generation else { return }
            await attemptFailed(error.localizedDescription, attempt: attempt, generation: current, stopTunnel: false)
        }
    }

    private func watch(_ events: AsyncStream<TunnelEvent>, attempt: Int, generation current: Int) {
        let timeout = establishTimeout
        watcher = Task {
            for await event in events {
                guard current == generation else { return }
                await handle(event, attempt: attempt, generation: current)
            }
        }
        establishTimer = Task {
            do { try await sleep(timeout) } catch { return }
            guard current == generation, !phase.isConnected else { return }
            let detail = failureDetail.map { " Last message: \($0)" } ?? ""
            await attemptFailed(
                "The tunnel did not come up within \(Int(timeout)) seconds.\(detail)",
                attempt: attempt, generation: current, stopTunnel: true
            )
        }
    }

    private func handle(_ event: TunnelEvent, attempt: Int, generation current: Int) async {
        switch event {
        case .output(let line):
            if !phase.isConnected, failureDetail == nil, OpenConnectOutput.isFailureLine(line) {
                failureDetail = line
            }
        case .established:
            guard !phase.isConnected else { return }
            establishTimer?.cancel()
            establishTimer = nil
            transition(to: .connected(since: now()))
        case .exited(let code):
            if phase.isConnected {
                tunnelDropped()
            } else {
                await attemptFailed(establishFailure(code), attempt: attempt, generation: current, stopTunnel: false)
            }
        case .failed(let reason):
            failureDetail = reason
            await handle(.exited(1), attempt: attempt, generation: current)
        case .stopped:
            generation += 1
            cancelTasks()
            transition(to: .idle)
        }
    }

    private func tunnelDropped() {
        guard reconnectPolicy.isEnabled, credentials != nil, let first = reconnectPolicy.delays.first else {
            generation += 1
            transition(to: .failed("The VPN connection was lost."))
            return
        }
        begin(attempt: 1, after: first)
    }

    private func attemptFailed(_ message: String, attempt: Int, generation current: Int, stopTunnel: Bool) async {
        guard current == generation else { return }
        generation += 1
        if stopTunnel { await tunnel.stop() }

        let delays = reconnectPolicy.delays
        if attempt > 0, attempt < delays.count, reconnectPolicy.isEnabled, !message.hasPrefix("Unlock cancelled") {
            begin(attempt: attempt + 1, after: delays[attempt])
            return
        }
        transition(to: .failed(attempt > 0 ? "The VPN connection was lost and could not be restored: \(message)" : message))
    }

    private func establishFailure(_ code: Int32) -> String {
        if let detail = failureDetail {
            if detail.lowercased().hasPrefix("sudo:") {
                return "The root tunnel helper is missing or not authorized (\(detail)). Press Connect to reinstall it."
            }
            return "The tunnel did not come up: \(detail)"
        }
        return "The tunnel did not come up (openconnect exited with code \(code)). Check the portal."
    }

    // MARK: - Helpers

    /// Never reuses a code: gateways usually reject a replayed OTP, so a
    /// reconnect within the same 30 seconds waits for the next one.
    private func freshCode(_ totp: TOTP) async throws -> String {
        var date = now()
        if let last = lastOTPCounter, totp.counter(at: date) <= last {
            try await sleep(totp.nextRollover(after: date).timeIntervalSince(date) + 0.5)
            date = now()
        }
        lastOTPCounter = totp.counter(at: date)
        return totp.code(at: date)
    }

    private func tearDown(to final: VPNPhase) async {
        generation += 1
        cancelTasks()
        transition(to: .disconnecting)
        await tunnel.stop()
        transition(to: final)
    }

    private func cancelTasks() {
        work?.cancel()
        watcher?.cancel()
        establishTimer?.cancel()
        work = nil
        watcher = nil
        establishTimer = nil
    }

    private func ensureCurrent(_ current: Int) throws {
        if current != generation || Task.isCancelled { throw CancellationError() }
    }

    private func transition(to next: VPNPhase) {
        phase = next
        if !next.isBusy {
            let waiters = settleWaiters
            settleWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private func waitUntilSettled() async {
        guard phase.isBusy else { return }
        await withCheckedContinuation { settleWaiters.append($0) }
    }
}
