import AppKit
import ApplicationServices

/// Observes Dock Accessibility notifications and emits change events without polling. Rebinds the
/// observer when the Dock rebuilds its accessibility tree in place, and when the Dock process
/// itself crashes or is relaunched (its observer is bound to a specific Dock pid).
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

    /// True while monitoring is requested (between `start()` and `stop()`), independent of whether
    /// an observer is currently bound. Gates establish attempts so retries stop after a deliberate
    /// stop, yet keep running across a Dock relaunch (when no observer is momentarily bound).
    private var isActive = false

    /// Watches the bound Dock process for exit (a crash, or `killall Dock`), so the pid-bound AX
    /// observer rebinds to the relaunched Dock. A process-exit source is the only reliable signal
    /// here: NSWorkspace launch/terminate notifications are not posted for the Dock (a background
    /// `LSUIElement` agent), and the dead process's AX observer goes silently inert. Recreated by
    /// `activate` for each newly bound Dock pid; cancelled in `teardownObserver`.
    private var dockExitSource: DispatchSourceProcess?

    /// Coalesces re-establish triggers and spaces out retries into a single delayed attempt.
    /// Triggers arrive in bursts (`AXUIElementDestroyed`) or before the Dock is observable (a
    /// freshly relaunched Dock has not built its accessibility tree yet), so we collapse them into
    /// one delayed attempt and retry a bounded number of times until the Dock's `AXList` is found.
    private var establishWorkItem: DispatchWorkItem?
    private var establishAttemptsRemaining = 0
    private static let establishRetryInterval: TimeInterval = 0.5
    private static let maxEstablishAttempts = 8

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
            self?.beginEstablish(reason: reason, immediate: true)
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
        isActive = true
        beginEstablish(reason: "start", immediate: true)
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
        watchForDockExit(pid: installation.dockPid)
        Logger.debug("DockAXNotificationMonitor: observing \(observedElements.count) element(s) for \(Self.observedNotifications.count) notification(s)")
    }

    private func stopOnMain() {
        // A deliberate stop ends monitoring: drop the active flag, cancel any pending establish
        // retry, and tear down the observer (which also cancels the Dock exit watcher).
        isActive = false
        establishWorkItem?.cancel()
        establishWorkItem = nil
        teardownObserver()
    }

    /// Removes notification registrations, the run-loop source, and the Dock exit watcher for the
    /// current observer, if any. Mechanical teardown only — it does not change `isActive` or pending
    /// retries, so it is safe to call right before swapping in a freshly-built observer.
    private func teardownObserver() {
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

        dockExitSource?.cancel()
        dockExitSource = nil
        observer = nil
        observedElements = []
        runLoopSource = nil
        dockPid = nil
    }

    /// (Re)binds the observer to the Dock's current accessibility tree, retrying a bounded number
    /// of times while the Dock is not yet observable (its tree is still being rebuilt, or a crashed
    /// Dock has not finished relaunching). Builds the replacement first and swaps only on success,
    /// so a transient failure leaves any existing observer in place rather than stranding DockMenus
    /// with none. No-op once monitoring has been deliberately stopped.
    /// - Parameter immediate: run the first attempt synchronously (start / wake / display refresh)
    ///   rather than after the coalescing delay (bursty `AXUIElementDestroyed` / Dock relaunch).
    private func beginEstablish(reason: String, immediate: Bool) {
        guard isActive else {
            Logger.debug("DockAXNotificationMonitor: skipping establish, not active (reason: \(reason))")
            return
        }
        // This call starts a fresh establish sequence, so supersede any pending attempt — otherwise
        // a queued retry could fire after an immediate establish succeeds and redundantly rebind.
        establishWorkItem?.cancel()
        establishWorkItem = nil
        establishAttemptsRemaining = Self.maxEstablishAttempts
        if immediate {
            attemptEstablish(reason: reason)
        } else {
            scheduleEstablishAttempt(reason: reason)
        }
    }

    /// Coalesces bursts of triggers (and spaces out retries) into a single delayed attempt.
    private func scheduleEstablishAttempt(reason: String) {
        establishWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.attemptEstablish(reason: reason)
        }
        establishWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.establishRetryInterval, execute: workItem)
    }

    private func attemptEstablish(reason: String) {
        guard isActive else { return }
        establishWorkItem = nil

        if let installation = buildInstallation() {
            teardownObserver()
            activate(installation)
            Logger.debug("DockAXNotificationMonitor: established Dock observer (reason: \(reason))")
            return
        }

        establishAttemptsRemaining -= 1
        guard establishAttemptsRemaining > 0 else {
            Logger.debug("DockAXNotificationMonitor: establish failed — Dock not observable, retries exhausted (reason: \(reason))")
            return
        }
        Logger.debug("DockAXNotificationMonitor: establish deferred — Dock not observable, will retry (reason: \(reason), attempts left: \(establishAttemptsRemaining))")
        scheduleEstablishAttempt(reason: reason)
    }

    // MARK: - Dock process lifecycle

    /// Installs a kqueue-backed watcher (`DispatchSourceProcess`) that fires when the bound Dock
    /// process exits — a crash, or `killall Dock`. This is the reliable signal that the pid the
    /// observer is bound to has died: NSWorkspace launch/terminate notifications are not posted for
    /// the Dock (a background `LSUIElement` agent), and the dead process's AX observer simply stops
    /// delivering callbacks (no `AXUIElementDestroyed` arrives). Runs on the main queue.
    private func watchForDockExit(pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            self?.handleDockExit(pid: pid)
        }
        dockExitSource = source
        source.resume()
    }

    private func handleDockExit(pid: pid_t) {
        // Only the currently bound Dock pid should trigger a rebind. The live source's pid always
        // equals `dockPid`; this guard makes that invariant explicit and ignores any stale exit from
        // a source we've already replaced, so it can't tear down a freshly-rebound observer.
        guard pid == dockPid else {
            Logger.debug("DockAXNotificationMonitor: ignoring stale Dock-exit for pid \(pid) (current dockPid \(dockPid.map { "\($0)" } ?? "nil"))")
            return
        }
        Logger.debug("DockAXNotificationMonitor: Dock process exited (pid \(pid)); re-establishing observer")
        // The observer (and this exit source) is bound to the now-dead pid; drop both, then rebind
        // once the relaunched Dock is observable. Retries bridge the gap while launchd respawns the
        // Dock and it rebuilds its accessibility tree.
        teardownObserver()
        beginEstablish(reason: "dock-exited", immediate: false)
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
            beginEstablish(reason: "element-destroyed", immediate: false)
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
