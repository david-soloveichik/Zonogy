/// Stores and persists keyboard shortcut preferences
import Foundation
import Carbon

/// Manages all keyboard shortcut configurations with persistence
final class KeyboardShortcutPreferences: ObservableObject {
    static let shared = KeyboardShortcutPreferences()

    /// All configurable shortcut actions
    enum ShortcutAction: String, CaseIterable, Codable {
        case addZone
        case removeZone
        case captureTimeTravelLogs
        case flipKeyWindow
        case clearOrResetZones
        case clearOrResetZonesAtCursor
        case targetTemporaryZone
        case navigateUp
        case navigateLeft
        case navigateRight
        case minimizeActiveWindow
        case minimizeWindowOrRemoveZoneAtCursor

        var displayName: String {
            switch self {
            case .addZone: return "Add Zone"
            case .removeZone: return "Remove Zone"
            case .captureTimeTravelLogs: return "Capture Time-Travel Logs"
            case .flipKeyWindow: return "Flip Key Window to Another Screen"
            case .clearOrResetZones: return "Clear/Reset Zones (Active Screen)"
            case .clearOrResetZonesAtCursor: return "Clear/Reset Zones (Cursor Screen)"
            case .targetTemporaryZone: return "Target Temporary Zone"
            case .navigateUp: return "Navigate Up"
            case .navigateLeft: return "Navigate Left"
            case .navigateRight: return "Navigate Right"
            case .minimizeActiveWindow: return "Minimize Active Window"
            case .minimizeWindowOrRemoveZoneAtCursor: return "Minimize/Remove Zone at Cursor"
            }
        }

        var defaultShortcut: KeyboardShortcut {
            let cmdCtrl = UInt32(cmdKey | controlKey)
            let cmdCtrlShiftOpt = UInt32(cmdKey | controlKey | shiftKey | optionKey)
            let cmdOnly = UInt32(cmdKey)

            switch self {
            case .addZone:
                return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Equal), modifiers: cmdCtrl)
            case .removeZone:
                return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Minus), modifiers: cmdCtrl)
            case .captureTimeTravelLogs:
                return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Z), modifiers: cmdCtrl)
            case .flipKeyWindow:
                return KeyboardShortcut(keyCode: UInt32(kVK_Return), modifiers: cmdCtrl)
            case .clearOrResetZones:
                return KeyboardShortcut(keyCode: UInt32(kVK_Space), modifiers: cmdCtrl)
            case .clearOrResetZonesAtCursor:
                return KeyboardShortcut(keyCode: UInt32(kVK_Space), modifiers: cmdCtrlShiftOpt)
            case .targetTemporaryZone:
                return KeyboardShortcut(keyCode: UInt32(kVK_DownArrow), modifiers: cmdCtrl)
            case .navigateUp:
                return KeyboardShortcut(keyCode: UInt32(kVK_UpArrow), modifiers: cmdCtrl)
            case .navigateLeft:
                return KeyboardShortcut(keyCode: UInt32(kVK_LeftArrow), modifiers: cmdCtrl)
            case .navigateRight:
                return KeyboardShortcut(keyCode: UInt32(kVK_RightArrow), modifiers: cmdCtrl)
            case .minimizeActiveWindow:
                return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: cmdOnly)
            case .minimizeWindowOrRemoveZoneAtCursor:
                return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: cmdCtrlShiftOpt)
            }
        }
    }

    private struct StoredPreferences: Codable {
        var shortcuts: [String: KeyboardShortcut]
    }

    @Published private(set) var shortcuts: [ShortcutAction: KeyboardShortcut] = [:]
    private let preferencesURL: URL

    var onShortcutsChanged: (() -> Void)?

    private init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Zonogy")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.preferencesURL = appSupport.appendingPathComponent("shortcuts.json")

        loadShortcuts()
    }

    func shortcut(for action: ShortcutAction) -> KeyboardShortcut {
        shortcuts[action] ?? action.defaultShortcut
    }

    func setShortcut(_ shortcut: KeyboardShortcut, for action: ShortcutAction) {
        shortcuts[action] = shortcut
        saveShortcuts()
        onShortcutsChanged?()
    }

    func resetToDefault(action: ShortcutAction) {
        shortcuts.removeValue(forKey: action)
        saveShortcuts()
        onShortcutsChanged?()
    }

    func resetAllToDefaults() {
        shortcuts.removeAll()
        saveShortcuts()
        onShortcutsChanged?()
    }

    private func loadShortcuts() {
        guard FileManager.default.fileExists(atPath: preferencesURL.path),
              let data = try? Data(contentsOf: preferencesURL),
              let stored = try? JSONDecoder().decode(StoredPreferences.self, from: data) else {
            Logger.debug("No stored keyboard shortcuts found, using defaults")
            return
        }

        for (key, shortcut) in stored.shortcuts {
            if let action = ShortcutAction(rawValue: key) {
                shortcuts[action] = shortcut
            }
        }
        Logger.debug("Loaded \(shortcuts.count) custom keyboard shortcuts")
    }

    private func saveShortcuts() {
        var stored = StoredPreferences(shortcuts: [:])
        for (action, shortcut) in shortcuts {
            stored.shortcuts[action.rawValue] = shortcut
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(stored)
            try data.write(to: preferencesURL)
            Logger.debug("Saved keyboard shortcuts to \(preferencesURL.path)")
        } catch {
            Logger.debug("Failed to save keyboard shortcuts: \(error)")
        }
    }
}
