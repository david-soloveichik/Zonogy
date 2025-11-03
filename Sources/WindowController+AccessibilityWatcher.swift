import ApplicationServices

/// Bridges AccessibilityWatcher delegate callbacks back to the owning WindowController

extension WindowController: AccessibilityWatcherDelegate {
    func accessibilityWatcher(_ watcher: AccessibilityWatcher, didReceive notification: CFString, element: AXUIElement) {
        handleAXNotification(element: element, notification: notification)
    }
}
