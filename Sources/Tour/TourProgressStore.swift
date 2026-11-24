/// What the tour remembers between launches: that it has been shown, so its Welcome chapter opens by itself
/// only once, and the page of that chapter to reopen at after the restart that follows granting Accessibility
/// from it.
import Foundation

enum TourProgressStore {
    static var hasBeenShown: Bool {
        get { UserDefaults.standard.bool(forKey: UserDefaultsKeys.tourShown) }
        set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.tourShown) }
    }

    static func saveResumePage(_ page: Int) {
        UserDefaults.standard.set(page, forKey: UserDefaultsKeys.tourResumePage)
    }

    /// The page to reopen at if a restart interrupted the tour. Asking clears it.
    static func takeResumePage() -> Int? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: UserDefaultsKeys.tourResumePage) != nil else {
            return nil
        }
        defer { defaults.removeObject(forKey: UserDefaultsKeys.tourResumePage) }
        return defaults.integer(forKey: UserDefaultsKeys.tourResumePage)
    }
}
