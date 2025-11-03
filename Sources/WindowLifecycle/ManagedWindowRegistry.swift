/// Tracks managed windows and provides id allocation helpers for WindowController
final class ManagedWindowRegistry {
    private var nextIdentifier: Int = 1
    private var windowsById: [Int: ManagedWindow] = [:]

    func allocateIdentifier() -> Int {
        let identifier = nextIdentifier
        nextIdentifier += 1
        return identifier
    }

    func insert(_ window: ManagedWindow) {
        windowsById[window.windowId] = window
    }

    func update(_ window: ManagedWindow) {
        windowsById[window.windowId] = window
    }

    func window(withId identifier: Int) -> ManagedWindow? {
        windowsById[identifier]
    }

    @discardableResult
    func removeWindow(withId identifier: Int) -> ManagedWindow? {
        windowsById.removeValue(forKey: identifier)
    }

    func removeAll(where shouldRemove: (ManagedWindow) -> Bool) -> [ManagedWindow] {
        let identifiers = windowsById.compactMap { id, window in
            shouldRemove(window) ? id : nil
        }
        var removed: [ManagedWindow] = []
        for identifier in identifiers {
            if let window = windowsById.removeValue(forKey: identifier) {
                removed.append(window)
            }
        }
        return removed
    }

    func contains(where predicate: (ManagedWindow) -> Bool) -> Bool {
        windowsById.values.contains(where: predicate)
    }

    func first(where predicate: (ManagedWindow) -> Bool) -> ManagedWindow? {
        windowsById.values.first(where: predicate)
    }

    var allWindows: [ManagedWindow] {
        Array(windowsById.values)
    }
}
