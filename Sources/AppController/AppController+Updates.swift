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
        let alert = NSAlert()
        alert.messageText = "Zonogy \(update.version) is available"
        alert.informativeText = "You have Zonogy \(AppVersion.marketingVersion)."
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        guard let response = runUpdateCheckAlert(alert) else { return false }
        switch response {
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
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        runUpdateCheckAlert(alert)
    }

    /// Update-themed icon for the update-check alerts. NSAlert would otherwise show the app
    /// icon, which degrades to a plain folder when the bare dev executable runs outside the
    /// app bundle.
    private static let updateCheckAlertIcon: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 52, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .controlAccentColor))
        return NSImage(systemSymbolName: "arrow.down.app", accessibilityDescription: "Software update")?
            .withSymbolConfiguration(configuration)
    }()

    /// Runs an update-check alert modally, returning nil without presenting when one is
    /// already on screen — a manual check can complete while an automatic check's alert
    /// is still up (or vice versa); never stack a second modal alert on the first.
    /// Dismisses an open Launcher first (as opening Preferences does) so its floating
    /// panel does not cover the alert.
    @discardableResult
    private func runUpdateCheckAlert(_ alert: NSAlert) -> NSApplication.ModalResponse? {
        guard !isPresentingUpdateCheckAlert else { return nil }
        isPresentingUpdateCheckAlert = true
        defer { isPresentingUpdateCheckAlert = false }
        if let icon = Self.updateCheckAlertIcon {
            alert.icon = icon
        }
        dismissLauncherIfActive()
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
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
