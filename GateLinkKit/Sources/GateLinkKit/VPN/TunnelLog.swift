import Foundation

/// Appends tunnel output to `~/Library/Logs/GateLink/tunnel.log` (mode 0600),
/// rotating to `tunnel.log.1` past ``maxBytes``. The tunnel output never
/// contains the session cookie, which travels on stdin.
public final class TunnelLog: @unchecked Sendable {
    public let fileURL: URL
    public var maxBytes: UInt64 = 512 * 1024

    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    public init(fileURL: URL = TunnelLog.defaultURL) {
        self.fileURL = fileURL
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/GateLink", directoryHint: .isDirectory)
            .appending(path: "tunnel.log")
    }

    public func append(_ line: String) {
        lock.withLock {
            let entry = Data("[\(formatter.string(from: Date()))] \(line)\n".utf8)
            let manager = FileManager.default
            let path = fileURL.path
            do {
                if let size = try? manager.attributesOfItem(atPath: path)[.size] as? UInt64, size > maxBytes {
                    let rotated = path + ".1"
                    try? manager.removeItem(atPath: rotated)
                    try manager.moveItem(atPath: path, toPath: rotated)
                }
                if !manager.fileExists(atPath: path) {
                    try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    manager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: entry)
            } catch {
                // Diagnostics only; never interfere with the tunnel.
            }
        }
    }
}
