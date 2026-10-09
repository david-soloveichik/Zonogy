/// Remembers verified Dock activations so Zonogy can resume a surviving patch after a crash.
import Foundation

struct InstantMinimizeActivation: Codable, Equatable {
    let dock: InstantMinimizeDock
    let verifiedAt: TimeInterval
}

enum InstantMinimizeActivationStore {
    static func load(defaults: UserDefaults = .standard) -> InstantMinimizeActivation? {
        guard let data = defaults.data(forKey: UserDefaultsKeys.instantMinimizeActivation) else { return nil }
        return try? PropertyListDecoder().decode(InstantMinimizeActivation.self, from: data)
    }

    static func save(_ activation: InstantMinimizeActivation?, defaults: UserDefaults = .standard) {
        if let activation, let data = try? PropertyListEncoder().encode(activation) {
            defaults.set(data, forKey: UserDefaultsKeys.instantMinimizeActivation)
        } else {
            defaults.removeObject(forKey: UserDefaultsKeys.instantMinimizeActivation)
        }
    }
}
