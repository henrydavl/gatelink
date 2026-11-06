import AppKit
import GateLinkKit
import Observation

/// App state for the menu bar app. Updater and system settings live in AppModel+macOS.swift.
@MainActor
@Observable
final class AppModel {
    let vault: Vault
    let session: GlobalProtectSession

    /// Typing another account's username switches to that account, so its OTP is used.
    var username = "" {
        didSet {
            if let match = vault.account(forUsername: username, preferring: selectedAccountID), match.id != selectedAccountID {
                setSelection(match.id)
            }
        }
    }
    /// Feedback that is not part of the connection phase.
    var message: String?
    /// Generator for the visible code; dropped when the vault relocks.
    private(set) var revealed: TOTP?
    private(set) var selectedAccountID: UUID?

    var openAtLogin = false
    var availableUpdate: AppUpdate?
    var updateStep: UpdateStep?

    enum UpdateStep: Equatable {
        case downloading(Double)
        case verifying
        case installing
    }

    @ObservationIgnored var updateTicker: Task<Void, Never>?
    @ObservationIgnored let notifier = DisconnectNotifier()
    @ObservationIgnored private var relockTicker: Task<Void, Never>?

    private static let selectedAccountKey = "selectedAccount"

    init() {
        vault = Vault()
        session = GlobalProtectSession(ui: AccessibleGlobalProtect())
        selectedAccountID = UserDefaults.standard.string(forKey: Self.selectedAccountKey).flatMap(UUID.init)

        do {
            try vault.load()
        } catch {
            message = error.localizedDescription
        }
        if let account { username = account.username }
        startRelockTicker()
        startPlatform()
    }

    // MARK: - Accounts

    var account: Account? {
        vault.accounts.first { $0.id == selectedAccountID } ?? vault.accounts.first
    }

    /// Switching is locked while a connection uses the selected account.
    var canSwitchAccount: Bool {
        !session.phase.isBusy && !session.phase.isConnected
    }

    func select(_ account: Account) {
        setSelection(account.id)
        username = account.username
    }

    private func setSelection(_ id: UUID) {
        selectedAccountID = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.selectedAccountKey)
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

    /// Saves the VPN password for the selected account. Returns false if the
    /// user cancelled the unlock prompt.
    func savePassword(_ password: String) async -> Bool {
        guard let account else { return false }
        guard await vault.unlock(reason: "Save the VPN password for \(account.username)") else { return false }
        do {
            try vault.setPassword(password, for: account)
            message = "Password saved."
            return true
        } catch {
            message = error.localizedDescription
            return false
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

    /// Connect when idle, cancel while working. When connected, open
    /// GlobalProtect, which owns the connection.
    func primaryAction() async {
        switch session.phase {
        case .connected:
            session.showGlobalProtect()
        case .authenticating, .connecting:
            await session.cancel()
        case .idle, .failed:
            await connect()
        }
    }

    func connect() async {
        message = nil
        guard var account else {
            message = "Add a 2FA account first (+)."
            return
        }
        let login = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else {
            message = "Enter your VPN username."
            return
        }
        guard account.hasPassword else {
            message = "Set your VPN password first."
            return
        }

        do {
            if account.username != login {
                account.username = login
                try vault.update(account)
            }
        } catch {
            message = error.localizedDescription
            return
        }

        // Touch ID on every login, even right after showing the code.
        vault.lock()
        await session.connect(credentials: credentials(for: account.id))
    }

    private func credentials(for id: UUID) -> GlobalProtectSession.CredentialProvider {
        { [weak self] in
            guard let self, let account = vault.accounts.first(where: { $0.id == id }) else {
                throw GateLinkError("The account was deleted.")
            }
            guard let secret = try await vault.secret(for: account, reason: "Log in to GlobalProtect") else {
                return nil
            }
            guard let password = secret.vpnPassword, !password.isEmpty else {
                throw GateLinkError("No VPN password is saved for \(account.username). Set it and press Connect.")
            }
            return VPNCredentials(username: account.username, password: password, totp: try secret.makeTOTP(for: account))
        }
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

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
