import AppKit
import ApplicationServices

/// Observes Dock Accessibility notifications and emits change events without polling.
final class DockAXNotificationMonitor {
    struct Event: Equatable {
        let notification: String
    }

    var onEvent: ((Event) -> Void)?

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

        guard let dockPid = NSRunningApplication.runningApplications(withBundleIdentifier: DockWindowFrameDetector.dockBundleIdentifier)
            .first?
            .processIdentifier else {
            Logger.debug("DockAXNotificationMonitor: Dock process not found")
            return
        }

        var observer: AXObserver?
        let status = AXObserverCreate(dockPid, Self.axObserverCallback, &observer)
        guard status == .success, let observer else {
            Logger.debug("DockAXNotificationMonitor: AXObserverCreate failed (status=\(status.rawValue))")
            return
        }

        self.observer = observer

        let source = AXObserverGetRunLoopSource(observer)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        let appElement = AXUIElementCreateApplication(dockPid)
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
    }

    private static let axObserverCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<DockAXNotificationMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handleAXNotification(element: element, notification: notification as String)
    }

    private func handleAXNotification(element: AXUIElement, notification: String) {
        if notification == (kAXSelectedChildrenChangedNotification as String) {
            let role = axStringAttribute(element: element, attribute: kAXRoleAttribute as CFString) ?? "?"
            Logger.debug("DockAXNotificationMonitor: AXSelectedChildrenChanged role=\(role)")
        }
        onEvent?(Event(notification: notification))
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
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
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
}
