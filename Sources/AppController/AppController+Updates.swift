/// AppController extension for the software update check: menu wiring, alerts, and settings accessors.
import Foundation
import AppKit

extension AppController {
    /// Wires the update checker to the menu bar item and alert presentation, then starts its schedule.
    internal func startUpdateChecker() {
        updateChecker.onAvailableUpdateChange = { [weak self] update in
            self?.menuBarManager.setAvailableUpdateVersion(update?.version)
        }
        updateChecker.onAutomaticUpdateFound = { [weak self] update in
            self?.presentUpdateAvailableAlert(for: update) ?? false
        }
        updateChecker.start()
    }

    // MARK: - MenuBarManagerDelegate

    func menuBarManagerDidRequestCheckForUpdates() {
        // While the menu already advertises an update, its item is a direct link to the release.
        if let update = updateChecker.availableUpdate {
            NSWorkspace.shared.open(update.pageURL)
            return
        }
        updateChecker.checkManually { [weak self] outcome in
            self?.presentManualCheckOutcome(outcome)
        }
    }

    // MARK: - Alerts

    private func presentManualCheckOutcome(_ outcome: UpdateCheckOutcome) {
        switch outcome {
        case .updateAvailable(let update):
            presentUpdateAvailableAlert(for: update)
        case .upToDate:
            presentInformationalAlert(
                title: "You're up to date",
                text: "Zonogy \(AppVersion.marketingVersion) is the latest version."
            )
        case .failed(let reason):
            presentInformationalAlert(title: "Could not check for updates", text: reason)
        }
    }

    /// Returns whether the alert was actually presented (false when another
    /// update-check alert is already on screen).
    @discardableResult
    private func presentUpdateAvailableAlert(for update: UpdateInfo) -> Bool {
        // A manual check can complete while an automatic check's alert is still up
        // (or vice versa); never stack a second modal alert on the first.
        guard !isPresentingUpdateCheckAlert else { return false }
        isPresentingUpdateCheckAlert = true
        defer { isPresentingUpdateCheckAlert = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Zonogy \(update.version) is available"
        alert.informativeText = "You have Zonogy \(AppVersion.marketingVersion)."
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(update.pageURL)
        case .alertThirdButtonReturn:
            updateChecker.skipVersion(update.version)
        default:
            break
        }
        return true
    }

    private func presentInformationalAlert(title: String, text: String) {
        guard !isPresentingUpdateCheckAlert else { return }
        isPresentingUpdateCheckAlert = true
        defer { isPresentingUpdateCheckAlert = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: - Settings

    var isAutomaticUpdateCheckEnabledInSettings: Bool {
        UpdateCheckPreferencesStore.loadAutomaticCheckEnabled()
    }

    func setAutomaticUpdateCheckEnabledFromSettings(_ enabled: Bool) {
        UpdateCheckPreferencesStore.saveAutomaticCheckEnabled(enabled)
        Logger.debug("Automatic update check \(enabled ? "enabled" : "disabled") from settings")
    }
}
