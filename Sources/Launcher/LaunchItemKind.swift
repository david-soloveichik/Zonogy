/// Classifies a selectable item as an application, directory, or file.

import Foundation

enum LaunchItemKind: Sendable {
    case application
    case directory
    case file
}
