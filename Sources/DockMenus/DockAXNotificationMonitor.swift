import AppKit
import ApplicationServices

/// Observes Dock Accessibility notifications and emits change events without polling.
final class DockAXNotificationMonitor {
    struct Event: Equatable {
        let notification: String
        /// The AXFrame of the AXList when AXSelectedChildrenChanged fires on an AXList element.
        let listFrame: CGRect?
        /// The AXFrame of the first selected dock item (if available). Used to compute the offset
        /// between the AXList frame and actual dock item bounds.
        let itemFrame: CGRect?
    }

    private static let dockBundleIdentifier = "com.apple.dock"

    var onEvent: ((Event) -> Void)?

    /// Called when hover changes: a running app's Dock icon (event), a non-running app or non-app item (nil).
    /// Note: There is no reliable "cursor left Dock" signal from AX notifications. See SPECIFICATION-DOCKMENUS.md.
    var onAppHover: ((DockMenuHoverEvent?) -> Void)?

    /// The Dock's process ID (set when monitoring starts, nil when stopped).
    private(set) var dockPid: pid_t?

    private var observer: AXObserver?
    private var observedElements: [AXUIElement] = []
    private var runLoopSource: CFRunLoopSource?

    func start() {
        DispatchQueue.main.async { [weak self] in
            self?.startOnMain()
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.stopOnMain()
        }
    }

    private func startOnMain() {
        stopOnMain()

        guard AXIsProcessTrusted() else {
            Logger.debug("DockAXNotificationMonitor: missing Accessibility permission; cannot observe Dock notifications")
            return
        }

        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleIdentifier)
            .first?
            .processIdentifier else {
            Logger.debug("DockAXNotificationMonitor: Dock process not found")
            return
        }

        self.dockPid = pid

        var observer: AXObserver?
        let status = AXObserverCreate(pid, Self.axObserverCallback, &observer)
        guard status == .success, let observer else {
            Logger.debug("DockAXNotificationMonitor: AXObserverCreate failed (status=\(status.rawValue))")
            return
        }

        self.observer = observer

        let source = AXObserverGetRunLoopSource(observer)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        let appElement = AXUIElementCreateApplication(pid)
        var elementsToObserve: [AXUIElement] = [appElement]
        elementsToObserve.append(contentsOf: findDockListElements(appElement: appElement))

        elementsToObserve = dedupeElements(elementsToObserve)

        let notifications: [CFString] = [
            kAXSelectedChildrenChangedNotification as CFString,
            kAXLayoutChangedNotification as CFString,
            kAXMovedNotification as CFString,
            kAXResizedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString
        ]

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for element in elementsToObserve {
            for notification in notifications {
                _ = AXObserverAddNotification(observer, element, notification, refcon)
            }
        }

        observedElements = elementsToObserve

        Logger.debug("DockAXNotificationMonitor: observing \(observedElements.count) element(s) for \(notifications.count) notification(s)")
    }

    private func stopOnMain() {
        if let observer {
            let notifications: [CFString] = [
                kAXSelectedChildrenChangedNotification as CFString,
                kAXLayoutChangedNotification as CFString,
                kAXMovedNotification as CFString,
                kAXResizedNotification as CFString,
                kAXUIElementDestroyedNotification as CFString
            ]
            for element in observedElements {
                for notification in notifications {
                    _ = AXObserverRemoveNotification(observer, element, notification)
                }
            }

            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            }
        }

        observer = nil
        observedElements = []
        runLoopSource = nil
        dockPid = nil
    }

    private static let axObserverCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<DockAXNotificationMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handleAXNotification(element: element, notification: notification as String)
    }

    private func handleAXNotification(element: AXUIElement, notification: String) {
        var listFrame: CGRect?
        var itemFrame: CGRect?

        if notification == (kAXSelectedChildrenChangedNotification as String) {
            let role = axStringAttribute(element: element, attribute: kAXRoleAttribute as CFString) ?? "?"
            Logger.debug("DockAXNotificationMonitor: AXSelectedChildrenChanged role=\(role)")

            if role == (kAXListRole as String) {
                listFrame = axFrameAttribute(element: element)
                let orientationStr = axStringAttribute(element: element, attribute: kAXOrientationAttribute as CFString) ?? "nil"
                Logger.debug("DockAXNotificationMonitor: AXList frame=\(listFrame.map { String(describing: $0) } ?? "nil") orientation=\(orientationStr)")

                // Check first selected child for AXApplicationDockItem
                let selectedChildren = axSelectedChildren(of: element)
                guard let firstSelected = selectedChildren.first else {
                    // No selected children - this does NOT reliably indicate cursor left the Dock.
                    // AXSelectedChildrenChanged with empty selection fires at unpredictable times.
                    // Panel dismissal must rely on mouse tracking, not this signal.
                    return
                }

                // Get item frame for any selected dock item (used to compute list-to-item offset)
                itemFrame = axFrameAttribute(element: firstSelected)

                let subrole = axStringAttribute(element: firstSelected, attribute: kAXSubroleAttribute as CFString)
                if subrole == "AXApplicationDockItem" {
                    let url = axURLAttribute(element: firstSelected, attribute: kAXURLAttribute as CFString)
                    Logger.debug("DockAXNotificationMonitor: selected item is AXApplicationDockItem, URL=\(url?.absoluteString ?? "nil")")

                    // Emit hover event if this is a running app
                    if let appURL = url,
                       let listFrame,
                       let itemFrame,
                       let bundleId = bundleIdentifier(for: appURL),
                       isAppRunning(bundleIdentifier: bundleId) {
                        let orientation: DockOrientation = (orientationStr == "AXVerticalOrientation") ? .vertical : .horizontal
                        let hoverEvent = DockMenuHoverEvent(
                            appURL: appURL,
                            bundleIdentifier: bundleId,
                            itemFrame: itemFrame,
                            listFrame: listFrame,
                            dockOrientation: orientation
                        )
                        Logger.debug("DockAXNotificationMonitor: emitting hover event for \(appURL.lastPathComponent)")
                        onAppHover?(hoverEvent)
                    } else {
                        // Not a running app or missing data
                        onAppHover?(nil)
                    }
                } else {
                    // Selected item is not an app (e.g., folder, separator)
                    onAppHover?(nil)
                }
            }
        }
        onEvent?(Event(notification: notification, listFrame: listFrame, itemFrame: itemFrame))
    }

    private func bundleIdentifier(for appURL: URL) -> String? {
        guard let bundle = Bundle(url: appURL) else { return nil }
        return bundle.bundleIdentifier
    }

    private func isAppRunning(bundleIdentifier: String) -> Bool {
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    private func axFrameAttribute(element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func findDockListElements(appElement: AXUIElement) -> [AXUIElement] {
        struct Item {
            let element: AXUIElement
            let depth: Int
        }

        var results: [AXUIElement] = []
        var queue: [Item] = [Item(element: appElement, depth: 0)]
        var visitedHashes: Set<CFHashCode> = []
        visitedHashes.insert(CFHash(appElement))

        let maxNodes = 250
        let maxDepth = 8

        while !queue.isEmpty, visitedHashes.count < maxNodes {
            let item = queue.removeFirst()
            let role = axStringAttribute(element: item.element, attribute: kAXRoleAttribute as CFString)

            if role == (kAXListRole as String) {
                results.append(item.element)
            }

            guard item.depth < maxDepth else { continue }

            for child in axChildren(of: item.element) {
                let hash = CFHash(child)
                guard !visitedHashes.contains(hash) else { continue }
                visitedHashes.insert(hash)
                queue.append(Item(element: child, depth: item.depth + 1))
            }
        }

        return results
    }

    private func dedupeElements(_ elements: [AXUIElement]) -> [AXUIElement] {
        var seenHashes: Set<CFHashCode> = []
        var output: [AXUIElement] = []
        output.reserveCapacity(elements.count)
        for element in elements {
            let hash = CFHash(element)
            guard !seenHashes.contains(hash) else { continue }
            seenHashes.insert(hash)
            output.append(element)
        }
        return output
    }

    private func axChildren(of element: AXUIElement) -> [AXUIElement] {
        return axElementArrayAttribute(element: element, attribute: kAXChildrenAttribute as CFString)
    }

    private func axSelectedChildren(of element: AXUIElement) -> [AXUIElement] {
        return axElementArrayAttribute(element: element, attribute: kAXSelectedChildrenAttribute as CFString)
    }

    private func axElementArrayAttribute(element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let value else {
            return []
        }

        let anyArray: [Any]
        if let array = value as? [Any] {
            anyArray = array
        } else if let array = value as? NSArray {
            anyArray = array.compactMap { $0 }
        } else {
            return []
        }

        return anyArray.compactMap { item in
            let cf = item as CFTypeRef
            guard CFGetTypeID(cf) == AXUIElementGetTypeID() else {
                return nil
            }
            return unsafeBitCast(cf, to: AXUIElement.self)
        }
    }

    private func axStringAttribute(element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let value else {
            return nil
        }
        return value as? String
    }

    private func axURLAttribute(element: AXUIElement, attribute: CFString) -> URL? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let value else {
            return nil
        }
        return value as? URL
    }
}
