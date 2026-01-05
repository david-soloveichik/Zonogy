/// Defines the available zone targeting behaviors.
import Foundation

enum TargetingMode: String, CaseIterable, Codable {
    case independentOfFocus
    case followsFocus

    var displayName: String {
        switch self {
        case .independentOfFocus:
            "Targeting independent of focus"
        case .followsFocus:
            "Targeting follows focus"
        }
    }
}

