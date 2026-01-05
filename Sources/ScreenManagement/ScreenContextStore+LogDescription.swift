import AppKit

/// Screen identifier formatting helpers for consistent log output.
extension ScreenContextStore {
    private static let maxDisplayIdToIncludeInLogs: CGDirectDisplayID = 1000

    func logDescription(for displayId: CGDirectDisplayID) -> String {
        guard let index = screenIndex(for: displayId) else {
            return "displayId \(displayId)"
        }
        return ScreenContextStore.logDescription(for: displayId, screenIndex: index)
    }

    static func logDescription(for displayId: CGDirectDisplayID) -> String {
        guard let index = screenIndex(for: displayId) else {
            return "displayId \(displayId)"
        }
        return logDescription(for: displayId, screenIndex: index)
    }

    private static func logDescription(for displayId: CGDirectDisplayID, screenIndex: Int) -> String {
        if displayId < maxDisplayIdToIncludeInLogs, screenIndex != Int(displayId) {
            return "screen \(screenIndex) (displayId \(displayId))"
        }
        return "screen \(screenIndex)"
    }
}
