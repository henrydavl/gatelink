import Foundation
import Testing
@testable import GateLinkKit

@Suite struct GPCookieTests {
    @Test func parsesQuotedValuesWithCRLF() throws {
        let output = "POST https://vpn.example.com/ssl-vpn/login.esp\r\n"
            + "COOKIE='authcookie=abc&portal=gw&user=jane'\r\n"
            + "HOST='203.0.113.10'\r\n"
            + "CONNECT_URL='https://vpn.example.com'\r\n"
            + "FINGERPRINT='pin-sha256:AbC+/12=='\r\n"
            + "RESOLVE='vpn.example.com:203.0.113.10'\r\n"
        let cookie = try GPCookie.parse(output)
        #expect(cookie.cookie == "authcookie=abc&portal=gw&user=jane")
        #expect(cookie.fingerprint == "pin-sha256:AbC+/12==")
    }

    @Test func requiresACookie() {
        #expect(throws: GateLinkError.self) {
            try GPCookie.parse("Login failed.\nHOST=1.2.3.4")
        }
    }
}

@Suite struct TunnelArgsTests {
    @Test func asksForESPOnlyWhenEnabled() {
        let base = ["-n", "/helper", "connect", "--host", "vpn.example.com", "--fingerprint", "pin-sha256:AbC="]
        func arguments(useESP: Bool) -> [String] {
            HelperTunnelController.arguments(
                helperPath: "/helper", host: "vpn.example.com", fingerprint: "pin-sha256:AbC=", useESP: useESP
            )
        }
        #expect(arguments(useESP: false) == base)
        #expect(arguments(useESP: true) == base + ["--esp"])
    }

    @Test(arguments: ["vpn.example.com", "203.0.113.10", "a", "gw-1.corp.example"])
    func acceptsHosts(_ host: String) {
        #expect(TunnelArgs.isValidHost(host))
    }

    @Test(arguments: ["", "-oProxyCommand=x", "vpn example.com", "host;rm -rf /", "/etc/passwd",
                      "vpn.example.com.", ".vpn", String(repeating: "a", count: 254)])
    func rejectsHosts(_ host: String) {
        #expect(!TunnelArgs.isValidHost(host))
    }

    @Test func validatesFingerprints() {
        #expect(TunnelArgs.isValidFingerprint("pin-sha256:AbC+/12=="))
        #expect(TunnelArgs.isValidFingerprint("sha256:0123abcd"))
        #expect(!TunnelArgs.isValidFingerprint("--script=/tmp/x"))
        #expect(!TunnelArgs.isValidFingerprint("sha256:ab cd"))
        #expect(!TunnelArgs.isValidFingerprint(""))
    }
}

@Suite struct OpenConnectOutputTests {
    @Test(arguments: [
        "Password: ",
        "POST https://vpn.example.com/ssl-vpn/login.esp\r\nPassword:",
        "Enter login credentials\nPasscode:  ",
        "Password for jane: ",
    ])
    func detectsPrompts(_ text: String) {
        #expect(OpenConnectOutput.endsWithCredentialPrompt(text))
    }

    @Test(arguments: [
        "POST https://vpn.example.com/ssl-vpn/login.esp\n",
        "Password:\nCOOKIE='abc'\n",
        "Connected to 203.0.113.10:443",
        "",
    ])
    func ignoresNonPrompts(_ text: String) {
        #expect(!OpenConnectOutput.endsWithCredentialPrompt(text))
    }

    @Test func recognizesEstablishedAndErrors() {
        #expect(OpenConnectOutput.isEstablished("Configured as 10.0.0.5, with SSL connected and ESP in progress"))
        #expect(OpenConnectOutput.isEstablished("ESP session established with server"))
        #expect(!OpenConnectOutput.isEstablished("Connected to HTTPS on vpn.example.com"))
        #expect(OpenConnectOutput.firstError(in: "ok\nsudo: a password is required\n") == "sudo: a password is required")
        #expect(OpenConnectOutput.isIncompatibleEngine("dyld[123]: Symbol not found: _foo"))
    }
}
