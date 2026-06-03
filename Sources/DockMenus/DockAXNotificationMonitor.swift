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

    /// Notifications registered on every observed Dock element. Shared by setup and teardown so
    /// the two lists can't drift apart.
    private static let observedNotifications: [CFString] = [
        kAXSelectedChildrenChangedNotification as CFString,
        kAXLayoutChangedNotification as CFString,
        kAXMovedNotification as CFString,
        kAXResizedNotification as CFString,
        kAXUIElementDestroyedNotification as CFString
    ]

    var onEvent: ((Event) -> Void)?

    /// Called when hover changes: a running app's Dock icon (event), a non-running app or non-app item (nil).
    /// Note: There is no reliable "cursor left Dock" signal from AX notifications. See SPECIFICATION-DOCKMENUS.md.
    var onAppHover: ((DockMenuHoverEvent?) -> Void)?

    /// The Dock's process ID (set when monitoring starts, nil when stopped).
    private(set) var dockPid: pid_t?

    private var observer: AXObserver?
    private var observedElements: [AXUIElement] = []
    private var runLoopSource: CFRunLoopSource?

    /// Debounce for re-establishing the observer after the Dock rebuilds its accessibility
    /// hierarchy. `AXUIElementDestroyed` notifications on observed Dock elements arrive in bursts,
    /// so we coalesce them into a single re-discovery + re-registration pass.
    private var reestablishWorkItem: DispatchWorkItem?
    private static let reestablishDebounceInterval: TimeInterval = 0.5

    func start() {
        DispatchQueue.main.async { [weak self] in
            self?.startOnMain()
        }
    }

    func stop() {
        // Retain self until teardown runs. DockFrameMonitor drops its only strong reference
        // immediately after calling stop(), so a `[weak self]` hop could let the monitor deallocate
        // before stopOnMain() removes the run-loop source — leaving it installed on the main run
        // loop with a dangling refcon (a use-after-free on the next Dock notification).
        DispatchQueue.main.async {
            self.stopOnMain()
        }
    }

    /// Re-discovers the Dock's AXList element(s) and re-registers observers.
    ///
    /// The Dock can rebuild its accessibility hierarchy in place (same process) on wake or display
    /// reconfiguration. When it does, our cached AXList element goes "stale but alive": it keeps
    /// firing `AXSelectedChildrenChanged` and still answers position/size, but its
    /// `AXSelectedChildren` query returns empty on hover, so no hover events are emitted and no
    /// DockMenu appears. Binding to the freshly-discovered element restores hover detection.
    /// No-op if monitoring isn't currently active.
    func reestablish(reason: String) {
        DispatchQueue.main.async { [weak self] in
            self?.performReestablish(reason: reason)
        }
    }

    /// A fully-built but not-yet-activated observer. Built off to the side so a re-establish can
    /// swap to it only after success — never tearing down a working observer and then failing,
    /// which would strand DockMenus with no observer during the wake/display churn re-establish
    /// targets.
    private struct Installation {
        let observer: AXObserver
        let runLoopSource: CFRunLoopSource
        let observedElements: [AXUIElement]
        let dockPid: pid_t
    }

    private func startOnMain() {
        stopOnMain()
        guard let installation = buildInstallation() else { return }
        activate(installation)
    }

    /// Builds a fresh Dock observer and registers notifications on it, without yet scheduling its
    /// run-loop source (so it delivers no callbacks until `activate`). Returns nil — leaving any
    /// existing observer untouched — when Accessibility or the Dock is currently unavailable, or
    /// when no Dock `AXList` can actually be observed for hover. The hover signal
    /// (`AXSelectedChildrenChanged`) only arrives from `AXList` elements, so an app-element-only
    /// installation would be inert; reporting failure (which can be transient while the Dock
    /// rebuilds its hierarchy) keeps the existing observer instead of swapping in a dud.
    private func buildInstallation() -> Installation? {
        guard AXIsProcessTrusted() else {
            Logger.debug("DockAXNotificationMonitor: missing Accessibility permission; cannot observe Dock notifications")
            return nil
        }

        guard let pid = ApplicationIdentity.runningApplication(bundleIdentifier: Self.dockBundleIdentifier)?
            .processIdentifier else {
            Logger.debug("DockAXNotificationMonitor: Dock process not found")
            return nil
        }

        var observer: AXObserver?
        let status = AXCall.createObserver(pid, Self.axObserverCallback, &observer)
        guard status == .success, let observer else {
            Logger.debug("DockAXNotificationMonitor: AXObserverCreate failed (status=\(status.rawValue))")
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid)
        let listElements = findDockListElements(appElement: appElement)
        guard !listElements.isEmpty else {
            Logger.debug("DockAXNotificationMonitor: no Dock AXList found; treating as build failure")
            return nil
        }

        let elementsToObserve = dedupeElements([appElement] + listElements)
        let listHashes = Set(listElements.map { CFHash($0) })
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Register every notification on every element, but require the hover-critical
        // `AXSelectedChildrenChanged` to register on at least one `AXList` — otherwise the observer
        // can't produce DockMenus and we should not adopt it.
        var registeredHoverOnList = false
        for element in elementsToObserve {
            let isList = listHashes.contains(CFHash(element))
            for notification in Self.observedNotifications {
                let addStatus = AXCall.addObserverNotification(observer, element, notification, refcon)
                if isList,
                   notification == (kAXSelectedChildrenChangedNotification as CFString),
                   addStatus == .success || addStatus == .notificationAlreadyRegistered {
                    registeredHoverOnList = true
                }
            }
        }

        guard registeredHoverOnList else {
            Logger.debug("DockAXNotificationMonitor: failed to register hover notification on any Dock AXList; treating as build failure")
            return nil
        }

        return Installation(
            observer: observer,
            runLoopSource: AXObserverGetRunLoopSource(observer),
            observedElements: elementsToObserve,
            dockPid: pid
        )
    }

    /// Makes a freshly-built observer the active one and begins delivering its callbacks.
    /// Any previously-active observer must already be torn down (via `stopOnMain()`).
    private func activate(_ installation: Installation) {
        observer = installation.observer
        runLoopSource = installation.runLoopSource
        observedElements = installation.observedElements
        dockPid = installation.dockPid
        CFRunLoopAddSource(CFRunLoopGetMain(), installation.runLoopSource, .defaultMode)
        Logger.debug("DockAXNotificationMonitor: observing \(observedElements.count) element(s) for \(Self.observedNotifications.count) notification(s)")
    }

    private func stopOnMain() {
        if let observer {
            for element in observedElements {
                for notification in Self.observedNotifications {
                    _ = AXCall.removeObserverNotification(observer, element, notification)
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

        // A deliberate stop must not be followed by a queued re-establish.
        reestablishWorkItem?.cancel()
        reestablishWorkItem = nil
    }

    /// Coalesces bursty `AXUIElementDestroyed` notifications into a single re-establish pass.
    private func scheduleDebouncedReestablish(reason: String) {
        reestablishWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performReestablish(reason: reason)
        }
        reestablishWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reestablishDebounceInterval, execute: workItem)
    }

    /// Rebinds the observer to the Dock's current accessibility tree. Builds the replacement first
    /// and swaps only on success, so a transient failure during wake/display churn leaves the
    /// existing observer in place rather than stranding DockMenus with none. No-op after a
    /// deliberate `stop()` (there is then no active observer to refresh).
    private func performReestablish(reason: String) {
        guard observer != nil else {
            Logger.debug("DockAXNotificationMonitor: skipping re-establish, not monitoring (reason: \(reason))")
            return
        }
        guard let installation = buildInstallation() else {
            Logger.debug("DockAXNotificationMonitor: re-establish deferred — Dock observer unavailable, keeping existing (reason: \(reason))")
            return
        }
        Logger.debug("DockAXNotificationMonitor: re-establishing Dock observer (reason: \(reason))")
        stopOnMain()
        activate(installation)
    }

    private static let axObserverCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<DockAXNotificationMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handleAXNotification(element: element, notification: notification as String)
    }

    private func handleAXNotification(element: AXUIElement, notification: String) {
        if notification == (kAXUIElementDestroyedNotification as String) {
            // An observed Dock element was torn down — the Dock rebuilt its accessibility hierarchy.
            // Our cached AXList reference is now (or will soon become) stale, so rebind to the new tree.
            Logger.debug("DockAXNotificationMonitor: observed Dock element destroyed; scheduling re-establish")
            scheduleDebouncedReestablish(reason: "element-destroyed")
        }

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
                       let bundleId = ApplicationIdentity.bundleIdentifier(forApplicationURL: appURL),
                       ApplicationIdentity.isRunning(bundleIdentifier: bundleId) {
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

    private func axFrameAttribute(element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXCall.copyAttribute(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXCall.copyAttribute(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
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
        let status = AXCall.copyAttribute(element, attribute, &value)
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
        let status = AXCall.copyAttribute(element, attribute, &value)
        guard status == .success, let value else {
            return nil
        }
        return value as? String
    }

    private func axURLAttribute(element: AXUIElement, attribute: CFString) -> URL? {
        var value: CFTypeRef?
        let status = AXCall.copyAttribute(element, attribute, &value)
        guard status == .success, let value else {
            return nil
        }
        return value as? URL
    }
}
