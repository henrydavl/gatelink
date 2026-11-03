import Foundation
import GateLinkKit
@preconcurrency import NetworkExtension

/// Runs the tunnel in GateLink's Packet Tunnel extension. iOS keeps the VPN
/// up after the app closes, so a relaunch adopts it with ``running()``.
@MainActor
final class PacketTunnelController: TunnelController {
    nonisolated static let extensionBundleID = (Bundle.main.bundleIdentifier ?? "com.example.gatelink") + ".tunnel"

    private var manager: NETunnelProviderManager?

    func start(host: String, fingerprint: String, cookie: String) async throws -> AsyncStream<TunnelEvent> {
        let manager = try await loadManager()
        let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = Self.extensionBundleID
        configuration.serverAddress = host
        configuration.disconnectOnSleep = false
        manager.protocolConfiguration = configuration
        manager.localizedDescription = "GateLink"
        manager.isEnabled = true
        do {
            // The first save shows iOS's "Add VPN Configurations" prompt.
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        } catch {
            throw GateLinkError("iOS did not allow GateLink's VPN configuration: \(error.localizedDescription)")
        }

        TunnelShared.defaults?.removeObject(forKey: TunnelShared.lastErrorKey)
        let stream = events(for: manager.connection)
        do {
            try manager.connection.startVPNTunnel(options: [
                TunnelShared.hostKey: host as NSString,
                TunnelShared.cookieKey: cookie as NSString,
                TunnelShared.fingerprintKey: fingerprint as NSString,
            ])
        } catch {
            throw GateLinkError("Could not start the VPN: \(error.localizedDescription)")
        }
        return stream
    }

    func stop() async {
        guard let connection = try? await loadManager().connection else { return }
        connection.stopVPNTunnel()
        for _ in 0..<50 where connection.status != .disconnected && connection.status != .invalid {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The GateLink VPN that is already up, if any.
    func running() async -> (gateway: String, since: Date, events: AsyncStream<TunnelEvent>)? {
        guard let manager = try? await loadManager(),
              [.connected, .reasserting].contains(manager.connection.status),
              let gateway = manager.protocolConfiguration?.serverAddress
        else { return nil }
        return (gateway, manager.connection.connectedDate ?? Date(), events(for: manager.connection))
    }

    private func loadManager() async throws -> NETunnelProviderManager {
        if let manager { return manager }
        let loaded = try await NETunnelProviderManager.loadAllFromPreferences().first ?? NETunnelProviderManager()
        manager = loaded
        return loaded
    }

    /// Status changes as tunnel events: connected once, then how it ended.
    private func events(for connection: NEVPNConnection) -> AsyncStream<TunnelEvent> {
        let (stream, continuation) = AsyncStream<TunnelEvent>.makeStream()
        let watcher = Task {
            var established = connection.status == .connected
            for await _ in NotificationCenter.default.notifications(named: .NEVPNStatusDidChange, object: connection) {
                switch connection.status {
                case .connected where !established:
                    established = true
                    continuation.yield(.established)
                case .disconnected, .invalid:
                    if let reason = TunnelShared.defaults?.string(forKey: TunnelShared.lastErrorKey) {
                        continuation.yield(.failed(reason))
                    } else {
                        continuation.yield(.stopped)
                    }
                    continuation.finish()
                    return
                default:
                    break
                }
            }
        }
        continuation.onTermination = { _ in watcher.cancel() }
        return stream
    }
}
