@preconcurrency import NetworkExtension
import os

private let log = Logger(subsystem: "com.example.gatelink", category: "tunnel")

/// Runs a GlobalProtect tunnel with libopenconnect, using the cookie and
/// certificate pin the app got at login. iOS applies the gateway's routes and
/// DNS (vpnc-script's job on macOS).
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var tunnel: OpaquePointer?
    private var stopping = false
    private var finished: CheckedContinuation<Void, Never>?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let host = options?[TunnelShared.hostKey] as? String
        let cookie = options?[TunnelShared.cookieKey] as? String
        let fingerprint = options?[TunnelShared.fingerprintKey] as? String
        Task {
            do {
                try await start(host: host, cookie: cookie, fingerprint: fingerprint)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    private func start(host: String?, cookie: String?, fingerprint: String?) async throws {
        guard let host, let cookie, let fingerprint else {
            // Started from Settings or On Demand: only the app can log in.
            throw fail("Open GateLink and press Connect.")
        }
        guard let tunnel = gl_tunnel_new(host, cookie, fingerprint, tunnelLog, nil) else {
            throw fail("Could not set up OpenConnect.")
        }
        var error = [CChar](repeating: 0, count: 256)
        guard gl_tunnel_connect(tunnel, &error, error.count) == 0 else {
            gl_tunnel_free(tunnel)
            throw fail(TunnelShared.string(error))
        }
        guard let info = gl_tunnel_ip_info(tunnel)?.pointee, let settings = Self.networkSettings(info, server: host) else {
            gl_tunnel_free(tunnel)
            throw fail("The gateway did not assign an address.")
        }
        do {
            try await setTunnelNetworkSettings(settings)
        } catch {
            gl_tunnel_free(tunnel)
            throw fail("iOS refused the VPN settings: \(error.localizedDescription)")
        }
        let fd = gl_find_utun_fd()
        guard fd >= 0 else {
            gl_tunnel_free(tunnel)
            throw fail("Could not find the VPN interface.")
        }

        lock.withLock { self.tunnel = tunnel }
        let thread = Thread { [self] in run(fd: fd) }
        thread.name = "openconnect"
        thread.start()
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        let tunnel: OpaquePointer? = lock.withLock {
            stopping = true
            return self.tunnel
        }
        guard let tunnel else { return }
        await withCheckedContinuation { continuation in
            lock.withLock { finished = continuation }
            gl_tunnel_cancel(tunnel)
        }
    }

    /// openconnect's main loop; returns when cancelled or the tunnel is lost.
    private func run(fd: Int32) {
        guard let tunnel = lock.withLock({ self.tunnel }) else { return }
        var error = [CChar](repeating: 0, count: 256)
        let status = gl_tunnel_run(tunnel, fd, &error, error.count)
        let (wasStopping, continuation) = lock.withLock {
            self.tunnel = nil
            defer { finished = nil }
            return (stopping, finished)
        }
        gl_tunnel_free(tunnel)
        if let continuation {
            continuation.resume()
        } else if !wasStopping {
            let message = status == 0 ? "The VPN connection ended." : TunnelShared.string(error)
            cancelTunnelWithError(fail(message))
        }
    }

    /// Records the reason for the app, which only gets a generic error from iOS.
    private func fail(_ message: String) -> NSError {
        log.error("\(message, privacy: .public)")
        TunnelShared.defaults?.set(message, forKey: TunnelShared.lastErrorKey)
        return NSError(domain: "GateLinkTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Network settings

    /// Turns the gateway's address, split routes and DNS into iOS settings.
    /// No split-include routes means everything goes through the tunnel.
    static func networkSettings(_ info: oc_ip_info, server: String) -> NEPacketTunnelNetworkSettings? {
        let remote = info.gateway_addr.map { String(cString: $0) } ?? server
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remote)
        let includes = routes(info.split_includes)
        let excludes = routes(info.split_excludes)

        if let addr = info.addr.map({ String(cString: $0) }) {
            let mask = info.netmask.map { String(cString: $0) } ?? "255.255.255.255"
            let ipv4 = NEIPv4Settings(addresses: [addr], subnetMasks: [mask])
            let included = includes.compactMap(ipv4Route)
            ipv4.includedRoutes = included.isEmpty ? [.default()] : included
            ipv4.excludedRoutes = excludes.compactMap(ipv4Route)
            settings.ipv4Settings = ipv4
        }
        if let addr6 = info.netmask6.map({ String(cString: $0) }) ?? info.addr6.map({ String(cString: $0) }) {
            let parts = addr6.split(separator: "/")
            let prefix = parts.count == 2 ? Int(parts[1]) ?? 128 : 128
            let ipv6 = NEIPv6Settings(addresses: [String(parts[0])], networkPrefixLengths: [NSNumber(value: prefix)])
            let included = includes.compactMap(ipv6Route)
            ipv6.includedRoutes = included.isEmpty && includes.isEmpty ? [.default()] : included
            ipv6.excludedRoutes = excludes.compactMap(ipv6Route)
            settings.ipv6Settings = ipv6
        }
        guard settings.ipv4Settings != nil || settings.ipv6Settings != nil else { return nil }

        let servers = withUnsafeBytes(of: info.dns) { raw in
            raw.bindMemory(to: UnsafePointer<CChar>?.self).compactMap { $0.map { String(cString: $0) } }
        }
        if !servers.isEmpty {
            let dns = NEDNSSettings(servers: servers)
            let domains = info.domain.map { String(cString: $0) }?
                .split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init) ?? []
            let splitDNS = routes(info.split_dns)
            dns.searchDomains = domains
            // Split tunnel: the VPN's DNS answers only its own domains, as vpnc-script does.
            if !includes.isEmpty {
                let match = splitDNS.isEmpty ? domains : splitDNS
                dns.matchDomains = match.isEmpty ? [""] : match
            }
            settings.dnsSettings = dns
        }
        if info.mtu > 0 { settings.mtu = NSNumber(value: info.mtu) }
        return settings
    }

    private static func routes(_ list: UnsafeMutablePointer<oc_split_include>?) -> [String] {
        var result: [String] = []
        var node = list
        while let current = node {
            if let route = current.pointee.route { result.append(String(cString: route)) }
            node = current.pointee.next
        }
        return result
    }

    /// "10.0.0.0/8" or "10.0.0.0/255.0.0.0".
    private static func ipv4Route(_ route: String) -> NEIPv4Route? {
        guard !route.contains(":") else { return nil }
        let parts = route.split(separator: "/", maxSplits: 1).map(String.init)
        guard let address = parts.first else { return nil }
        guard parts.count == 2 else { return NEIPv4Route(destinationAddress: address, subnetMask: "255.255.255.255") }
        if parts[1].contains(".") { return NEIPv4Route(destinationAddress: address, subnetMask: parts[1]) }
        guard let bits = Int(parts[1]), (0...32).contains(bits) else { return nil }
        let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
        let dotted = [24, 16, 8, 0].map { String((mask >> UInt32($0)) & 0xFF) }.joined(separator: ".")
        return NEIPv4Route(destinationAddress: address, subnetMask: dotted)
    }

    private static func ipv6Route(_ route: String) -> NEIPv6Route? {
        guard route.contains(":") else { return nil }
        let parts = route.split(separator: "/", maxSplits: 1).map(String.init)
        let prefix = parts.count == 2 ? Int(parts[1]) ?? 128 : 128
        return NEIPv6Route(destinationAddress: parts[0], networkPrefixLength: NSNumber(value: prefix))
    }
}

/// openconnect progress lines go to the unified log (Console.app, "tunnel").
private let tunnelLog: gl_log_fn = { _, level, line in
    guard let line else { return }
    let text = String(cString: line)
    if level == PRG_ERR {
        log.error("\(text, privacy: .public)")
    } else {
        log.info("\(text, privacy: .public)")
    }
}
