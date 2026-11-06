import Foundation
import Observation

/// Which screen GlobalProtect's window shows.
public enum GlobalProtectScreen: Equatable, Sendable {
    case closed, portal, login, connected, other

    /// One control or label in GlobalProtect's window.
    public struct Element: Equatable, Sendable {
        public var role = ""
        public var subrole = ""
        public var title = ""
        public var text = ""

        public init(role: String = "", subrole: String = "", title: String = "", text: String = "") {
            self.role = role
            self.subrole = subrole
            self.title = title
            self.text = text
        }
    }

    /// Recognises the screen from GlobalProtect 6.0's English labels.
    public init(elements: [Element]) {
        if elements.isEmpty {
            self = .closed
        } else if elements.contains(where: { $0.subrole == "AXSecureTextField" }) {
            self = .login
        } else if elements.contains(where: { $0.title == "GlobalProtect Connected" || $0.text == "Connected" }) {
            self = .connected
        } else if elements.contains(where: { $0.title == "GlobalProtect Disconnected" })
                    && elements.contains(where: { $0.role == "AXButton" && $0.title == "Connect" }) {
            self = .portal
        } else {
            self = .other
        }
    }
}

public enum GlobalProtectLog {
    /// Whether the last meaningful line of pan_gp_event.log says the tunnel is
    /// up. Nil when no line says. A tunnel that is down while GlobalProtect
    /// restores it ("network change", "keep-alive timeout") does not count as
    /// disconnected; "User was logged out" or "could not be logged out" follows
    /// if restoring fails.
    public static func isConnected(_ log: String) -> Bool? {
        for line in log.split(separator: "\n").reversed() {
            if line.contains("tunnel creation finished") || line.contains("Tunnel is restored") {
                return true
            }
            if ["logged out of Gateway", "session has ended", "due to disconnection", "due to idle timeout",
                "GlobalProtect service"].contains(where: line.contains) {
                return false
            }
        }
        return nil
    }
}

/// The controls GateLink uses in the official GlobalProtect app.
@MainActor
public protocol GlobalProtectUI: AnyObject {
    /// Throws unless GateLink has Accessibility permission and the real, signed GlobalProtect is running.
    func verifyAccess() throws
    func screen() -> GlobalProtectScreen
    /// Presses the menu bar icon, which opens or closes the window.
    func toggleWindow() throws
    /// Presses Connect on whichever screen is showing.
    func pressConnect() throws
    func fillLogin(username: String, password: String) throws
    func clearPassword()
    func connectedFromLog() -> Bool?
}

/// Logs in through the official GlobalProtect app, which makes the connection.
/// One login attempt per Connect: repeated bad logins can lock the account.
@MainActor
@Observable
public final class GlobalProtectSession {
    /// Returns nil when the user cancels the unlock prompt.
    public typealias CredentialProvider = @MainActor () async throws -> VPNCredentials?

    public private(set) var phase: VPNPhase = .idle

    @ObservationIgnored private let ui: GlobalProtectUI
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var lastOTPCounter: UInt64?
    @ObservationIgnored public var onDisconnect: (@MainActor () -> Void)?

    private static let pollInterval: TimeInterval = 0.25
    /// A code with less life left could expire while GlobalProtect checks it.
    private static let minimumCodeLife = 8
    private static let screenTimeout: TimeInterval = 20
    private static let acceptTimeout: TimeInterval = 20
    private static let connectTimeout: TimeInterval = 90

    public init(
        ui: GlobalProtectUI,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.ui = ui
        self.now = now
        self.sleep = sleep
    }

    /// Follows GlobalProtect's log, so a login by hand or a dropped session shows up too.
    public func startMonitoring() {
        refresh()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.refresh()
            }
        }
    }

    public func refresh() {
        guard !phase.isBusy else { return }
        switch ui.connectedFromLog() {
        case true?:
            if !phase.isConnected { phase = .connected }
        case false?:
            if phase.isConnected {
                phase = .idle
                onDisconnect?()
            }
        case nil:
            break
        }
    }

    /// Returns once connected or failed.
    public func connect(credentials: @escaping CredentialProvider) async {
        guard !phase.isBusy, !phase.isConnected else { return }
        phase = .authenticating
        let task = Task { await login(credentials) }
        work = task
        await task.value
        work = nil
    }

    /// Stops the attempt. A login already sent to GlobalProtect may still finish there.
    public func cancel() async {
        work?.cancel()
        await work?.value
    }

    public func showGlobalProtect() {
        do {
            if ui.screen() == .closed { try ui.toggleWindow() }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func login(_ credentials: CredentialProvider) async {
        var filled = false
        do {
            try ui.verifyAccess()
            guard let login = try await credentials() else {
                phase = .idle
                return
            }
            try await waitForUsableCode(login.totp)
            guard try await openLoginScreen() else {
                phase = .connected
                return
            }
            let date = now()
            lastOTPCounter = login.totp.counter(at: date)
            filled = true
            try ui.fillLogin(username: login.username, password: login.password + login.totp.code(at: date))
            try Task.checkCancellation()
            phase = .connecting
            try ui.pressConnect()
            try await waitForResult()
            phase = .connected
        } catch is CancellationError {
            if filled { ui.clearPassword() }
            phase = .idle
        } catch {
            if filled { ui.clearPassword() }
            phase = .failed(error.localizedDescription)
        }
    }

    /// The gateway rejects a code that was already used, so a quick reconnect waits for the next one.
    private func waitForUsableCode(_ totp: TOTP) async throws {
        let date = now()
        if totp.secondsRemaining(at: date) < Self.minimumCodeLife || totp.counter(at: date) == lastOTPCounter {
            try await sleep(totp.nextRollover(after: date).timeIntervalSince(date))
        }
    }

    /// Clicks through to the login screen. False when GlobalProtect is already connected.
    private func openLoginScreen() async throws -> Bool {
        let deadline = now().addingTimeInterval(Self.screenTimeout)
        var pressedPortalConnect = false
        var reopenAt = Date.distantPast
        while now() < deadline {
            switch ui.screen() {
            case .login:
                return true
            case .connected:
                return false
            case .portal where !pressedPortalConnect:
                try ui.pressConnect()
                pressedPortalConnect = true
            case .closed where now() >= reopenAt:
                try ui.toggleWindow()
                reopenAt = now().addingTimeInterval(2)
            default:
                break
            }
            try await sleep(Self.pollInterval)
        }
        throw GateLinkError("GlobalProtect didn't show its login screen. Check its window, or log in there by hand.")
    }

    private func waitForResult() async throws {
        let start = now()
        var leftLoginScreen = false
        let rejected = GateLinkError(
            "GlobalProtect didn't accept the login. GateLink won't retry, so your account doesn't get locked. "
                + "Check your saved password and 2FA account, then press Connect."
        )
        while now().timeIntervalSince(start) < Self.connectTimeout {
            let screen = ui.screen()
            if screen == .connected || ui.connectedFromLog() == true { return }
            switch screen {
            case .login:
                if leftLoginScreen || now().timeIntervalSince(start) >= Self.acceptTimeout { throw rejected }
            case .portal:
                if leftLoginScreen { throw rejected }
            default:
                leftLoginScreen = true
            }
            try await sleep(Self.pollInterval)
        }
        throw GateLinkError("GlobalProtect didn't connect in time. Check its window.")
    }
}
