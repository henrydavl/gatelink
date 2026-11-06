import Foundation
import Testing
@testable import GateLinkKit

@MainActor
final class FakeGlobalProtect: GlobalProtectUI {
    var current: GlobalProtectScreen = .portal
    /// Screens shown after the login Connect press, one per poll; the last one stays.
    var afterLogin: [GlobalProtectScreen] = [.other, .connected]
    var accessError: GateLinkError?
    var logSays: Bool?
    private var submitted = false
    private(set) var toggles = 0
    private(set) var portalPresses = 0
    private(set) var loginPresses = 0
    private(set) var fills: [(username: String, password: String)] = []
    private(set) var passwordClears = 0

    func verifyAccess() throws {
        if let accessError { throw accessError }
    }

    func screen() -> GlobalProtectScreen {
        if submitted, !afterLogin.isEmpty {
            current = afterLogin.removeFirst()
        }
        return current
    }

    /// Back on the portal screen, as after a disconnect.
    func startOver() {
        submitted = false
        current = .portal
        afterLogin = [.other, .connected]
    }

    func toggleWindow() throws {
        toggles += 1
        current = .portal
    }

    func pressConnect() throws {
        if current == .portal {
            portalPresses += 1
            current = .login
        } else {
            loginPresses += 1
            submitted = true
        }
    }

    func fillLogin(username: String, password: String) throws {
        fills.append((username, password))
    }

    func clearPassword() { passwordClears += 1 }
    func connectedFromLog() -> Bool? { logSays }
}

@MainActor
@Suite struct GlobalProtectSessionTests {
    let clock = TestClock()
    let ui = FakeGlobalProtect()
    let totp: TOTP

    init() throws {
        totp = try TOTP(base32Secret: "JBSWY3DPEHPK3PXP")
    }

    func makeSession() -> GlobalProtectSession {
        let clock = clock
        return GlobalProtectSession(ui: ui, now: { clock.now }, sleep: { try await clock.sleep($0) })
    }

    func credentials() -> GlobalProtectSession.CredentialProvider {
        let totp = totp
        return { VPNCredentials(username: "jane", password: "hunter2", totp: totp) }
    }

    func connect(_ session: GlobalProtectSession) async {
        let task = Task { await session.connect(credentials: credentials()) }
        #expect(await drive(clock) { !session.phase.isBusy && session.phase != .idle })
        await task.value
    }

    @Test func clicksThroughBothScreensAndSendsPasswordPlusCode() async {
        let session = makeSession()
        let code = totp.code(at: clock.now)
        await connect(session)

        #expect(session.phase.isConnected)
        #expect(ui.portalPresses == 1)
        #expect(ui.loginPresses == 1)
        #expect(ui.fills.count == 1)
        #expect(ui.fills.first?.username == "jane")
        #expect(ui.fills.first?.password == "hunter2" + code)
    }

    @Test func opensTheWindowWhenItIsClosed() async {
        ui.current = .closed
        let session = makeSession()
        await connect(session)

        #expect(ui.toggles == 1)
        #expect(session.phase.isConnected)
    }

    @Test func aRejectedLoginIsNeverRetried() async {
        ui.afterLogin = [.other, .login]
        let session = makeSession()
        await connect(session)

        #expect(session.phase.isFailed)
        #expect(ui.loginPresses == 1)
        #expect(ui.fills.count == 1)
        #expect(ui.passwordClears == 1)
    }

    @Test func aLoginScreenThatNeverChangesCountsAsRejected() async {
        ui.afterLogin = []
        let session = makeSession()
        await connect(session)

        #expect(session.phase.isFailed)
        #expect(ui.loginPresses == 1)
    }

    @Test func aCancelledTouchIDSendsNothing() async {
        let session = makeSession()
        await session.connect(credentials: { nil })

        #expect(session.phase == .idle)
        #expect(ui.toggles == 0)
        #expect(ui.portalPresses == 0)
        #expect(ui.fills.isEmpty)
    }

    @Test func missingAccessStopsBeforeReadingSecrets() async {
        ui.accessError = GateLinkError("no permission")
        let session = makeSession()
        var asked = false
        await session.connect(credentials: {
            asked = true
            return nil
        })

        #expect(!asked)
        #expect(session.phase == .failed("no permission"))
    }

    @Test func waitsForTheNextCodeWhenThisOneIsAboutToExpire() async {
        clock.advance(by: 10) // 5 seconds left in the step
        let start = clock.now
        let session = makeSession()
        await connect(session)

        let used = ui.fills.first?.password
        #expect(used != "hunter2" + totp.code(at: start))
        #expect(used == "hunter2" + totp.code(at: totp.nextRollover(after: start)))
    }

    @Test func aQuickReconnectDoesNotReuseACode() async {
        let session = makeSession()
        await connect(session)
        ui.logSays = false
        session.refresh()
        #expect(session.phase == .idle)

        ui.startOver()
        await connect(session)
        #expect(ui.fills.count == 2)
        #expect(ui.fills[0].password != ui.fills[1].password)
    }

    @Test func alreadyConnectedSendsNothing() async {
        ui.current = .connected
        let session = makeSession()
        await connect(session)

        #expect(session.phase.isConnected)
        #expect(ui.fills.isEmpty)
    }

    @Test func cancellingBeforeTheLoginTypesNothing() async {
        ui.current = .other
        let session = makeSession()
        let task = Task { await session.connect(credentials: credentials()) }
        #expect(await drive(clock) { clock.pendingSleeps > 0 })
        await session.cancel()
        await task.value

        #expect(session.phase == .idle)
        #expect(ui.fills.isEmpty)
    }

    @Test func aDroppedSessionNotifiesOnce() {
        let session = makeSession()
        var drops = 0
        session.onDisconnect = { drops += 1 }

        ui.logSays = true
        session.refresh()
        #expect(session.phase.isConnected)

        ui.logSays = false
        session.refresh()
        session.refresh()
        #expect(session.phase == .idle)
        #expect(drops == 1)
    }

    @Test func recognisesTheRealScreens() {
        typealias E = GlobalProtectScreen.Element
        let portal = [E(role: "AXImage", title: "GlobalProtect Disconnected"), E(role: "AXStaticText", text: "Not Connected"),
                      E(role: "AXTextField"), E(role: "AXButton", title: "Connect")]
        let login = [E(role: "AXImage", title: "GlobalProtect"), E(role: "AXTextField"),
                     E(role: "AXTextField", subrole: "AXSecureTextField"), E(role: "AXButton", title: "Connect")]
        let connected = [E(role: "AXImage", title: "GlobalProtect Connected"), E(role: "AXStaticText", text: "Connected"),
                         E(role: "AXButton", title: "Disconnect")]

        #expect(GlobalProtectScreen(elements: []) == .closed)
        #expect(GlobalProtectScreen(elements: portal) == .portal)
        #expect(GlobalProtectScreen(elements: login) == .login)
        #expect(GlobalProtectScreen(elements: connected) == .connected)
        #expect(GlobalProtectScreen(elements: [E(role: "AXImage", title: "GlobalProtect")]) == .other)
    }

    @Test func readsTheConnectionFromRealLogLines() {
        let up = "[Info ]: IPSec tunnel creation finished with Gateway vpn.bri.co.id.\n[Info ]: HIP Report submitted to the Gateway vpn.bri.co.id.\n"
        let restored = up + "[Info ]: Tunnel is down due to network change.\n[Info ]: Tunnel is restored.\n"
        let restoring = up + "[Info ]: Tunnel is down due to keep-alive timeout.\n[Info ]: Gateway RGN Gateway: Checking network availability and restoring VPN connection\n"
        let userDown = up + "[Info ]: Tunnel is down due to disconnection.\n[Info ]: User was logged out of Gateway vpn.bri.co.id.\n"
        let gaveUp = restoring + "[Info ]: User could not be logged out of Gateway vpn.bri.co.id.\n"
        let rebooted = up + "[Info ]: GlobalProtect service started (client version: 6.0.7-372).\n"

        #expect(GlobalProtectLog.isConnected(up) == true)
        #expect(GlobalProtectLog.isConnected(restored) == true)
        #expect(GlobalProtectLog.isConnected(restoring) == true)
        #expect(GlobalProtectLog.isConnected(userDown) == false)
        #expect(GlobalProtectLog.isConnected(gaveUp) == false)
        #expect(GlobalProtectLog.isConnected(rebooted) == false)
        #expect(GlobalProtectLog.isConnected("") == nil)
    }
}
