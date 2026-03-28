import AppKit

/// Tracks Control-Command external drags over managed tiling zones and presents zone overlays.
protocol ExternalZoneDropInterceptorHost: AnyObject, DragOverlayExternalDropDelegate {
    var isManagedWindowDragInProgress: Bool { get }
    func currentCursorAccessibilityPoint() -> CGPoint?
    func noteExternalDragSourceBundleIdentifierIfNeeded()
    func shouldApplyControlCommandExternalDragGestures() -> Bool
    func shouldBeginExternalZoneDropInterception(cursorPoint: CGPoint) -> Bool
    func resolveInterceptedExternalDropZoneKey(cursorPoint: CGPoint) -> ZoneKey?
    func externalDropOverlayDescriptors() -> [ZoneOverlayDescriptor]
    func suspendPlaceholderExternalDragOverlay(reason: String)
    func resumePlaceholderExternalDragOverlayIfNeeded(cursorPoint: CGPoint?)
    func resetObservedPlaceholderExternalDrag(reason: String)
    func resetExternalDragSourceBundleIdentifier(reason: String)
}

final class ExternalZoneDropInterceptor {
    private enum Constants {
        static let monitoredEvents: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp, .flagsChanged]
    }

    weak var host: ExternalZoneDropInterceptorHost?

    private let overlayManager: DragOverlayManager
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isInterceptionActive = false
    private var pendingMouseUpTearDownWorkItem: DispatchWorkItem?

    init(host: ExternalZoneDropInterceptorHost) {
        self.host = host
        self.overlayManager = DragOverlayManager(externalDropDelegate: host, windowLevel: .statusBar)
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else {
            return
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Constants.monitoredEvents) { [weak self] event in
            self?.handle(event: event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Constants.monitoredEvents) { [weak self] event in
            self?.handle(event: event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        pendingMouseUpTearDownWorkItem?.cancel()
        pendingMouseUpTearDownWorkItem = nil
        tearDownOverlays()
        host?.suspendPlaceholderExternalDragOverlay(reason: "external-zone-drop-interceptor-stop")
        host?.resetObservedPlaceholderExternalDrag(reason: "external-zone-drop-interceptor-stop")
        host?.resetExternalDragSourceBundleIdentifier(reason: "external-zone-drop-interceptor-stop")
    }

    private func handle(event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            refreshInterceptionState(allowBeginInterception: true)
        case .flagsChanged:
            refreshInterceptionState(allowBeginInterception: false)
        case .leftMouseUp:
            scheduleMouseUpTearDown()
        default:
            break
        }
    }

    private func refreshInterceptionState(allowBeginInterception: Bool) {
        pendingMouseUpTearDownWorkItem?.cancel()
        pendingMouseUpTearDownWorkItem = nil

        let cursorPoint = host?.currentCursorAccessibilityPoint()

        guard let host,
              !host.isManagedWindowDragInProgress,
              MouseButtons.isLeftMouseButtonDown(),
              NSEvent.modifierFlags.contains(.command),
              NSEvent.modifierFlags.contains(.control),
              ExternalDropParser.canAccept(NSPasteboard(name: .drag)),
              let cursorPoint else {
            tearDownOverlays()
            host?.resumePlaceholderExternalDragOverlayIfNeeded(cursorPoint: cursorPoint)
            return
        }

        host.noteExternalDragSourceBundleIdentifierIfNeeded()
        guard host.shouldApplyControlCommandExternalDragGestures() else {
            tearDownOverlays()
            host.resumePlaceholderExternalDragOverlayIfNeeded(cursorPoint: cursorPoint)
            return
        }

        if !isInterceptionActive {
            guard allowBeginInterception else {
                return
            }
            guard host.shouldBeginExternalZoneDropInterception(cursorPoint: cursorPoint) else {
                return
            }

            overlayManager.present(over: host.externalDropOverlayDescriptors())
            isInterceptionActive = true
            Logger.debug("External zone drop interception began")
        }

        host.suspendPlaceholderExternalDragOverlay(reason: "control-command-external-drop")
        overlayManager.updateHighlight(to: host.resolveInterceptedExternalDropZoneKey(cursorPoint: cursorPoint))
    }

    private func scheduleMouseUpTearDown() {
        pendingMouseUpTearDownWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingMouseUpTearDownWorkItem = nil
            self?.tearDownOverlays()
            self?.host?.suspendPlaceholderExternalDragOverlay(reason: "external-zone-drop-mouse-up")
            self?.host?.resetObservedPlaceholderExternalDrag(reason: "external-zone-drop-mouse-up")
            self?.host?.resetExternalDragSourceBundleIdentifier(reason: "external-zone-drop-mouse-up")
        }
        pendingMouseUpTearDownWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func tearDownOverlays() {
        guard isInterceptionActive else {
            return
        }
        pendingMouseUpTearDownWorkItem?.cancel()
        pendingMouseUpTearDownWorkItem = nil
        overlayManager.tearDown()
        isInterceptionActive = false
        Logger.debug("External zone drop interception ended")
    }
}
