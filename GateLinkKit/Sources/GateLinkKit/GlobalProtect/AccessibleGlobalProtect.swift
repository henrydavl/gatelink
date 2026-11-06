import AppKit
import ApplicationServices
import Security

/// Drives the official GlobalProtect app through macOS Accessibility.
@MainActor
public final class AccessibleGlobalProtect: GlobalProtectUI {
    private static let bundleID = "com.paloaltonetworks.GlobalProtect.client"
    /// Palo Alto Networks' Apple Developer team.
    private static let requirement = """
        anchor apple generic and identifier "\(bundleID)" and certificate leaf[subject.OU] = "PXPZ95SK77"
        """
    private static let eventLog = URL(fileURLWithPath: "/Library/Logs/PaloAltoNetworks/GlobalProtect/pan_gp_event.log")
    private static let logTailBytes: UInt64 = 16 * 1024

    public init() {}

    public func verifyAccess() throws {
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            throw GateLinkError(
                "Allow GateLink in System Settings > Privacy & Security > Accessibility, then press Connect. "
                    + "If it's already on, remove GateLink from the list and add it again."
            )
        }
        guard let app = running() else {
            throw GateLinkError("GlobalProtect isn't running. Open it, then press Connect.")
        }
        try verifySignature(of: app)
    }

    public func screen() -> GlobalProtectScreen {
        guard let window = window() else { return .closed }
        let elements = descendants(of: window).map { element in
            let role = string(element, "AXRole")
            return GlobalProtectScreen.Element(
                role: role,
                subrole: string(element, "AXSubrole"),
                title: string(element, "AXTitle"),
                // Labels only: this must never read a text field's value.
                text: role == "AXStaticText" ? string(element, "AXValue") : ""
            )
        }
        return GlobalProtectScreen(elements: elements)
    }

    public func toggleWindow() throws {
        guard let application = application(),
              let bar = attribute(application, "AXExtrasMenuBar").map({ $0 as! AXUIElement }),
              let icon = children(of: bar).first,
              AXUIElementPerformAction(icon, "AXPress" as CFString) == .success else {
            throw GateLinkError("Couldn't open GlobalProtect from its menu bar icon.")
        }
    }

    public func pressConnect() throws {
        guard let window = window(),
              let button = descendants(of: window).first(where: {
                  string($0, "AXRole") == "AXButton" && string($0, "AXTitle") == "Connect"
              }),
              AXUIElementPerformAction(button, "AXPress" as CFString) == .success else {
            throw GateLinkError("Couldn't press Connect in GlobalProtect.")
        }
    }

    public func fillLogin(username: String, password: String) throws {
        guard let app = running() else { throw GateLinkError("GlobalProtect stopped running.") }
        try verifySignature(of: app)
        guard let window = window(),
              let user = descendants(of: window).first(where: { string($0, "AXPlaceholderValue") == "Username" }),
              let secure = secureField(in: window) else {
            throw GateLinkError("Couldn't find GlobalProtect's username and password fields.")
        }
        guard set(user, to: username), string(user, "AXValue") == username,
              set(secure, to: password), string(secure, "AXValue").count == password.count else {
            clearPassword()
            throw GateLinkError("GlobalProtect didn't accept the username and password from GateLink.")
        }
    }

    public func clearPassword() {
        guard let window = window(), let secure = secureField(in: window) else { return }
        _ = set(secure, to: "")
    }

    public func connectedFromLog() -> Bool? {
        guard let file = try? FileHandle(forReadingFrom: Self.eventLog) else { return nil }
        defer { try? file.close() }
        guard let end = try? file.seekToEnd(), (try? file.seek(toOffset: end - min(end, Self.logTailBytes))) != nil,
              let data = try? file.readToEnd() else { return nil }
        return GlobalProtectLog.isConnected(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Accessibility

    private func running() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
    }

    /// Anything else claiming this bundle ID never receives the password.
    private func verifySignature(of app: NSRunningApplication) throws {
        var code: SecCode?
        var requirement: SecRequirement?
        let attributes = [kSecGuestAttributePid: app.processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw GateLinkError("The running GlobalProtect isn't signed by Palo Alto Networks, so GateLink won't log in to it.")
        }
    }

    private func application() -> AXUIElement? {
        guard let app = running() else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // These calls run on the main actor; a hung GlobalProtect must not freeze GateLink for long.
        AXUIElementSetMessagingTimeout(element, 2)
        return element
    }

    private func window() -> AXUIElement? {
        guard let application = application() else { return nil }
        return (attribute(application, "AXWindows") as? [AXUIElement])?.first
    }

    private func secureField(in window: AXUIElement) -> AXUIElement? {
        descendants(of: window).first { string($0, "AXSubrole") == "AXSecureTextField" }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func string(_ element: AXUIElement, _ name: String) -> String {
        attribute(element, name) as? String ?? ""
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, "AXChildren") as? [AXUIElement] ?? []
    }

    private func descendants(of element: AXUIElement) -> [AXUIElement] {
        children(of: element).flatMap { [$0] + descendants(of: $0) }
    }

    private func set(_ element: AXUIElement, to value: String) -> Bool {
        AXUIElementSetAttributeValue(element, "AXValue" as CFString, value as CFString) == .success
    }
}
