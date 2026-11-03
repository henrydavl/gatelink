import Foundation
import Observation

/// Owns the saved accounts and gates access to their secrets.
///
/// One successful verification unlocks the vault for a sliding window
/// (``relockAfter``); reveal, copy and connect within the window do not prompt
/// again. Every secret read refreshes the window.
@MainActor
@Observable
public final class Vault {
    public private(set) var accounts: [Account] = []
    public var relockAfter: TimeInterval = 60

    private let store: AccountStore
    private let secrets: SecretStore
    private let verifier: UserPresenceVerifier
    private let now: @Sendable () -> Date
    private var unlockedUntil: Date = .distantPast

    public init(
        store: AccountStore = AccountStore(),
        secrets: SecretStore = KeychainSecretStore(),
        verifier: UserPresenceVerifier = LocalAuthenticationVerifier(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.secrets = secrets
        self.verifier = verifier
        self.now = now
    }

    public var isUnlocked: Bool { now() < unlockedUntil }

    public func load() throws {
        accounts = try store.load()
    }

    /// Prompts only when locked. Returns false if the user cancels.
    public func unlock(reason: String) async -> Bool {
        if isUnlocked {
            unlockedUntil = now().addingTimeInterval(relockAfter)
            return true
        }
        guard await verifier.verify(reason: reason) else { return false }
        unlockedUntil = now().addingTimeInterval(relockAfter)
        return true
    }

    public func lock() {
        unlockedUntil = .distantPast
    }

    /// Unlocks if needed and reads the account's secret. Returns nil if the
    /// user cancels the prompt.
    public func secret(for account: Account, reason: String) async throws -> AccountSecret? {
        guard await unlock(reason: reason) else { return nil }
        guard let secret = try secrets.secret(for: account.id) else {
            throw GateLinkError("The secret for \(account.issuer) is missing from the Keychain. Delete the account and add it again.")
        }
        return secret
    }

    /// Adds a new account, or replaces the one with the same id.
    @discardableResult
    public func add(_ draft: AccountDraft) async throws -> Bool {
        guard await unlock(reason: "Save the \(draft.account.issuer) account") else { return false }
        try secrets.setSecret(draft.secret, for: draft.account.id)
        var account = draft.account
        account.hasPassword = !(draft.secret.vpnPassword ?? "").isEmpty
        var updated = accounts.filter { $0.id != draft.account.id }
        updated.append(account)
        try persist(updated)
        return true
    }

    /// Saves non-secret changes such as the username.
    public func update(_ account: Account) throws {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        var updated = accounts
        updated[index] = account
        try persist(updated)
    }

    /// Stores a new VPN password for the account. The vault must be unlocked.
    public func setPassword(_ password: String, for account: Account) throws {
        guard isUnlocked else { throw GateLinkError("Unlock the vault first.") }
        guard var secret = try secrets.secret(for: account.id) else {
            throw GateLinkError("The secret for \(account.issuer) is missing from the Keychain.")
        }
        secret.vpnPassword = password
        try secrets.setSecret(secret, for: account.id)
        var updated = accounts.first { $0.id == account.id } ?? account
        updated.hasPassword = !password.isEmpty
        try update(updated)
    }

    @discardableResult
    public func delete(_ account: Account) async throws -> Bool {
        guard await unlock(reason: "Delete the \(account.issuer) account") else { return false }
        try secrets.deleteSecret(for: account.id)
        try persist(accounts.filter { $0.id != account.id })
        return true
    }

    private func persist(_ updated: [Account]) throws {
        try store.save(updated)
        accounts = updated
    }
}
