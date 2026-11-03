import Foundation
import GateLinkKit
import os

/// Logs in with libopenconnect in the app, like `openconnect --authenticate`
/// on macOS, and returns the cookie and certificate pin for the extension.
///
/// shortcut: a login already sent cannot be interrupted; Cancel stops waiting
/// for it and VPNSession drops the late result.
struct LibOpenConnectAuthenticator: VPNAuthenticator {
    func authenticate(gateway: String, username: String, credential: String) async throws -> GPCookie {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var cookie: UnsafeMutablePointer<CChar>?
                var fingerprint: UnsafeMutablePointer<CChar>?
                var error = [CChar](repeating: 0, count: 256)
                let status = gl_login(gateway, username, credential, &cookie, &fingerprint,
                                      openConnectLog, nil, &error, error.count)
                defer {
                    free(cookie)
                    free(fingerprint)
                }
                if status == 0, let cookie, let fingerprint {
                    continuation.resume(returning: GPCookie(cookie: String(cString: cookie), fingerprint: String(cString: fingerprint)))
                } else {
                    continuation.resume(throwing: GateLinkError(TunnelShared.string(error)))
                }
            }
        }
    }
}

private let loginLog = Logger(subsystem: "com.example.gatelink", category: "login")

/// openconnect progress lines. Form values (password, OTP) are never logged.
let openConnectLog: gl_log_fn = { _, level, line in
    guard let line else { return }
    let text = String(cString: line)
    if level == PRG_ERR {
        loginLog.error("\(text, privacy: .public)")
    } else {
        loginLog.info("\(text, privacy: .public)")
    }
}
