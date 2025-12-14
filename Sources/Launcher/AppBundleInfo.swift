/// Extracts display name and icon for an application bundle URL.

import AppKit
import Foundation

enum AppBundleInfo {
    static func displayName(for url: URL, style: AppDisplayNameStyle) -> String? {
        switch style {
        case .preferred:
            if let bundleName = bundleInfoName(for: url) {
                return bundleName
            }
            if let localized = localizedName(for: url) {
                return localized
            }
            return filenameName(for: url)
        case .bundleInfo:
            return bundleInfoName(for: url)
        case .localizedName:
            return localizedName(for: url)
        case .filename:
            return filenameName(for: url)
        }
    }

    private static func bundleInfoName(for url: URL) -> String? {
        if let bundle = Bundle(url: url) {
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !name.isEmpty {
                return name
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    private static func localizedName(for url: URL) -> String? {
        if let localized = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName, !localized.isEmpty {
            return localized
        }
        return nil
    }

    private static func filenameName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
