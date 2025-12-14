/// Abstraction for discovering applications available on the system.

import Foundation

protocol AppProviding: Sendable {
    func discoverApplications(displayNameStyle: AppDisplayNameStyle, skipIcons: Bool) async -> [LaunchItem]
}
