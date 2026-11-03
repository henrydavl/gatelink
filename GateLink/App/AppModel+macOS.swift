import AppKit
import GateLinkKit
import ServiceManagement

/// The menu bar app's helper, updater and system settings.
extension AppModel {
    func startPlatform() {
        if resources.openConnectURL == nil {
            message = "The OpenConnect engine is missing. Open Requirements from the … menu."
        }
        removeLegacyLaunchAgent()
        refreshOpenAtLogin()
        startUpdateTicker()
        Task { await session.stopLeftoverTunnel() }
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

            // Installer replaces the tunnel helper's engine, so the tunnel must not be using it.
            if session.phase.isConnected {
                await session.disconnect()
            } else if session.phase.isBusy {
                await session.cancel()
            }
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

    func refreshRequirements() async {
        requirements = await Requirements.check(resources)
    }

    func uninstallHelper() async {
        do {
            try await helper.uninstall()
            message = "The tunnel helper was removed."
        } catch {
            message = error.localizedDescription
        }
        await refreshRequirements()
    }

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
        // The tunnel helper sees its stdin close and stops the VPN.
        NSApp.terminate(nil)
    }
}
