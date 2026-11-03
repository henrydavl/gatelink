#if os(macOS) // the sudo helper is macOS-only
import Foundation

/// Where the app's bundled tools live.
public struct AppResources: Sendable {
    public var openConnectURL: URL?
    public var installerURL: URL?
    public var hipReportURL: URL?

    public init(openConnectURL: URL?, installerURL: URL?, hipReportURL: URL?) {
        self.openConnectURL = openConnectURL
        self.installerURL = installerURL
        self.hipReportURL = hipReportURL
    }

    /// Looks in `Contents/Helpers/openconnect` and `Contents/Resources`, then
    /// falls back to a Homebrew openconnect for development builds.
    public init(bundle: Bundle) {
        let helpers = bundle.bundleURL.appending(path: "Contents/Helpers/openconnect/openconnect")
        let candidates = [helpers.path, "/opt/homebrew/bin/openconnect", "/usr/local/bin/openconnect"]
        let engine = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        self.init(
            openConnectURL: engine.map { URL(fileURLWithPath: $0) },
            installerURL: bundle.url(forResource: "install-tunnel-helper", withExtension: "sh"),
            hipReportURL: bundle.url(forResource: "hipreport", withExtension: "sh")
        )
    }
}

public struct Requirement: Identifiable, Sendable {
    public var name: String
    public var isMet: Bool
    public var detail: String
    public var fix: String?

    public var id: String { name }
}

public enum Requirements {
    public static func check(_ resources: AppResources) async -> [Requirement] {
        var items: [Requirement] = []

        let engine = resources.openConnectURL
        items.append(Requirement(
            name: "OpenConnect engine",
            isMet: engine != nil,
            detail: engine?.path ?? "not found",
            fix: engine == nil ? "Reinstall GateLink, or for a development build run scripts/bundle-openconnect.sh." : nil
        ))

        let installed = TunnelHelper.isInstalled
        let approvedPortals = (try? String(contentsOfFile: TunnelHelper.allowedGatewaysPath, encoding: .utf8))
            .map { $0.split(whereSeparator: \.isNewline).joined(separator: ", ") }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "none"
        let authorized = installed ? await TunnelHelper.isAuthorized() : false
        items.append(Requirement(
            name: "Root tunnel helper",
            isMet: authorized,
            detail: authorized ? "installed (v\(TunnelHelper.expectedVersion)), approved portals: \(approvedPortals)"
                : installed ? "installed but not authorized" : "not installed",
            fix: authorized ? nil : "Press Connect and approve the administrator prompt, or run scripts/install-tunnel-helper.sh."
        ))

        let hip = resources.hipReportURL
        items.append(Requirement(
            name: "HIP report script",
            isMet: hip != nil,
            detail: hip == nil ? "missing" : "bundled",
            fix: hip == nil ? "Reinstall GateLink. Gateways that enforce HIP checks may limit the tunnel without it." : nil
        ))

        return items
    }
}
#endif
