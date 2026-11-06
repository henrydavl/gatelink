import AppKit
import GateLinkKit
import ServiceManagement
import UserNotifications

/// The menu bar app's updater and system settings.
extension AppModel {
    func startPlatform() {
        removeLegacyLaunchAgent()
        refreshOpenAtLogin()
        startUpdateTicker()
        notifier.onTap = { [weak self] in
            Task { await self?.connect() }
        }
        UNUserNotificationCenter.current().delegate = notifier
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        session.onDisconnect = { [weak self] in self?.notifier.announceDisconnect() }
        session.startMonitoring()
    }

    // MARK: - Update

    var updater: Updater { Updater(currentVersion: version) }

    /// Checks GitHub now. `quietly` keeps network errors and "up to date" out of the popover.
    func checkForUpdate(quietly: Bool = false) async {
        guard updateStep == nil else { return }
        do {
            availableUpdate = try await updater.check()
            if !quietly, availableUpdate == nil { message = "GateLink \(version) is up to date." }
        } catch {
            if !quietly { message = error.localizedDescription }
        }
    }

    /// Downloads, verifies and installs the update, then relaunches the new app.
    func installUpdate() async {
        guard let update = availableUpdate, updateStep == nil else { return }
        message = nil
        do {
            updateStep = .downloading(0)
            let package = try await updater.download(update) { fraction in
                Task { @MainActor [weak self] in
                    if case .downloading = self?.updateStep { self?.updateStep = .downloading(fraction) }
                }
            }
            updateStep = .verifying
            try await updater.verifyPackage(package, version: update.version)

            await session.cancel()
            updateStep = .installing
            try await updater.install(package, version: update.version)
            try Updater.relaunchAfterExit()
            NSApp.terminate(nil)
        } catch {
            updateStep = nil
            message = error.localizedDescription
        }
    }

    func openReleaseNotes() {
        guard let url = availableUpdate?.pageURL else { return }
        NSWorkspace.shared.open(url)
    }

    func startUpdateTicker() {
        updateTicker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkForUpdate(quietly: true)
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    // MARK: - System

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            message = "Could not change Open at Login: \(error.localizedDescription)"
        }
        refreshOpenAtLogin()
    }

    func refreshOpenAtLogin() {
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// The .NET app used a LaunchAgent; Open at Login now uses SMAppService.
    func removeLegacyLaunchAgent() {
        let agent = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/com.gatelink.app.plist")
        try? FileManager.default.removeItem(at: agent)
    }

    func quit() {
        NSApp.terminate(nil)
    }
}

/// Says when GlobalProtect's session ends; clicking starts a new login, which asks for Touch ID.
final class DisconnectNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    @MainActor var onTap: (@MainActor @Sendable () -> Void)?

    func announceDisconnect() {
        let content = UNMutableNotificationContent()
        content.title = "GlobalProtect disconnected"
        content.body = "Click to log in again with Touch ID."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "disconnected", content: content, trigger: nil)
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await onTap?()
    }

    /// A menu bar app can count as frontmost; still show the banner.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
