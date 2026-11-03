import Foundation
import Testing
@testable import GateLinkKit

@MainActor
@Suite struct VPNSessionTests {
    let clock = TestClock()
    let auth = FakeAuthenticator()
    let tunnel = FakeTunnel()
    let totp: TOTP

    init() throws {
        totp = try TOTP(base32Secret: "JBSWY3DPEHPK3PXP")
    }

    func makeSession(reconnect: ReconnectPolicy = ReconnectPolicy()) -> VPNSession {
        let clock = clock
        let session = VPNSession(
            authenticator: auth,
            tunnel: tunnel,
            now: { clock.now },
            sleep: { try await clock.sleep($0) }
        )
        session.reconnectPolicy = reconnect
        return session
    }

    func credentials() -> VPNSession.CredentialProvider {
        let totp = totp
        return { VPNCredentials(username: "jane", password: "hunter2", totp: totp) }
    }

    /// Starts a connect and lets the fake tunnel report it is up.
    func connect(_ session: VPNSession) async {
        let task = Task { await session.connect(gateway: "vpn.example.com", credentials: credentials()) }
        await tunnel.waitForStart()
        await tunnel.emit(.established)
        await task.value
    }

    @Test func connectsWithPasswordPlusCurrentOTP() async {
        let session = makeSession()
        let expectedOTP = totp.code(at: clock.now)
        await connect(session)

        #expect(session.phase.isConnected)
        #expect(await auth.calls == [.init(gateway: "vpn.example.com", username: "jane", credential: "hunter2" + expectedOTP)])
        #expect(await tunnel.starts == [.init(host: "vpn.example.com", fingerprint: "pin-sha256:AbC=", cookie: "authcookie=abc")])
    }

    @Test func tunnelsToThePortalWhenTheGatewayReportsAnIPv6Host() async {
        let session = makeSession()
        await auth.setResult(.success(GPCookie(cookie: "c", host: "64:ff9b::673f:60be", fingerprint: "pin-sha256:AbC=")))
        await connect(session)
        #expect(session.phase.isConnected)
        #expect(await tunnel.starts.map(\.host) == ["vpn.example.com"])
    }

    @Test func ignoresASecondConnectWhileTheFirstIsRunning() async {
        let session = makeSession()
        await auth.hold()
        let first = Task { await session.connect(gateway: "vpn.example.com", credentials: credentials()) }
        // The phase changes before the login task runs; wait for the held call itself.
        #expect(await eventually { await auth.calls.count == 1 })
        #expect(session.phase == .authenticating)

        await session.connect(gateway: "vpn.example.com", credentials: credentials())
        #expect(await auth.calls.count == 1)

        await auth.release()
        await tunnel.waitForStart()
        await tunnel.emit(.established)
        await first.value
        #expect(session.phase.isConnected)
        #expect(await tunnel.starts.count == 1)
        #expect(await tunnel.stops == 0)
    }

    @Test func reportsLoginFailure() async {
        let session = makeSession()
        await auth.setResult(.failure(GateLinkError("Login failed: bad password")))
        await session.connect(gateway: "vpn.example.com", credentials: credentials())
        #expect(session.phase == .failed("Login failed: bad password"))
        #expect(await tunnel.starts.isEmpty)
    }

    @Test func reportsCancelledUnlock() async {
        let session = makeSession()
        await session.connect(gateway: "vpn.example.com") { nil }
        #expect(session.phase == .failed("Unlock cancelled. VPN not connected."))
        #expect(await auth.calls.isEmpty)
    }

    @Test func rejectsInvalidPortalAndFingerprint() async {
        let session = makeSession()
        await session.connect(gateway: "-oProxy=x", credentials: credentials())
        #expect(session.phase == .failed("Enter a valid portal: a hostname or IPv4 address."))

        await auth.setResult(.success(GPCookie(cookie: "c", host: "203.0.113.10", fingerprint: "--script=/tmp/x")))
        await session.connect(gateway: "vpn.example.com", credentials: credentials())
        #expect(session.phase == .failed("The gateway did not return a valid certificate fingerprint; refusing to connect."))
        #expect(await tunnel.starts.isEmpty)
    }

    @Test func explainsAMissingSudoRule() async {
        let session = makeSession()
        let task = Task { await session.connect(gateway: "vpn.example.com", credentials: credentials()) }
        await tunnel.waitForStart()
        await tunnel.emit(.output("sudo: a password is required"))
        await tunnel.emit(.exited(1))
        await task.value
        #expect(session.phase == .failed(
            "The root tunnel helper is missing or not authorized (sudo: a password is required). Press Connect to reinstall it."
        ))
    }

    @Test func timesOutWhenTheTunnelNeverComesUp() async {
        let session = makeSession()
        let task = Task { await session.connect(gateway: "vpn.example.com", credentials: credentials()) }
        await tunnel.waitForStart()
        #expect(await eventually { clock.pendingSleeps == 1 })
        clock.advance(by: 29)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(session.phase == .connecting)
        clock.advance(by: 1)
        await task.value
        #expect(session.phase == .failed("The tunnel did not come up within 30 seconds."))
        #expect(await tunnel.stops == 1)
    }

    @Test func cancelStopsALoginInProgress() async {
        let session = makeSession()
        await auth.hold()
        let task = Task { await session.connect(gateway: "vpn.example.com", credentials: credentials()) }
        // The phase changes before the login task runs; wait for the held call itself.
        #expect(await eventually { await auth.calls.count == 1 })
        #expect(session.phase == .authenticating)

        await session.cancel()
        await auth.release()
        await task.value
        #expect(session.phase == .idle)
        #expect(await tunnel.starts.isEmpty)
    }

    @Test func disconnectStopsTheTunnel() async {
        let session = makeSession()
        await connect(session)
        await session.disconnect()
        #expect(session.phase == .idle)
        #expect(await tunnel.stops == 1)

        // A late exit from the stopped tunnel must not trigger a reconnect.
        await tunnel.emit(.exited(0))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.phase == .idle)
        #expect(await auth.calls.count == 1)
    }

    @Test func reconnectsWithAFreshCodeAfterADrop() async {
        let session = makeSession()
        await connect(session)
        let firstCredential = await auth.calls[0].credential

        await tunnel.emit(.exited(2))
        #expect(await eventually { session.phase == .reconnecting(attempt: 1) })
        #expect(await drive(clock) { await tunnel.starts.count == 2 })
        await tunnel.emit(.established)
        #expect(await eventually { session.phase.isConnected })

        let calls = await auth.calls
        #expect(calls.count == 2)
        // The retry waited for the next 30-second step instead of replaying.
        #expect(calls[1].credential != firstCredential)
        #expect(calls[1].credential == "hunter2" + totp.code(at: clock.now))
    }

    @Test func givesUpAfterTheConfiguredAttempts() async {
        let session = makeSession(reconnect: ReconnectPolicy(delays: [1, 1]))
        await connect(session)
        await auth.setResult(.failure(GateLinkError("Login failed: gateway down")))

        await tunnel.emit(.exited(2))
        #expect(await drive(clock) {
            session.phase == .failed("The VPN connection was lost and could not be restored: Login failed: gateway down")
        })
        #expect(await auth.calls.count == 3)
    }

    @Test func staysFailedWithoutReconnect() async {
        let session = makeSession(reconnect: ReconnectPolicy(isEnabled: false))
        await connect(session)
        await tunnel.emit(.exited(2))
        #expect(await eventually { session.phase == .failed("The VPN connection was lost.") })
        #expect(await auth.calls.count == 1)
    }

    @Test func stopsALeftoverTunnelOnlyWhenIdle() async {
        let session = makeSession()
        await session.stopLeftoverTunnel()
        #expect(await tunnel.stops == 1)

        await connect(session)
        await session.stopLeftoverTunnel()
        #expect(session.phase.isConnected)
        #expect(await tunnel.stops == 1)
    }

    @Test func connectIsAllowedAgainAfterAFailure() async {
        let session = makeSession()
        await auth.setResult(.failure(GateLinkError("Login failed: x")))
        await session.connect(gateway: "vpn.example.com", credentials: credentials())
        await auth.setResult(.success(GPCookie(cookie: "c", host: "203.0.113.10", fingerprint: "sha256:ab")))
        // The failed login used this step's code; the retry needs the next one.
        clock.advance(by: 30)
        await connect(session)
        #expect(session.phase.isConnected)
    }

    @Test func waitsForTheNextCodeInsteadOfReplayingOne() async {
        let session = makeSession()
        await auth.setResult(.failure(GateLinkError("Login failed: x")))
        await session.connect(gateway: "vpn.example.com", credentials: credentials())
        await auth.setResult(.success(GPCookie(cookie: "c", host: "203.0.113.10", fingerprint: "sha256:ab")))

        let task = Task { await session.connect(gateway: "vpn.example.com", credentials: credentials()) }
        #expect(await eventually { clock.pendingSleeps == 1 })
        #expect(await auth.calls.count == 1)
        clock.advanceToNextDeadline()
        await tunnel.waitForStart()
        await tunnel.emit(.established)
        await task.value

        let calls = await auth.calls
        #expect(calls[0].credential != calls[1].credential)
    }
}
