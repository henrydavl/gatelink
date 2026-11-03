import CryptoKit
import Foundation

/// A newer GateLink release and the installer package for this Mac's CPU.
public struct AppUpdate: Sendable, Equatable {
    public var version: String
    public var notes: String
    public var pageURL: URL
    public var packageURL: URL
    /// Lowercase hex SHA-256 that GitHub reports for the package.
    public var sha256: String
    public var size: Int
}

/// Checks GitHub for a newer release, downloads its `.pkg`, verifies it and
/// installs it with one administrator prompt.
///
/// shortcut: trusts what GitHub serves for the release (same as a manual
/// download); add a pinned signature or a notarized Developer ID package
/// before shipping beyond a small team.
public struct Updater: Sendable {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/henrydavl/gatelink/releases/latest")!
    public static let bundleID = "com.gatelink.app"
    public static let installedAppPath = "/Applications/GateLink.app"

    public var currentVersion: String
    public var session: URLSession

    public init(currentVersion: String, session: URLSession = .shared) {
        self.currentVersion = currentVersion
        self.session = session
    }

    public static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }

    /// The latest release if it is newer than ``currentVersion``.
    public func check() async throws -> AppUpdate? {
        var request = URLRequest(url: Self.latestReleaseURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GateLinkError("Could not check for updates (GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        return try Self.update(fromRelease: data, currentVersion: currentVersion, architecture: Self.architecture)
    }

    static func update(fromRelease data: Data, currentVersion: String, architecture: String) throws -> AppUpdate? {
        struct Release: Decodable {
            struct Asset: Decodable {
                var name: String
                var size: Int
                var digest: String?
                var browser_download_url: URL
            }
            var tag_name: String
            var html_url: URL
            var body: String?
            var assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard isNewer(version, than: currentVersion) else { return nil }

        let name = "GateLink-\(architecture).pkg"
        guard let asset = release.assets.first(where: { $0.name == name }) else {
            throw GateLinkError("GateLink \(version) has no \(name) yet. Try again later.")
        }
        guard let digest = asset.digest, digest.hasPrefix("sha256:") else {
            throw GateLinkError("GitHub did not report a checksum for \(name); refusing to install it.")
        }
        return AppUpdate(
            version: version,
            notes: release.body ?? "",
            pageURL: release.html_url,
            packageURL: asset.browser_download_url,
            sha256: String(digest.dropFirst("sha256:".count)).lowercased(),
            size: asset.size
        )
    }

    /// Compares dotted numeric versions; "2.0.10" is newer than "2.0.9".
    static func isNewer(_ version: String, than current: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let new = parts(version), old = parts(current)
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// Downloads the package and checks its size and SHA-256 against the
    /// release. Returns the local file.
    public func download(_ update: AppUpdate, progress: @Sendable (Double) -> Void) async throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "GateLink-\(update.version)-\(UUID().uuidString).pkg")
        let (bytes, response) = try await session.bytes(from: update.packageURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GateLinkError("The download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        var hasher = SHA256()
        var buffer = Data()
        var received = 0
        do {
            defer { try? handle.close() }
            for try await byte in bytes {
                buffer.append(byte)
                guard buffer.count == 1 << 16 else { continue }
                received += buffer.count
                guard received <= update.size else { throw GateLinkError("The download is larger than the release says.") }
                hasher.update(data: buffer)
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                progress(Double(received) / Double(max(update.size, 1)))
            }
            received += buffer.count
            hasher.update(data: buffer)
            try handle.write(contentsOf: buffer)
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard received == update.size, digest == update.sha256 else {
                throw GateLinkError("The downloaded update does not match the release checksum; it was not installed.")
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        progress(1)
        return file
    }

    /// Checks the package holds GateLink at the expected version, so a
    /// mislabeled asset is never installed as root.
    public func verifyPackage(_ package: URL, version: String) async throws {
        let expanded = FileManager.default.temporaryDirectory.appending(path: "GateLink-expanded-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: expanded) }
        let result = try await ProcessRunner.run("/usr/sbin/pkgutil", ["--expand-full", package.path, expanded.path], timeout: 120)
        let plist = expanded.appending(path: "Payload/Applications/GateLink.app/Contents/Info.plist")
        guard result.status == 0,
              let info = NSDictionary(contentsOf: plist),
              info["CFBundleIdentifier"] as? String == Self.bundleID,
              info["CFBundleShortVersionString"] as? String == version
        else {
            throw GateLinkError("The downloaded package is not GateLink \(version); it was not installed.")
        }
    }

    /// Runs Installer as root. Throws if the prompt is cancelled or Installer fails.
    public func install(_ package: URL, version: String) async throws {
        let result = try await ProcessRunner.runAsAdministrator(
            ["/usr/sbin/installer", "-pkg", package.path, "-target", "/"],
            prompt: "GateLink wants to install version \(version).",
            timeout: 600
        )
        try? FileManager.default.removeItem(at: package)
        guard result.status == 0 else {
            if result.cancelledPrompt { throw GateLinkError("Update cancelled.") }
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GateLinkError("Installing the update failed: \(detail)")
        }
    }

    /// Opens the installed app once this process has exited.
    public static func relaunchAfterExit() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", installedAppPath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
