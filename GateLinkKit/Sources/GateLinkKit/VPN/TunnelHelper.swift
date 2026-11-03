#if os(macOS) // the sudo helper is macOS-only
import Foundation

/// Installs and probes the root-owned tunnel helper.
///
/// `scripts/install-tunnel-helper.sh` copies the wrapper, the OpenConnect
/// engine, `vpnc-script` and `hipreport.sh` to ``directory`` as root:wheel,
/// writes the approved portals to ``allowedGatewaysPath`` and a sudoers rule
/// that authorizes only the wrapper. The wrapper connects only to approved portals.
public struct TunnelHelper: Sendable {
    public static let directory = "/usr/local/libexec/gatelink"
    public static let helperPath = directory + "/gatelink-tunnel"
    public static let versionPath = directory + "/VERSION"
    public static let allowedGatewaysPath = directory + "/allowed-gateways"
    public static let sudoersPath = "/etc/sudoers.d/gatelink"
    public static let expectedVersion = "6"

    /// `install-tunnel-helper.sh` inside the app bundle.
    public var installerURL: URL?

    public init(installerURL: URL?) {
        self.installerURL = installerURL
    }

    /// The helper files and sudoers rule exist and the version matches.
    public static var isInstalled: Bool {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: helperPath),
              manager.fileExists(atPath: sudoersPath),
              let version = try? String(contentsOfFile: versionPath, encoding: .utf8)
        else { return false }
        return version.trimmingCharacters(in: .whitespacesAndNewlines) == expectedVersion
    }

    /// An administrator approved `gateway` for the tunnel.
    public static func isApproved(_ gateway: String) -> Bool {
        guard let list = try? String(contentsOfFile: allowedGatewaysPath, encoding: .utf8) else { return false }
        return list.split(whereSeparator: \.isNewline).contains { $0 == gateway.lowercased() }
    }

    /// Runs the exact command sudoers authorizes. `version` touches nothing,
    /// so this only proves the rule and the helper work.
    public static func isAuthorized() async -> Bool {
        guard let result = try? await ProcessRunner.run("/usr/bin/sudo", ["-n", helperPath, "version"], timeout: 10) else {
            return false
        }
        return result.status == 0
            && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == expectedVersion
    }

    /// Installs or repairs the helper, or approves a new portal, when needed.
    /// Shows the macOS administrator prompt only then.
    public func ensureReady(gateway: String, user: String = NSUserName()) async throws {
        if Self.isInstalled, Self.isApproved(gateway), await Self.isAuthorized() { return }
        try await runInstaller(arguments: ["--user", user, "--gateway", gateway])
        guard Self.isInstalled, Self.isApproved(gateway), await Self.isAuthorized() else {
            throw GateLinkError("The tunnel helper was installed but sudo still refuses it. Check /etc/sudoers.d/gatelink.")
        }
    }

    public func uninstall() async throws {
        try await runInstaller(arguments: ["--uninstall"])
    }

    private func runInstaller(arguments: [String]) async throws {
        guard let installerURL, FileManager.default.fileExists(atPath: installerURL.path) else {
            throw GateLinkError("install-tunnel-helper.sh is missing from the app. Reinstall GateLink.")
        }
        let result = try await ProcessRunner.runAsAdministrator(["/bin/bash", installerURL.path] + arguments)
        guard result.status == 0 else {
            if result.cancelledPrompt {
                throw GateLinkError("The administrator prompt was cancelled. GateLink needs the helper once to create the VPN tunnel.")
            }
            let detail = OpenConnectOutput.firstError(in: result.output)
                ?? result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GateLinkError("Installing the tunnel helper failed: \(detail)")
        }
    }
}
#endif
