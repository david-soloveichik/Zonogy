import ApplicationServices

/// Central catalog of AX notifications used by WindowController observers
struct AccessibilityNotificationCatalog {
    static let windowNotifications: [CFString] = [
        kAXUIElementDestroyedNotification as CFString,
        kAXWindowMiniaturizedNotification as CFString,
        kAXWindowDeminiaturizedNotification as CFString,
        kAXMovedNotification as CFString,
        kAXResizedNotification as CFString
    ]

    static let applicationNotifications: [CFString] = [
        kAXWindowCreatedNotification as CFString,
        kAXFocusedWindowChangedNotification as CFString,
        kAXMainWindowChangedNotification as CFString,
        kAXUIElementDestroyedNotification as CFString
    ]
}
