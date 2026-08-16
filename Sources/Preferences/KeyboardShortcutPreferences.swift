/// Stores and persists keyboard shortcut preferences
import Foundation
import Carbon

/// Manages all keyboard shortcut configurations with persistence
final class KeyboardShortcutPreferences: ObservableObject {
    static let shared = KeyboardShortcutPreferences()

    /// All configurable shortcut actions (ordered by feature group for Preferences UI)
    enum ShortcutAction: String, CaseIterable, Codable {
        // Zone Management
        case addZone
        case removeZone
        case collapseToOneZone
        case clearOrResetZones
        case clearOrResetZonesAtCursor

        // Window Actions
        case minimizeActiveWindow
        case minimizeWindowOrRemoveZoneAtCursor

        // Targeting
        case toggleTargetZoneWithFocusedWindow

        // Window Switchers
        case showLauncher
        case showCmdTab
        case showCmdTabCurrentApp

        // WinShot Snapshots
        case showWinShotChooser
        case saveWinShotSnapshot

        // Developer
        case captureTimeTravelLogs

        var displayName: String {
            switch self {
            // Zone Management
            case .addZone: return "Add Zone"
            case .removeZone: return "Remove Zone"
            case .collapseToOneZone: return "Collapse to One Zone"
            case .clearOrResetZones: return "Clear/Reset Zones (Active Display)"
            case .clearOrResetZonesAtCursor: return "Clear/Reset Zones (Cursor Display)"
            // Window Actions
            case .minimizeActiveWindow: return "Minimize Focused Window"
            case .minimizeWindowOrRemoveZoneAtCursor: return "Minimize/Remove Zone at Cursor"
            // Targeting
            case .toggleTargetZoneWithFocusedWindow: return "Toggle Destination w/ Focused Window"
            // Window Switchers
            case .showLauncher: return "Show Launcher"
            case .showCmdTab: return "CmdTab Window Switcher"
            case .showCmdTabCurrentApp: return "CmdTab (Current App Only)"
            // WinShot Snapshots
            case .showWinShotChooser: return "Show WinShot Switcher"
            case .saveWinShotSnapshot: return "Save WinShot Snapshot"
            // Developer
            case .captureTimeTravelLogs: return "Capture Time-Travel Logs"
            }
        }

        var defaultShortcut: KeyboardShortcut {
            let cmdCtrl = UInt32(cmdKey | controlKey)
            let cmdCtrlShift = UInt32(cmdKey | controlKey | shiftKey)
            let cmdOnly = UInt32(cmdKey)

            switch self {
            // Zone Management
            case .addZone:
                return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Equal), modifiers: cmdCtrl)
            case .removeZone:
                return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Minus), modifiers: cmdCtrl)
            case .collapseToOneZone:
                return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_0), modifiers: cmdCtrl)
            case .clearOrResetZones:
                return KeyboardShortcut(keyCode: UInt32(kVK_Escape), modifiers: cmdCtrl)
            case .clearOrResetZonesAtCursor:
                return KeyboardShortcut(keyCode: UInt32(kVK_Escape), modifiers: cmdCtrlShift)
            // Window Actions
            case .minimizeActiveWindow:
                return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: cmdOnly)
            case .minimizeWindowOrRemoveZoneAtCursor:
                return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: cmdCtrl)
            // Targeting
            case .toggleTargetZoneWithFocusedWindow:
                return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Backslash), modifiers: cmdCtrl)
            // Window Switchers
            case .showLauncher:
                return KeyboardShortcut(keyCode: UInt32(kVK_Space), modifiers: cmdCtrl)
            case .showCmdTab:
                return KeyboardShortcut(keyCode: UInt32(kVK_Tab), modifiers: cmdOnly)
            case .showCmdTabCurrentApp:
                return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Grave), modifiers: cmdOnly)
            // WinShot Snapshots
            case .showWinShotChooser:
                return KeyboardShortcut(keyCode: UInt32(kVK_Tab), modifiers: cmdCtrl)
            case .saveWinShotSnapshot:
                return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Slash), modifiers: cmdCtrl)
            // Developer
            case .captureTimeTravelLogs:
                return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Z), modifiers: cmdCtrl)
            }
        }

        /// Actions that engage on a chord and commit when the modifiers are released (the CmdTab and
        /// WinShot choosers). They require at least one modifier — a modifier-free key has no
        /// release to detect — so a bare function key isn't accepted as a binding for these.
        var requiresModifier: Bool {
            switch self {
            case .showCmdTab, .showCmdTabCurrentApp, .showWinShotChooser:
                return true
            default:
                return false
            }
        }

        /// Key codes for the function keys (F1–F12), which may be bound without a modifier — except
        /// for `requiresModifier` actions (see `accepts`).
        static let functionKeyCodes: Set<Int> = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
            kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        ]

        /// The Carbon modifier bits Zonogy recognizes — the only ones the runtime release monitors
        /// map (see `KeyboardShortcut.cgEventFlags` / `nsEventModifierFlags`).
        static let recognizedModifierMask = UInt32(cmdKey | controlKey | optionKey | shiftKey)

        /// Whether `keyCode` + Carbon `modifiers` is an acceptable binding for this action. Shared by
        /// the shortcut recorder and the load path so a stored or hand-edited shortcut can't leave a
        /// hold-to-commit action with no modifier to release. Only recognized modifier bits count, so
        /// stray/unmapped bits (e.g. caps-lock) don't masquerade as a real modifier.
        func accepts(keyCode: Int, modifiers: UInt32) -> Bool {
            if modifiers & Self.recognizedModifierMask != 0 { return true }
            return Self.functionKeyCodes.contains(keyCode) && !requiresModifier
        }
    }

    private struct StoredPreferences: Codable {
        var shortcuts: [String: KeyboardShortcut]
        var clearedActions: [String]
    }

    /// Actions that are disabled by default (no shortcut assigned out of the box).
    /// All actions have a default shortcut out of the box.
    private static let defaultClearedActions: Set<ShortcutAction> = []

    @Published private(set) var shortcuts: [ShortcutAction: KeyboardShortcut] = [:]
    @Published private(set) var clearedActions: Set<ShortcutAction> = []
    private let preferencesURL: URL

    var onShortcutsChanged: (() -> Void)?

    private init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Zonogy")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.preferencesURL = appSupport.appendingPathComponent("shortcuts.json")

        loadShortcuts()
    }

    func shortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        if clearedActions.contains(action) {
            return nil
        }
        if let customShortcut = shortcuts[action] {
            return customShortcut
        }
        return action.defaultShortcut
    }

    func setShortcut(_ shortcut: KeyboardShortcut, for action: ShortcutAction) {
        clearedActions.remove(action)
        shortcuts[action] = shortcut
        saveShortcuts()
        onShortcutsChanged?()
    }

    func clearShortcut(for action: ShortcutAction) {
        shortcuts.removeValue(forKey: action)
        clearedActions.insert(action)
        saveShortcuts()
        onShortcutsChanged?()
    }

    func resetToDefault(action: ShortcutAction) {
        shortcuts.removeValue(forKey: action)
        // Restore default cleared state if applicable
        if Self.defaultClearedActions.contains(action) {
            clearedActions.insert(action)
        } else {
            clearedActions.remove(action)
        }
        saveShortcuts()
        onShortcutsChanged?()
    }

    func resetAllToDefaults() {
        shortcuts.removeAll()
        clearedActions = Self.defaultClearedActions
        saveShortcuts()
        onShortcutsChanged?()
    }

    func isCleared(_ action: ShortcutAction) -> Bool {
        clearedActions.contains(action)
    }

    func isCustomized(_ action: ShortcutAction) -> Bool {
        shortcuts[action] != nil
    }

    func action(for shortcut: KeyboardShortcut) -> ShortcutAction? {
        for action in ShortcutAction.allCases {
            if let currentShortcut = self.shortcut(for: action), currentShortcut == shortcut {
                return action
            }
        }
        return nil
    }

    private func loadShortcuts() {
        guard FileManager.default.fileExists(atPath: preferencesURL.path),
              let data = try? Data(contentsOf: preferencesURL),
              let stored = try? JSONDecoder().decode(StoredPreferences.self, from: data) else {
            Logger.debug("No valid stored keyboard shortcuts found, resetting to defaults")
            shortcuts.removeAll()
            clearedActions = Self.defaultClearedActions
            saveShortcuts()
            return
        }

        for (key, shortcut) in stored.shortcuts {
            guard let action = ShortcutAction(rawValue: key) else { continue }
            // Drop a stored/hand-edited binding that's invalid for this action (e.g. a modifier-free
            // key on a hold-to-commit action), so it falls back to the action's default.
            guard action.accepts(keyCode: Int(shortcut.keyCode), modifiers: shortcut.modifiers) else {
                Logger.debug("Ignoring invalid stored shortcut for \(action.rawValue): no modifier for a hold-to-commit action")
                continue
            }
            shortcuts[action] = shortcut
        }

        for key in stored.clearedActions {
            if let action = ShortcutAction(rawValue: key) {
                clearedActions.insert(action)
            }
        }

        Logger.debug("Loaded \(shortcuts.count) custom shortcuts, \(clearedActions.count) cleared")
    }

    private func saveShortcuts() {
        var stored = StoredPreferences(shortcuts: [:], clearedActions: [])
        for (action, shortcut) in shortcuts {
            stored.shortcuts[action.rawValue] = shortcut
        }
        stored.clearedActions = clearedActions.map { $0.rawValue }

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
