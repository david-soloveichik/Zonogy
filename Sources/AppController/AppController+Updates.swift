/// AppController extension for the software update check: menu wiring, alerts, and settings accessors.
import Foundation
import AppKit

extension AppController {
    /// Wires the update checker to the menu bar item and alert presentation, then starts its schedule.
    internal func startUpdateChecker() {
        updateChecker.onAvailableUpdateChange = { [weak self] update in
            self?.menuBarManager.setAvailableUpdateVersion(update?.version)
        }
        updateChecker.onCheckCompleted = { [weak self] outcome in
            self?.presentCheckOutcome(outcome)
        }
        updateChecker.start()
    }

    // MARK: - MenuBarManagerDelegate

    func menuBarManagerDidRequestCheckForUpdates() {
        // While the menu already advertises an update, its item is a direct link to the release.
        if let update = updateChecker.availableUpdate {
            AppLinks.open(update.pageURL)
            return
        }
        updateChecker.checkManually()
    }

    // MARK: - Alerts

    private func presentCheckOutcome(_ outcome: UpdateCheckOutcome) {
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

    private func presentUpdateAvailableAlert(for update: UpdateInfo) {
        let alert = NSAlert()
        alert.messageText = "Zonogy \(update.version) is available"
        alert.informativeText = "You have Zonogy \(AppVersion.marketingVersion)."
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        switch runUpdateCheckAlert(alert) {
        case .alertFirstButtonReturn:
            AppLinks.open(update.pageURL)
        case .alertThirdButtonReturn:
            updateChecker.skipVersion(update.version)
        default:
            break
        }
    }

    private func presentInformationalAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        _ = runUpdateCheckAlert(alert)
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

    /// Runs the alert modally, dismissing an open Launcher so it does not cover the alert.
    private func runUpdateCheckAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
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
