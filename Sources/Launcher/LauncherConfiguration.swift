/// Codable models for the user-editable launcher configuration file.

import Foundation

struct LauncherConfiguration: Codable, Sendable {
    var items: [LauncherConfigurationItem]
    var notes: String?

    init(items: [LauncherConfigurationItem], notes: String? = nil) {
        self.items = items
        self.notes = notes
    }
}

struct LauncherConfigurationItem: Codable, Sendable {
    var path: String
    var alias: String?
}
