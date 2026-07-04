/// Checks GitHub Releases for a newer Zonogy version: automatic daily checks, manual checks,
/// and the skip-version state that drives the menu bar's update hint.

import Foundation

/// A newer release the user can move to.
struct UpdateInfo {
    /// Normalized version like "1.1" (release tag with any leading "v" removed).
    let version: String
    /// Release page to open in the browser.
    let pageURL: URL
}

/// Outcome of a completed check, delivered on the main queue.
enum UpdateCheckOutcome {
    case upToDate
    case updateAvailable(UpdateInfo)
    case failed(String)
}

final class UpdateChecker {
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/david-soloveichik/Zonogy/releases/latest")!
    private static let releasesPage = URL(string: "https://github.com/david-soloveichik/Zonogy/releases/latest")!
    private static let launchCheckDelay: TimeInterval = 10
    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    /// Latest known newer version, nil when up to date or the user skipped it. Drives the menu bar hint.
    private(set) var availableUpdate: UpdateInfo?

    /// Called on the main queue whenever `availableUpdate` changes (including to nil).
    var onAvailableUpdateChange: ((UpdateInfo?) -> Void)?
    /// Called on the main queue when an automatic check finds a version not yet alerted this run.
    /// Returns whether the alert was actually presented; only then is the version marked alerted,
    /// so a presentation dropped behind an already-visible alert can retry on a later check.
    var onAutomaticUpdateFound: ((UpdateInfo) -> Bool)?

    private var latestKnown: UpdateInfo?
    private var alertedVersion: String?
    private var timer: Timer?

    /// Schedules the post-launch check and the daily repeating check. Both consult the
    /// automatic-check preference when they fire, so toggling it needs no rescheduling.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchCheckDelay) { [weak self] in
            self?.performAutomaticCheck()
        }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.automaticCheckInterval, repeats: true) { [weak self] _ in
            self?.performAutomaticCheck()
        }
        timer.tolerance = 60 * 60
        self.timer = timer
    }

    /// Fetches the latest release now and reports the outcome. Reports a skipped version too,
    /// so an explicit check always tells the truth.
    func checkManually(completion: @escaping (UpdateCheckOutcome) -> Void) {
        performCheck(completion: completion)
    }

    /// Silences the automatic alert and the menu hint for this version; a newer release triggers normally.
    func skipVersion(_ version: String) {
        UpdateCheckPreferencesStore.saveSkippedVersion(version)
        Logger.debug("Update check: user skipped version \(version)")
        refreshAvailableUpdate()
    }

    private func performAutomaticCheck() {
        guard UpdateCheckPreferencesStore.loadAutomaticCheckEnabled() else { return }
        performCheck { [weak self] outcome in
            guard let self, case .updateAvailable(let update) = outcome else { return }
            let skipped = UpdateCheckPreferencesStore.loadSkippedVersion()
            if update.version != skipped, update.version != self.alertedVersion,
               self.onAutomaticUpdateFound?(update) == true {
                self.alertedVersion = update.version
            }
        }
    }

    private func performCheck(completion: @escaping (UpdateCheckOutcome) -> Void) {
        var request = URLRequest(url: Self.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub's API requires a User-Agent identifying the calling app.
        request.setValue("Zonogy/\(AppVersion.marketingVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                completion(self.outcome(data: data, response: response, error: error))
            }
        }.resume()
    }

    /// Interprets the API response, updating the known-update state on success.
    private func outcome(data: Data?, response: URLResponse?, error: Error?) -> UpdateCheckOutcome {
        if let error {
            Logger.debug("Update check failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            Logger.debug("Update check failed: HTTP \(status)")
            // 404 covers a repository without published releases (or one that isn't public).
            return .failed(status == 404 ? "No published releases were found." : "GitHub responded with status \(status).")
        }
        struct LatestRelease: Decodable {
            let tagName: String
            let htmlURL: String?
            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case htmlURL = "html_url"
            }
        }
        guard let data, let release = try? JSONDecoder().decode(LatestRelease.self, from: data) else {
            Logger.debug("Update check failed: unreadable response")
            return .failed("The response from GitHub could not be read.")
        }
        let version = UpdateVersionComparison.normalized(release.tagName)
        let current = AppVersion.marketingVersion
        guard UpdateVersionComparison.isNewer(releaseTag: release.tagName, than: current) else {
            Logger.debug("Update check: up to date (current \(current), latest release \(version))")
            latestKnown = nil
            refreshAvailableUpdate()
            return .upToDate
        }
        let pageURL = release.htmlURL.flatMap(URL.init(string:)) ?? Self.releasesPage
        let update = UpdateInfo(version: version, pageURL: pageURL)
        Logger.debug("Update check: version \(version) available (current \(current))")
        latestKnown = update
        refreshAvailableUpdate()
        return .updateAvailable(update)
    }

    /// Recomputes the menu-facing update (latest known unless skipped) and notifies on change.
    private func refreshAvailableUpdate() {
        let skipped = UpdateCheckPreferencesStore.loadSkippedVersion()
        let effective = latestKnown.flatMap { $0.version == skipped ? nil : $0 }
        guard effective?.version != availableUpdate?.version else { return }
        availableUpdate = effective
        onAvailableUpdateChange?(effective)
    }
}
