/// Defines the user-selectable strategy for computing an app's display name.

import Foundation

enum AppDisplayNameStyle: String, CaseIterable, Identifiable {
    case preferred
    case bundleInfo
    case localizedName
    case filename

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .preferred:
            "Preferred (Bundle → Localized → Filename)"
        case .bundleInfo:
            "Bundle Info (CFBundleDisplayName/Name)"
        case .localizedName:
            "Finder Localized Name"
        case .filename:
            "Bundle Filename"
        }
    }
}
