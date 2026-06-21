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

        // Target Navigation
        case navigateUp
        case navigateDown
        case navigateLeft
        case navigateRight
        case focusTargetedWindow
        case toggleTargetZoneWithFocusedWindow

        // Window Focus Navigation (these four share one modifier; see sharedModifierActionGroups)
        case focusWindowUp
        case focusWindowDown
        case focusWindowLeft
        case focusWindowRight

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
            case .clearOrResetZones: return "Clear/Reset Zones (Active Screen)"
            case .clearOrResetZonesAtCursor: return "Clear/Reset Zones (Cursor Screen)"
            // Window Actions
            case .minimizeActiveWindow: return "Minimize Focused Window"
            case .minimizeWindowOrRemoveZoneAtCursor: return "Minimize/Remove Zone at Cursor"
            // Target Navigation
            case .navigateUp: return "Destination Up"
            case .navigateDown: return "Destination Down"
            case .navigateLeft: return "Destination Left"
            case .navigateRight: return "Destination Right"
            case .focusTargetedWindow: return "Focus Destination Window"
            case .toggleTargetZoneWithFocusedWindow: return "Toggle Destination w/ Focused Window"
            // Window Focus Navigation
            case .focusWindowUp: return "Focus Window Up"
            case .focusWindowDown: return "Focus Window Down"
            case .focusWindowLeft: return "Focus Window Left"
            case .focusWindowRight: return "Focus Window Right"
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
            // Target Navigation (Vim direction keys: H/J/K/L = left/down/up/right)
            case .navigateUp:
                return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: cmdCtrl)
            case .navigateDown:
                return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: cmdCtrl)
            case .navigateLeft:
                return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: cmdCtrl)
            case .navigateRight:
                return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: cmdCtrl)
            case .focusTargetedWindow:
                return KeyboardShortcut(keyCode: UInt32(kVK_Return), modifiers: cmdCtrl)
            case .toggleTargetZoneWithFocusedWindow:
                return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Backslash), modifiers: cmdCtrl)
            // Window Focus Navigation (arrow keys; all four share one modifier)
            case .focusWindowUp:
                return KeyboardShortcut(keyCode: UInt32(kVK_UpArrow), modifiers: cmdCtrl)
            case .focusWindowDown:
                return KeyboardShortcut(keyCode: UInt32(kVK_DownArrow), modifiers: cmdCtrl)
            case .focusWindowLeft:
                return KeyboardShortcut(keyCode: UInt32(kVK_LeftArrow), modifiers: cmdCtrl)
            case .focusWindowRight:
                return KeyboardShortcut(keyCode: UInt32(kVK_RightArrow), modifiers: cmdCtrl)
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
    }

    private struct StoredPreferences: Codable {
        var shortcuts: [String: KeyboardShortcut]
        var clearedActions: [String]
    }

    /// Actions that are disabled by default (no shortcut assigned out of the box).
    /// All actions have a default shortcut out of the box: "Focus Destination Window" defaults to
    /// Control-Command-Return and "Toggle Destination w/ Focused Window" to Control-Command-\.
    private static let defaultClearedActions: Set<ShortcutAction> = []

    /// Groups of actions that must share a single modifier combination. The four window-focus
    /// directions are linked because that gesture focuses on modifier release, which a per-direction
    /// modifier could never detect. Editing one direction's modifier propagates it to the others
    /// (each keeps its own key).
    private static let sharedModifierActionGroups: [[ShortcutAction]] = [
        [.focusWindowUp, .focusWindowDown, .focusWindowLeft, .focusWindowRight],
    ]

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
        enforceSharedModifiers(anchoredBy: action)
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
        enforceSharedModifiers(anchoredBy: action)
        saveShortcuts()
        onShortcutsChanged?()
    }

    /// Keep every member of `action`'s shared-modifier group on the same modifiers (preserving each
    /// member's key), so editing or resetting one window-focus direction re-syncs the others. No-op
    /// for ungrouped actions or when the anchor itself has no shortcut.
    private func enforceSharedModifiers(anchoredBy action: ShortcutAction) {
        guard let group = Self.sharedModifierActionGroups.first(where: { $0.contains(action) }),
              let modifiers = shortcut(for: action)?.modifiers else {
            return
        }
        for member in group where member != action {
            guard !clearedActions.contains(member) else { continue }
            let keyCode = (shortcuts[member] ?? member.defaultShortcut).keyCode
            let updated = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
            if shortcuts[member] != updated {
                shortcuts[member] = updated
            }
        }
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
            if let action = ShortcutAction(rawValue: key) {
                shortcuts[action] = shortcut
            }
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
