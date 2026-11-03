import Foundation
import Testing
@testable import GateLinkKit

/// Runs the real PTY login against a fake `openconnect` shell script.
@Suite struct AuthenticatorTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "gatelink-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The fake prompts like GlobalProtect, checks the combined credential,
    /// and records its arguments.
    func fakeOpenConnect(expecting credential: String, reprompt: Bool = true, prompt: Bool = true) throws -> URL {
        let script = """
        #!/bin/bash
        printf '%s\\n' "$@" > "\(directory.path)/args"
        echo "POST https://vpn.example.com/ssl-vpn/login.esp"
        \(prompt ? "" : "sleep 30")
        printf 'Password: '
        IFS= read -r cred
        if [ "$cred" = "\(credential)" ]; then
          echo "COOKIE='authcookie=abc'"
          echo "HOST='203.0.113.10'"
          echo "FINGERPRINT='pin-sha256:AbC+/12=='"
          exit 0
        fi
        echo "Login failed. got=$cred"
        \(reprompt ? "printf 'Password: '; IFS= read -r cred" : "")
        exit 1
        """
        let url = directory.appending(path: "openconnect")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func answersThePromptAndParsesTheCookie() async throws {
        let fake = try fakeOpenConnect(expecting: "hunter2123456")
        let cookie = try await OpenConnectAuthenticator(executableURL: fake)
            .authenticate(gateway: "vpn.example.com", username: "jane", credential: "hunter2123456")

        #expect(cookie.cookie == "authcookie=abc")
        #expect(cookie.fingerprint == "pin-sha256:AbC+/12==")
        let args = try String(contentsOf: directory.appending(path: "args"), encoding: .utf8)
        #expect(args == "--protocol=gp\n--usergroup=gateway\n--cafile=/etc/ssl/cert.pem\n-u\njane\n--authenticate\nvpn.example.com\n")
    }

    @Test func failsFastWhenTheGatewayPromptsAgain() async throws {
        let fake = try fakeOpenConnect(expecting: "right")
        await #expect(throws: GateLinkError("Login failed: the gateway asked for the password again. Check the password and OTP.")) {
            try await OpenConnectAuthenticator(executableURL: fake)
                .authenticate(gateway: "vpn.example.com", username: "jane", credential: "wrong")
        }
    }

    @Test func redactsTheCredentialFromErrors() async throws {
        let fake = try fakeOpenConnect(expecting: "right", reprompt: false)
        do {
            _ = try await OpenConnectAuthenticator(executableURL: fake)
                .authenticate(gateway: "vpn.example.com", username: "jane", credential: "s3cret999999")
            Issue.record("Expected a failure")
        } catch {
            #expect(!error.localizedDescription.contains("s3cret"))
            #expect(error.localizedDescription.hasPrefix("Login failed:"))
        }
    }

    @Test func timesOut() async throws {
        let fake = try fakeOpenConnect(expecting: "x", prompt: false)
        await #expect(throws: GateLinkError("Login timed out after 1 seconds. Check the gateway and try again.")) {
            try await OpenConnectAuthenticator(executableURL: fake, timeout: 1)
                .authenticate(gateway: "vpn.example.com", username: "jane", credential: "x")
        }
    }

    @Test func honoursCancellation() async throws {
        let fake = try fakeOpenConnect(expecting: "x", prompt: false)
        let task = Task {
            try await OpenConnectAuthenticator(executableURL: fake)
                .authenticate(gateway: "vpn.example.com", username: "jane", credential: "x")
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
