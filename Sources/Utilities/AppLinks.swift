/// Shared Zonogy links (repository, releases, feedback) and handing them to the system.
import Foundation
import AppKit

enum AppLinks {
    /// Owner and repository name. Every GitHub link below is built from it, so moving the
    /// repository is a one-line change.
    private static let repositorySlug = "david-soloveichik/Zonogy"

    /// Repository home, opened from the menu bar's Help submenu.
    static let repository = URL(string: "https://github.com/\(repositorySlug)")!
    /// New issue form, for feedback the user is happy to file in public.
    static let feedbackIssue = URL(string: "https://github.com/\(repositorySlug)/issues/new")!
    /// Release page offered by the update check.
    static let latestReleasePage = URL(string: "https://github.com/\(repositorySlug)/releases/latest")!
    /// Metadata the update check reads to learn the newest published version.
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(repositorySlug)/releases/latest")!
    /// New message to the maintainer, for feedback the user would rather keep private.
    static let feedbackEmail = URL(string: "mailto:vulpine-minds-0d@icloud.com?subject=Zonogy%20Feedback")!

    /// Hands a link to whichever app the user has chosen for it (browser, email client, ...).
    /// Nothing can be done about a refusal beyond noting it.
    static func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            Logger.debug("Failed to open \(url.absoluteString)")
        }
    }
}
