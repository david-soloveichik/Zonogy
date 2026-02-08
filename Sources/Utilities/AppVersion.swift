/// Shared Zonogy version formatting for UI and logs.
import Foundation

enum AppVersion {
    static var preferencesDisplayString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Zonogy Window Manager \(version)"
    }
}
