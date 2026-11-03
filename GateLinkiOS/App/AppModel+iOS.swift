import Foundation
import GateLinkKit

extension AppModel {
    /// iOS keeps the VPN up while the app is closed, so pick it up again.
    func startPlatform() {
        Task { await attachRunningTunnel() }
    }

    func attachRunningTunnel() async {
        guard let account, let running = await tunnel.running() else { return }
        session.attach(
            gateway: running.gateway,
            since: running.since,
            events: running.events,
            credentials: credentials(for: account.id, gateway: running.gateway)
        )
    }
}
