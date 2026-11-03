import Foundation

/// Persists the non-secret account list as JSON (mode 0600).
public struct AccountStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = AccountStore.defaultURL) {
        self.fileURL = fileURL
    }

    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "GateLink", directoryHint: .isDirectory).appending(path: "accounts.json")
    }

    public func load() throws -> [Account] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            return try JSONDecoder().decode([Account].self, from: Data(contentsOf: fileURL))
        } catch {
            throw GateLinkError("The saved account list is unreadable: \(error.localizedDescription)")
        }
    }

    public func save(_ accounts: [Account]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(accounts).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
