import Foundation
import Security

/// Persists account secrets. Implementations must keep them encrypted at rest.
public protocol SecretStore: Sendable {
    func secret(for id: UUID) throws -> AccountSecret?
    func setSecret(_ secret: AccountSecret, for id: UUID) throws
    func deleteSecret(for id: UUID) throws
}

/// Stores each account's secret as a generic password in the login Keychain.
///
/// The item's access list trusts only the app that created it, so other apps
/// (including `/usr/bin/security`) trigger a Keychain prompt to read it. The
/// app additionally asks for Touch ID or the login password before it reads a
/// secret; see ``Vault``.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "com.gatelink.app.account") {
        self.service = service
    }

    public func secret(for id: UUID) throws -> AccountSecret? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw keychainError(status, action: "read")
        }
        do {
            return try JSONDecoder().decode(AccountSecret.self, from: data)
        } catch {
            throw GateLinkError("The saved account secret is unreadable. Delete the account and add it again.")
        }
    }

    public func setSecret(_ secret: AccountSecret, for id: UUID) throws {
        let data = try JSONEncoder().encode(secret)
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(baseQuery(for: id) as CFDictionary, update)
        if status == errSecItemNotFound {
            var add = baseQuery(for: id)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "GateLink VPN account"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keychainError(status, action: "save") }
    }

    public func deleteSecret(for id: UUID) throws {
        let status = SecItemDelete(baseQuery(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status, action: "delete")
        }
    }

    private func baseQuery(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    private func keychainError(_ status: OSStatus, action: String) -> GateLinkError {
        if status == errSecUserCanceled || status == errSecAuthFailed {
            return GateLinkError("Keychain access was denied.")
        }
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return GateLinkError("Could not \(action) the account in the Keychain: \(detail)")
    }
}

/// In-memory store for tests and previews.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [UUID: AccountSecret] = [:]

    public init() {}

    public func secret(for id: UUID) throws -> AccountSecret? {
        lock.withLock { secrets[id] }
    }

    public func setSecret(_ secret: AccountSecret, for id: UUID) throws {
        lock.withLock { secrets[id] = secret }
    }

    public func deleteSecret(for id: UUID) throws {
        lock.withLock { _ = secrets.removeValue(forKey: id) }
    }
}
