import Foundation
import Testing
@testable import GateLinkKit

@MainActor
@Suite struct VaultTests {
    let clock = TestClock()
    let verifier = CountingVerifier()
    let secrets = MemorySecretStore()
    let store = AccountStore(
        fileURL: FileManager.default.temporaryDirectory.appending(path: "gatelink-\(UUID().uuidString)/accounts.json")
    )

    func makeVault() -> Vault {
        let clock = clock
        return Vault(store: store, secrets: secrets, verifier: verifier, now: { clock.now })
    }

    func draft() throws -> AccountDraft {
        try AccountDraft.fromManualInput("JBSWY3DPEHPK3PXP", issuer: "Corp", username: "jane")
    }

    @Test func oneUnlockCoversTheSlidingWindow() async throws {
        let vault = makeVault()
        let draft = try draft()
        #expect(try await vault.add(draft))
        #expect(verifier.prompts == 1)

        clock.advance(by: 50)
        #expect(try await vault.secret(for: draft.account, reason: "test") == draft.secret)
        clock.advance(by: 50)   // still inside the window: each read refreshes it
        _ = try await vault.secret(for: draft.account, reason: "test")
        #expect(verifier.prompts == 1)

        clock.advance(by: 61)
        #expect(!vault.isUnlocked)
        _ = try await vault.secret(for: draft.account, reason: "test")
        #expect(verifier.prompts == 2)
    }

    @Test func cancelledUnlockReturnsNilAndSavesNothing() async throws {
        let vault = makeVault()
        verifier.answer = false
        #expect(try await vault.add(try draft()) == false)
        #expect(vault.accounts.isEmpty)
        #expect(try store.load().isEmpty)
    }

    @Test func persistsMetadataWithoutSecrets() async throws {
        let vault = makeVault()
        let draft = try draft()
        try await vault.add(draft)

        let reloaded = makeVault()
        try reloaded.load()
        #expect(reloaded.accounts == [draft.account])
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!json.contains("JBSWY3DPEHPK3PXP"))
        let mode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func passwordUpdatesRequireAnUnlockedVault() async throws {
        let vault = makeVault()
        let draft = try draft()
        try await vault.add(draft)
        #expect(vault.accounts.first?.hasPassword == false)
        try vault.setPassword("hunter2", for: draft.account)
        #expect(try secrets.secret(for: draft.account.id)?.vpnPassword == "hunter2")
        #expect(vault.accounts.first?.hasPassword == true)

        vault.lock()
        #expect(throws: GateLinkError.self) { try vault.setPassword("other", for: draft.account) }
    }

    @Test func findsTheAccountForATypedUsername() async throws {
        let vault = makeVault()
        let jane = try draft()
        let bob = try AccountDraft.fromManualInput("KRUGS4ZANFZSAYJA", issuer: "Corp", username: "90184463")
        try await vault.add(jane)
        try await vault.add(bob)

        #expect(vault.account(forUsername: " 90184463 ")?.id == bob.account.id)
        #expect(vault.account(forUsername: "JANE")?.id == jane.account.id)
        #expect(vault.account(forUsername: "nobody") == nil)
        #expect(vault.account(forUsername: "") == nil)
    }

    @Test func keepsTheSelectedAccountWhenUsernamesAreShared() async throws {
        let vault = makeVault()
        let first = try AccountDraft.fromManualInput("JBSWY3DPEHPK3PXP", issuer: "Corp", username: "jane")
        let second = try AccountDraft.fromManualInput("KRUGS4ZANFZSAYJA", issuer: "Lab", username: "jane")
        try await vault.add(first)
        try await vault.add(second)

        #expect(vault.account(forUsername: "jane", preferring: second.account.id)?.id == second.account.id)
        #expect(vault.account(forUsername: "jane")?.id == first.account.id)
        #expect(vault.account(forUsername: "jane", preferring: UUID())?.id == first.account.id)
    }

    @Test func deleteRemovesSecretAndMetadata() async throws {
        let vault = makeVault()
        let draft = try draft()
        try await vault.add(draft)
        #expect(try await vault.delete(draft.account))
        #expect(vault.accounts.isEmpty)
        #expect(try secrets.secret(for: draft.account.id) == nil)
    }
}
