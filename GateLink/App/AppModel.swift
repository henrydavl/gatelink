import AppKit
import GateLinkKit
import Observation
import ServiceManagement

/// App state shared by the menu bar popover and the windows.
@MainActor
@Observable
final class AppModel {
    let vault: Vault
    let session: VPNSession
    let resources: AppResources

    var gateway: String
    var username = ""
    /// A newly typed password. Empty means "use the saved one".
    var password = ""
    /// Feedback that is not part of the connection phase.
    var message: String?
    /// Generator for the visible code; dropped when the vault relocks.
    private(set) var revealed: TOTP?
    private(set) var openAtLogin = false
    private(set) var requirements: [Requirement] = []
    private(set) var selectedAccountID: UUID?

    @ObservationIgnored private let helper: TunnelHelper
    @ObservationIgnored private var relockTicker: Task<Void, Never>?

    private static let gatewayKey = "gateway"
    private static let selectedAccountKey = "selectedAccount"

    init() {
        resources = AppResources(bundle: .main)
        helper = TunnelHelper(installerURL: resources.installerURL)
        vault = Vault()
        let engine = resources.openConnectURL ?? URL(fileURLWithPath: "/opt/homebrew/bin/openconnect")
        session = VPNSession(
            authenticator: OpenConnectAuthenticator(executableURL: engine),
            tunnel: HelperTunnelController()
        )
        gateway = UserDefaults.standard.string(forKey: Self.gatewayKey) ?? ""
        selectedAccountID = UserDefaults.standard.string(forKey: Self.selectedAccountKey).flatMap(UUID.init)

        do {
            try vault.load()
        } catch {
            message = error.localizedDescription
        }
        if let account { username = account.username }
        if resources.openConnectURL == nil {
            message = "The OpenConnect engine is missing. Open Requirements from the … menu."
        }

        removeLegacyLaunchAgent()
        refreshOpenAtLogin()
        startRelockTicker()
        Task { await adoptRunningTunnel() }
    }

    // MARK: - Accounts

    var account: Account? {
        vault.accounts.first { $0.id == selectedAccountID } ?? vault.accounts.first
    }

    func select(_ account: Account) {
        selectedAccountID = account.id
        UserDefaults.standard.set(account.id.uuidString, forKey: Self.selectedAccountKey)
        username = account.username
        revealed = nil
    }

    /// Saves an account from the Add Account window. Returns false if the
    /// user cancelled the unlock prompt.
    func add(_ draft: AccountDraft) async throws -> Bool {
        guard try await vault.add(draft) else { return false }
        select(draft.account)
        message = "Added \(draft.account.issuer)."
        return true
    }

    func deleteCurrentAccount() async {
        guard let account else { return }
        do {
            guard try await vault.delete(account) else { return }
            revealed = nil
            if let next = vault.accounts.first { select(next) } else { username = "" }
            message = "Deleted \(account.issuer)."
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - Code

    func toggleReveal() async {
        if revealed != nil {
            revealed = nil
            return
        }
        guard let account else { return }
        do {
            guard let secret = try await vault.secret(for: account, reason: "Show the \(account.issuer) code") else { return }
            revealed = try secret.makeTOTP(for: account)
        } catch {
            message = error.localizedDescription
        }
    }

    func copyCode() async {
        guard let account else { return }
        do {
            guard let secret = try await vault.secret(for: account, reason: "Copy the \(account.issuer) code") else { return }
            let code = try secret.makeTOTP(for: account).code()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            message = "Code copied."
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - Connection

    /// Connect when idle, cancel while working, disconnect when connected.
    func primaryAction() async {
        switch session.phase {
        case .connected:
            await session.disconnect()
        case .authenticating, .connecting, .reconnecting:
            await session.cancel()
        case .disconnecting:
            break
        case .idle, .failed:
            await connect()
        }
    }

    private func connect() async {
        message = nil
        guard var account = matchingAccount() else {
            message = "Add a 2FA account first (+)."
            return
        }
        let portal = gateway.trimmingCharacters(in: .whitespacesAndNewlines)
        let login = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !portal.isEmpty else {
            message = "Enter the portal."
            return
        }
        guard TunnelArgs.isValidHost(portal) else {
            message = "The portal must be a hostname or IPv4 address (letters, digits, dots and hyphens)."
            return
        }
        guard !login.isEmpty else {
            message = "Enter your VPN username."
            return
        }
        gateway = portal
        UserDefaults.standard.set(portal, forKey: Self.gatewayKey)

        do {
            if !TunnelHelper.isInstalled {
                message = "GateLink needs a one-time administrator approval to install its tunnel helper."
            }
            try await helper.ensureReady()
            message = nil

            if account.username != login {
                account.username = login
                try vault.update(account)
            }
            if account.id != selectedAccountID { select(account) }

            if !password.isEmpty {
                guard await vault.unlock(reason: "Connect to \(portal)") else {
                    message = "Unlock cancelled. VPN not connected."
                    return
                }
                try vault.setPassword(password, for: account)
                password = ""
            } else if !account.hasPassword {
                message = "Enter your VPN password."
                return
            }
        } catch {
            message = error.localizedDescription
            return
        }

        await session.connect(gateway: portal, credentials: credentials(for: account.id, gateway: portal))
    }

    /// Typing another account's username switches to that account, so its
    /// OTP is used.
    private func matchingAccount() -> Account? {
        let typed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return vault.accounts.first {
            $0.username.caseInsensitiveCompare(typed) == .orderedSame
                || $0.label.caseInsensitiveCompare(typed) == .orderedSame
        } ?? account
    }

    private func credentials(for id: UUID, gateway: String) -> VPNSession.CredentialProvider {
        { [weak self] in
            guard let self, let account = vault.accounts.first(where: { $0.id == id }) else {
                throw GateLinkError("The account was deleted.")
            }
            guard let secret = try await vault.secret(for: account, reason: "Connect to \(gateway)") else {
                return nil
            }
            guard let password = secret.vpnPassword, !password.isEmpty else {
                throw GateLinkError("No VPN password is saved for \(account.username). Enter it and press Connect.")
            }
            return VPNCredentials(username: account.username, password: password, totp: try secret.makeTOTP(for: account))
        }
    }

    private func adoptRunningTunnel() async {
        guard let account else { return }
        let portal = gateway.isEmpty ? nil : gateway
        await session.adoptRunningTunnel(
            gateway: portal,
            credentials: credentials(for: account.id, gateway: portal ?? "the VPN")
        )
    }

    // MARK: - System

    func refreshRequirements() async {
        requirements = await Requirements.check(resources)
    }

    func uninstallHelper() async {
        do {
            try await helper.uninstall()
            message = "The tunnel helper was removed."
        } catch {
            message = error.localizedDescription
        }
        await refreshRequirements()
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            message = "Could not change Open at Login: \(error.localizedDescription)"
        }
        refreshOpenAtLogin()
    }

    private func refreshOpenAtLogin() {
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// The .NET app used a LaunchAgent; Open at Login now uses SMAppService.
    private func removeLegacyLaunchAgent() {
        let agent = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/com.gatelink.app.plist")
        try? FileManager.default.removeItem(at: agent)
    }

    private func startRelockTicker() {
        relockTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if revealed != nil, !vault.isUnlocked { revealed = nil }
            }
        }
    }

    func quit() {
        // The tunnel keeps running; the next launch adopts it.
        NSApp.terminate(nil)
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
