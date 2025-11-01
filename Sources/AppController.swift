import Foundation
import AppKit
import Carbon
import ApplicationServices

/// Main controller that coordinates all components
private let hotKeySignature: OSType = 0x4C415454 // 'LATT'

private func AppControllerHotKeyHandler(_ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return noErr }
    let controller = Unmanaged<AppController>.fromOpaque(userData).takeUnretainedValue()
    return controller.handleHotKeyEvent(event: event)
}

/// Main controller that coordinates all components
class AppController: NSObject, WindowControllerDelegate, ZoneIndicatorManagerDelegate {
    private struct ScreenContext {
        var descriptor: ScreenDescriptor
        let zoneController: ZoneController
    }

    private struct DragSession {
        let windowId: Int
        let originZoneKey: ZoneKey?
        let originScreenId: CGDirectDisplayID?
        let originFrame: CGRect
        var latestFrame: CGRect
        var hoveredZoneKey: ZoneKey?
        let beganAt: Date
    }

    private struct DropResult {
        let displacedWindow: ManagedWindow?
        let preferredScreenId: CGDirectDisplayID?
    }

    private struct ZoneEdgeMargins {
        var top: CGFloat
        var left: CGFloat
        var bottom: CGFloat
        var right: CGFloat
    }

    static let shared = AppController()

    private let windowController: WindowController
    private let configuration: Configuration
    private var screenContexts: [CGDirectDisplayID: ScreenContext] = [:]
    private var screenOrder: [CGDirectDisplayID] = []
    private let primaryScreenId: CGDirectDisplayID
    private let primaryScreenBounds: CGRect
    private var eventMonitors: [Any] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyEventHandler: EventHandlerRef?
    private let zoneMargin: CGFloat = 8
    private let edgeAlignmentTolerance: CGFloat = 0.5
    private var isSyncingWindows = false
    private var pendingSync = false
    private var pendingSyncExcludedZones: Set<ZoneKey> = []
    private var liveResizingZoneKey: ZoneKey?
    private var lastActiveApplicationPid: pid_t?
    private var placeholderIdToZoneKey: [Int: ZoneKey] = [:]
    private var dragSession: DragSession?
    private let dragOverlayManager = DragOverlayManager()
    private let indicatorManager = ZoneIndicatorManager()
    private var targetedZoneKey: ZoneKey?

    private struct ValidationRetryEntry {
        var attempts: Int
        var baseReason: String
        var workItem: DispatchWorkItem?
    }

    private var validationRetryEntries: [pid_t: ValidationRetryEntry] = [:]
    private let validationRetryDelays: [TimeInterval] = [0.2, 0.4, 0.8, 1.6, 3.2]

    private var dragExcludedZones: Set<ZoneKey> {
        guard let dragSession else {
            return []
        }
        var excluded: Set<ZoneKey> = []
        if let origin = dragSession.originZoneKey {
            excluded.insert(origin)
        }
        if let hovered = dragSession.hoveredZoneKey {
            excluded.insert(hovered)
        }
        return excluded
    }

    private override init() {
        let configuration = Configuration.load()
        self.configuration = configuration

        let screens = NSScreen.screens
        guard let primaryScreen = screens.first,
              let primaryId = AppController.displayId(for: primaryScreen) else {
            fatalError("No primary screen found")
        }

        self.primaryScreenId = primaryId
        self.primaryScreenBounds = primaryScreen.frame

        self.windowController = WindowController(
            ignoredBundleIdentifiers: configuration.ignoredBundleIdentifiers,
            primaryScreenBounds: primaryScreen.frame
        )

        var initialContexts: [CGDirectDisplayID: ScreenContext] = [:]
        var order: [CGDirectDisplayID] = []

        for screen in screens {
            guard let displayId = AppController.displayId(for: screen) else {
                continue
            }

            let descriptor = ScreenDescriptor(
                displayId: displayId,
                localizedName: screen.localizedName,
                cocoaBounds: screen.frame,
                visibleCocoaBounds: screen.visibleFrame,
                primaryBounds: primaryScreen.frame
            )
            let zoneController = ZoneController(screenFrame: descriptor.visibleScreenBounds)
            initialContexts[displayId] = ScreenContext(descriptor: descriptor, zoneController: zoneController)
            order.append(displayId)
        }

        self.targetedZoneKey = ZoneKey(screenId: primaryId, index: 1)

        super.init()

        self.screenContexts = initialContexts
        self.screenOrder = order
        self.windowController.delegate = self
        self.indicatorManager.delegate = self
        prepareExistingApplicationWindows()
        setupKeyboardShortcuts()
        setupApplicationMonitoring()

        Logger.debug("AppController initialized with multi-screen support across \(screenContexts.count) display(s)")

        // Create initial placeholder for the first empty zone
        syncWindowsToZones()
        ensureTargetedZone(reason: "startup")
        refreshIndicators()
    }

    deinit {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        for entry in validationRetryEntries.values {
            entry.workItem?.cancel()
        }
        validationRetryEntries.removeAll()

        for hotKeyRef in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()

        if let handler = hotKeyEventHandler {
            RemoveEventHandler(handler)
            hotKeyEventHandler = nil
        }

        indicatorManager.tearDown()
    }

    // MARK: - Zone Management

    func addZone() {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId],
              let newZone = context.zoneController.addZone() else {
            print("Failed to add zone (max 3 zones)")
            return
        }
        syncWindowsToZones()
        setTargetedZone(zoneKey(for: screenId, index: newZone.index), reason: "zone-added")
        print("Added zone \(newZone.index) on \(context.descriptor.localizedName)")
    }

    func removeZone(at index: Int) {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId] else {
            print("Active screen not available")
            return
        }

        guard performRemoveZone(at: index, on: screenId, announce: true, context: context) != nil else {
            print("Failed to remove zone \(index)")
            return
        }
    }

    private func performRemoveZone(
        at index: Int,
        on screenId: CGDirectDisplayID,
        announce: Bool,
        context: ScreenContext? = nil
    ) -> ZoneController.RemovalResult? {
        let context = context ?? screenContexts[screenId]
        guard let context else {
            return nil
        }

        guard let removalResult = context.zoneController.removeZone(at: index) else {
            return nil
        }

        let currentTarget = targetedZoneKey
        var pendingTargetedKey: ZoneKey?
        if let currentTarget, currentTarget.screenId == screenId {
            if currentTarget.index == index {
                pendingTargetedKey = fallbackTargetedZone(preferredScreenId: screenId)
            } else if currentTarget.index > index {
                pendingTargetedKey = ZoneKey(screenId: screenId, index: currentTarget.index - 1)
            }
        }

        if let pendingTargetedKey {
            setTargetedZone(pendingTargetedKey, reason: "zone-removed")
        }

        if let removedWindowId = removalResult.removedWindowId,
           let managed = windowController.window(withId: removedWindowId) {
            handleWindowAfterZoneRemoval(managed, preferredScreenId: screenId)
        }

        syncWindowsToZones()

        if pendingTargetedKey == nil {
            ensureTargetedZone(reason: "zone-removed")
        }

        if announce {
            print("Removed zone \(index) on \(context.descriptor.localizedName)")
        }
        return removalResult
    }

    func resizeZone(at index: Int, frame: CGRect) {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId] else {
            print("Active screen not available")
            return
        }

        guard let zone = context.zoneController.zone(at: index) else {
            print("Zone \(index) not found on \(context.descriptor.localizedName)")
            return
        }

        guard zone.isEmpty else {
            print("Zone \(index) is occupied; minimize or close its window before resizing.")
            return
        }

        if context.zoneController.resizeZone(at: index, to: frame) {
            syncWindowsToZones()
            if let updatedZone = context.zoneController.zone(at: index) {
                print("Resized zone \(index) on \(context.descriptor.localizedName) to \(updatedZone.frame)")
            } else {
                print("Zone \(index) resized")
            }
        } else {
            print("Failed to resize zone \(index)")
        }
    }

    // MARK: - Window Management

    func createWindow() {
        let managed = windowController.createTestWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        placeNewWindow(managed)
        print("Created window \(managed.windowId)")
    }

    func closeWindow(withId windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        // Remove from zone
        removeWindowFromAllZones(windowId: windowId, reason: "close-command")

        // Close the window
        windowController.closeWindow(managed)

        // Sync to create placeholder if needed
        syncWindowsToZones()

        print("Closed window \(windowId)")
    }

    func minimizeWindow(withId windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        windowController.minimizeWindow(managed)

        // Remove from zone and sync (delegate may not fire in CLI environment)
        removeWindowFromAllZones(windowId: windowId, reason: "minimize-command")
        syncWindowsToZones()

        print("Minimized window \(windowId)")
    }

    func unminimizeWindow(withId windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        windowController.unminimizeWindow(managed)

        // Place the window using normal placement logic
        placeNewWindow(managed)

        print("Unminimized window \(windowId)")
    }

    func captureFrontmostWindow() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let bundleId = frontmost.bundleIdentifier,
           configuration.ignoredBundleIdentifiers.contains(bundleId) {
            print("Frontmost application \(bundleId) is configured to be ignored.")
            return
        }

        guard let managed = windowController.captureFrontmostWindow() else {
            print("No frontmost window available. Make sure Accessibility permissions are granted and another app has a visible window.")
            return
        }

        if let zoneIndex = managed.zoneIndex,
           let screenId = managed.screenDisplayId,
           let zone = screenContexts[screenId]?.zoneController.zone(at: zoneIndex),
           zone.windowId == managed.windowId {
            syncWindowsToZones()
            print("Window \(managed.windowId) is already managed in zone \(zoneIndex)")
            return
        }

        placeNewWindow(managed)
        print("Captured window \(managed.windowId)")
    }

    func validateApplication(pid: pid_t) {
        let pruned = validateWindowsForApplication(pid: pid, reason: "repl-command")
        if pruned.isEmpty {
            print("Validated pid \(pid): no destroyed windows detected")
        } else {
            print("Validated pid \(pid): pruned windows \(pruned)")
        }
    }

    // MARK: - Window Placement Logic

    private func placeNewWindow(_ managed: ManagedWindow, preferredScreenId: CGDirectDisplayID? = nil) {
        removeWindowFromAllZones(windowId: managed.windowId, reason: "place-new-window")
        managed.zoneIndex = nil

        if let preferredScreenId {
            placeWindow(managed, on: preferredScreenId)
            return
        }

        placeWindowInTargetedZone(managed)
    }

    private func handleWindowAfterZoneRemoval(_ managed: ManagedWindow, preferredScreenId: CGDirectDisplayID) {
        removeWindowFromAllZones(windowId: managed.windowId, reason: "zone-removal-reassignment")
        managed.zoneIndex = nil

        if let (zone, context, descriptor) = findZoneAcceptingRemovedWindow(preferredScreenId: preferredScreenId) {
            Logger.debug(
                "Zone removal reassigning window \(managed.windowId) to zone \(zone.index) on \(context.descriptor.localizedName) [\(context.descriptor.displayId)]"
            )
            assignWindowToZone(managed, zone: zone, screenId: context.descriptor.displayId, descriptor: descriptor)
            return
        }

        Logger.debug("Zone removal minimizing window \(managed.windowId); no available zone without displacement")
        clearManagedWindowZone(managed)
        windowController.minimizeWindow(managed)
    }

    private func findZoneAcceptingRemovedWindow(
        preferredScreenId: CGDirectDisplayID
    ) -> (zone: Zone, context: ScreenContext, descriptor: ScreenDescriptor)? {
        let orderedScreens = screenOrderStarting(with: preferredScreenId)

        for screenId in orderedScreens {
            guard let context = screenContexts[screenId],
                  let descriptor = descriptor(for: screenId) else {
                continue
            }

            for zone in context.zoneController.allZones {
                if zone.windowId == nil {
                    return (zone, context, descriptor)
                }

                if let windowId = zone.windowId,
                   let occupant = windowController.window(withId: windowId),
                   occupant.isPlaceholder {
                    return (zone, context, descriptor)
                }
            }
        }

        return nil
    }

    private func screenOrderStarting(with preferred: CGDirectDisplayID) -> [CGDirectDisplayID] {
        var ordered = screenOrder
        if let index = ordered.firstIndex(of: preferred) {
            let prefix = ordered.remove(at: index)
            ordered.insert(prefix, at: 0)
        } else {
            ordered.insert(preferred, at: 0)
        }
        return ordered
    }

    private func placeWindowInTargetedZone(_ managed: ManagedWindow) {
        ensureTargetedZone(reason: "placing-window")

        guard let targetedKey = targetedZoneKey,
              let context = screenContexts[targetedKey.screenId],
              let descriptor = descriptor(for: targetedKey.screenId),
              let zone = context.zoneController.zone(at: targetedKey.index) else {
            let fallbackScreen = detectScreenId(for: managed) ?? activeScreenId()
            placeWindow(managed, on: fallbackScreen)
            return
        }

        let controller = context.zoneController
        var displacedWindow: ManagedWindow?
        if let existingId = zone.windowId,
           existingId != managed.windowId,
           let existingWindow = windowController.window(withId: existingId) {
            controller.removeWindow(windowId: existingId)
            displacedWindow = existingWindow
        }

        assignWindowToZone(managed, zone: zone, screenId: targetedKey.screenId, descriptor: descriptor)

        if let displaced = displacedWindow {
            if displaced.isPlaceholder {
                windowController.closeWindow(displaced)
                forgetPlaceholder(windowId: displaced.windowId)
            } else {
                clearManagedWindowZone(displaced)
                windowController.minimizeWindow(displaced)
            }
        }
    }

    private func placeWindow(_ managed: ManagedWindow, on screenId: CGDirectDisplayID) {
        guard let controller = zoneController(for: screenId),
              let descriptor = descriptor(for: screenId) else {
            return
        }

        if let emptyZone = controller.findEmptyZone() {
            assignWindowToZone(managed, zone: emptyZone, screenId: screenId, descriptor: descriptor)
            return
        }

        guard let highestZone = controller.highestIndexZone() else {
            return
        }

        var displacedWindow: ManagedWindow?
        if let oldWindowId = highestZone.windowId,
           oldWindowId != managed.windowId,
           let oldWindow = windowController.window(withId: oldWindowId) {
            controller.removeWindow(windowId: oldWindowId)
            displacedWindow = oldWindow
        }

        assignWindowToZone(managed, zone: highestZone, screenId: screenId, descriptor: descriptor)

        if let displaced = displacedWindow {
            if displaced.isPlaceholder {
                windowController.closeWindow(displaced)
                forgetPlaceholder(windowId: displaced.windowId)
            } else {
                clearManagedWindowZone(displaced)
                windowController.minimizeWindow(displaced)
            }
        }
    }

    private func assignWindowToZone(
        _ managed: ManagedWindow,
        zone: Zone,
        screenId: CGDirectDisplayID,
        descriptor: ScreenDescriptor
    ) {
        for window in windowController.allWindows where window.isPlaceholder {
            if window.zoneIndex == zone.index && window.screenDisplayId == screenId {
                windowController.closeWindow(window)
                forgetPlaceholder(windowId: window.windowId)
            }
        }

        guard let controller = zoneController(for: screenId) else {
            return
        }
        controller.assignWindow(windowId: managed.windowId, toZoneIndex: zone.index)
        setManagedWindow(managed, screenId: screenId, zoneIndex: zone.index)

        let displayFrame = frameWithMargin(for: zone, in: controller)
        windowController.showWindow(managed, at: displayFrame, on: descriptor)
    }

    // MARK: - Targeted Zone Management

    private func zoneExists(_ key: ZoneKey) -> Bool {
        guard let controller = zoneController(for: key.screenId) else {
            return false
        }
        return controller.zone(at: key.index) != nil
    }

    private func ensureTargetedZone(reason: String) {
        if let current = targetedZoneKey, zoneExists(current) {
            return
        }

        let preferredScreen = targetedZoneKey?.screenId ?? primaryScreenId
        let fallback = fallbackTargetedZone(preferredScreenId: preferredScreen)
        setTargetedZone(fallback, reason: reason)
    }

    private func setTargetedZone(_ key: ZoneKey?, reason: String) {
        var resolvedKey = key
        if let candidate = key, !zoneExists(candidate) {
            resolvedKey = fallbackTargetedZone(preferredScreenId: candidate.screenId)
        }

        if targetedZoneKey == resolvedKey {
            refreshIndicators()
            return
        }

        targetedZoneKey = resolvedKey

        if let resolvedKey {
            Logger.debug("Targeted zone set to \(resolvedKey.index) on display \(resolvedKey.screenId) due to \(reason)")
        } else {
            Logger.debug("Cleared targeted zone due to \(reason)")
        }

        refreshIndicators()
    }

    private func fallbackTargetedZone(preferredScreenId: CGDirectDisplayID?) -> ZoneKey? {
        let emptyCandidates = collectZoneCandidates { $0.isEmpty }
        if let selection = selectHighestIndexZone(from: emptyCandidates, preferredScreenId: preferredScreenId) {
            return selection
        }

        let allCandidates = collectZoneCandidates { _ in true }
        return selectHighestIndexZone(from: allCandidates, preferredScreenId: preferredScreenId)
    }

    private func collectZoneCandidates(where predicate: (Zone) -> Bool) -> [(ZoneKey, Int)] {
        var result: [(ZoneKey, Int)] = []
        for (screenId, context) in screenContexts {
            for zone in context.zoneController.allZones where predicate(zone) {
                let key = ZoneKey(screenId: screenId, index: zone.index)
                result.append((key, zone.index))
            }
        }
        return result
    }

    private func selectHighestIndexZone(
        from candidates: [(ZoneKey, Int)],
        preferredScreenId: CGDirectDisplayID?
    ) -> ZoneKey? {
        guard !candidates.isEmpty else {
            return nil
        }

        let maxIndex = candidates.map { $0.1 }.max() ?? 0
        let highestCandidates = candidates.filter { $0.1 == maxIndex }

        if let preferredScreenId,
           let preferred = highestCandidates.first(where: { $0.0.screenId == preferredScreenId }) {
            return preferred.0
        }

        let sorted = highestCandidates.sorted { lhs, rhs in
            screenOrderIndex(for: lhs.0.screenId) < screenOrderIndex(for: rhs.0.screenId)
        }
        return sorted.first?.0 ?? highestCandidates.first?.0
    }

    private func indicatorFrame(for zone: Zone, descriptor: ScreenDescriptor) -> CGRect {
        let zoneFrame = descriptor.screenToCocoa(zone.frame).standardized
        let bounds = descriptor.cocoaBounds.standardized

        let indicatorHeight: CGFloat = 6
        let minWidth: CGFloat = 40
        let targetWidth = max(minWidth, zoneFrame.width / 3)
        let clampedWidth = min(targetWidth, zoneFrame.width)

        var originX = zoneFrame.midX - clampedWidth / 2
        originX = max(bounds.minX, min(originX, bounds.maxX - clampedWidth))

        let offset: CGFloat = 4
        var originY = zoneFrame.maxY + offset
        if originY + indicatorHeight > bounds.maxY {
            originY = zoneFrame.maxY - indicatorHeight - offset
        }
        if originY < bounds.minY {
            originY = bounds.minY
        }

        return CGRect(x: originX, y: originY, width: clampedWidth, height: indicatorHeight)
    }

    private func refreshIndicators() {
        var descriptors: [ZoneIndicatorDescriptor] = []

        for (screenId, context) in screenContexts {
            let screenDescriptor = context.descriptor
            for zone in context.zoneController.allZones {
                let key = ZoneKey(screenId: screenId, index: zone.index)
                let frame = indicatorFrame(for: zone, descriptor: screenDescriptor)
                guard frame.width > 0, frame.height > 0 else {
                    continue
                }
                let descriptor = ZoneIndicatorDescriptor(
                    key: key,
                    cocoaFrame: frame,
                    isTargeted: key == targetedZoneKey
                )
                descriptors.append(descriptor)
            }
        }

        if descriptors.isEmpty {
            indicatorManager.tearDown()
            return
        }

        indicatorManager.present(over: descriptors)
    }

    private func hasManagedWindows(for pid: pid_t) -> Bool {
        return windowController.allWindows.contains { window in
            if case .accessibility(_, let windowPid, _) = window.backing {
                return windowPid == pid
            }
            return false
        }
    }

    private func cancelValidationRetry(for pid: pid_t) {
        guard let entry = validationRetryEntries.removeValue(forKey: pid) else {
            return
        }
        entry.workItem?.cancel()
    }

    private func scheduleValidationRetry(for pid: pid_t, reason: String) {
        guard hasManagedWindows(for: pid) else {
            cancelValidationRetry(for: pid)
            return
        }

        var entry = validationRetryEntries[pid] ?? ValidationRetryEntry(attempts: 0, baseReason: reason, workItem: nil)

        if entry.attempts >= validationRetryDelays.count {
            Logger.debug("Validation retry for pid \(pid) exhausted after \(entry.attempts) attempts (reason: \(entry.baseReason))")
            cancelValidationRetry(for: pid)
            return
        }

        let delay = validationRetryDelays[entry.attempts]
        entry.attempts += 1

        entry.workItem?.cancel()

        let baseReason = entry.baseReason
        let attemptNumber = entry.attempts
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.validationRetryEntries[pid]?.workItem = nil
            let pruned = self.validateWindowsForApplication(pid: pid, reason: "retry-\(baseReason)-\(attemptNumber)")
            if pruned.isEmpty && self.hasManagedWindows(for: pid) {
                self.scheduleValidationRetry(for: pid, reason: baseReason)
            } else {
                self.cancelValidationRetry(for: pid)
            }
        }

        entry.workItem = workItem
        validationRetryEntries[pid] = entry

        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    // MARK: - Synchronization

    /// Sync all windows to their zones, creating placeholders as needed
    private func syncWindowsToZones(excluding excludedZones: Set<ZoneKey> = []) {
        let effectiveExcludedZones = excludedZones.union(dragExcludedZones)
        if isSyncingWindows {
            pendingSync = true
            pendingSyncExcludedZones.formUnion(effectiveExcludedZones)
            return
        }
        isSyncingWindows = true
        let currentExcludedZones = effectiveExcludedZones
        defer {
            isSyncingWindows = false
            if pendingSync {
                pendingSync = false
                let pendingExcluded = pendingSyncExcludedZones
                pendingSyncExcludedZones.removeAll()
                syncWindowsToZones(excluding: pendingExcluded)
            }
        }

        Logger.debug("Syncing windows to zones")

        let prunedWindowIds = windowController.pruneDestroyedExternalWindows()
        if !prunedWindowIds.isEmpty {
            for windowId in prunedWindowIds {
                removeWindowFromAllZones(windowId: windowId, reason: "sync-prune-destroyed")
            }
        }

        var placeholdersByKey: [ZoneKey: ManagedWindow] = [:]
        var placeholdersWithoutKey: [ManagedWindow] = []
        for window in windowController.allWindows where window.isPlaceholder {
            if let key = placeholderIdToZoneKey[window.windowId] {
                placeholdersByKey[key] = window
            } else if let screenId = window.screenDisplayId,
                      let zoneIndex = window.zoneIndex {
                let key = ZoneKey(screenId: screenId, index: zoneIndex)
                recordPlaceholder(window, key: key)
                placeholdersByKey[key] = window
            } else {
                placeholdersWithoutKey.append(window)
            }
        }

        var placeholdersToClose = placeholdersByKey
        var assignedWindowIds = Set<Int>()

        for screenId in screenOrder {
            guard let context = screenContexts[screenId],
                  let descriptor = descriptor(for: screenId) else {
                continue
            }
            let controller = context.zoneController

            for zone in controller.allZones {
                let key = ZoneKey(screenId: screenId, index: zone.index)
                let isExcluded = currentExcludedZones.contains(key)
                let displayFrame = frameWithMargin(for: zone, in: controller)

                if let windowId = zone.windowId,
                   let managed = windowController.window(withId: windowId) {
                    windowController.moveWindow(managed, to: displayFrame, on: descriptor)
                    setManagedWindow(managed, screenId: screenId, zoneIndex: zone.index)
                    assignedWindowIds.insert(windowId)

                    if let placeholder = placeholdersToClose.removeValue(forKey: key) {
                        windowController.closeWindow(placeholder)
                        forgetPlaceholder(windowId: placeholder.windowId)
                    }
                } else {
                    if let placeholder = placeholdersByKey[key] {
                        recordPlaceholder(placeholder, key: key)
                        if isExcluded {
                            placeholder.appKitWindow?.orderFront(nil)
                        } else {
                            windowController.showWindow(placeholder, at: displayFrame, on: descriptor)
                            windowController.moveWindow(placeholder, to: displayFrame, on: descriptor)
                        }
                        placeholdersToClose.removeValue(forKey: key)
                    } else if let unassigned = placeholdersWithoutKey.popLast() {
                        recordPlaceholder(unassigned, key: key)
                        windowController.showWindow(unassigned, at: displayFrame, on: descriptor)
                        windowController.moveWindow(unassigned, to: displayFrame, on: descriptor)
                    } else {
                        let placeholder = windowController.createPlaceholderWindow(
                            frame: displayFrame,
                            zoneIndex: zone.index,
                            on: descriptor
                        )
                        recordPlaceholder(placeholder, key: key)
                        windowController.showWindow(placeholder, at: displayFrame, on: descriptor)
                    }
                }
            }
        }

        var idlePlaceholders: [ManagedWindow] = []

        for placeholder in placeholdersToClose.values {
            placeholder.appKitWindow?.orderOut(nil)
            clearManagedWindowZone(placeholder)
            forgetPlaceholder(windowId: placeholder.windowId)
            idlePlaceholders.append(placeholder)
        }
        for placeholder in placeholdersWithoutKey {
            placeholder.appKitWindow?.orderOut(nil)
            clearManagedWindowZone(placeholder)
            idlePlaceholders.append(placeholder)
        }

        if !idlePlaceholders.isEmpty {
            Logger.debug("Parking \(idlePlaceholders.count) placeholder window(s) for reuse")
        }

        for window in windowController.allWindows where !window.isPlaceholder {
            if !assignedWindowIds.contains(window.windowId) {
                clearManagedWindowZone(window)
            }
        }

        ensureTargetedZone(reason: "sync")
        refreshIndicators()
    }

    /// Compute the frame used to render content inside a zone, honoring the spec margin
    private func frameWithMargin(for zone: Zone, in controller: ZoneController) -> CGRect {
        let margins = zoneMargins(for: zone, in: controller)

        var left = margins.left
        var right = margins.right
        var top = margins.top
        var bottom = margins.bottom

        var frame = zone.frame.standardized

        let horizontalTotal = left + right
        if horizontalTotal > frame.width && frame.width > 0 {
            let scale = frame.width / horizontalTotal
            left *= scale
            right *= scale
        }

        let verticalTotal = top + bottom
        if verticalTotal > frame.height && frame.height > 0 {
            let scale = frame.height / verticalTotal
            top *= scale
            bottom *= scale
        }

        frame.origin.x += left
        frame.origin.y += top
        frame.size.width = max(0, frame.size.width - (left + right))
        frame.size.height = max(0, frame.size.height - (top + bottom))

        return frame
    }

    private func zoneMargins(for zone: Zone, in controller: ZoneController) -> ZoneEdgeMargins {
        let frame = zone.frame.standardized
        let bounds = controller.layoutBounds.standardized
        let neighbors = controller.allZones.filter { $0 !== zone }

        let fullMargin = zoneMargin
        let sharedMargin = zoneMargin / 2
        let tolerance = edgeAlignmentTolerance

        func verticalOverlap(with other: CGRect) -> CGFloat {
            let standardized = other.standardized
            return min(frame.maxY, standardized.maxY) - max(frame.minY, standardized.minY)
        }

        func horizontalOverlap(with other: CGRect) -> CGFloat {
            let standardized = other.standardized
            return min(frame.maxX, standardized.maxX) - max(frame.minX, standardized.minX)
        }

        let hasLeftNeighbor = neighbors.contains {
            abs($0.frame.standardized.maxX - frame.minX) <= tolerance && verticalOverlap(with: $0.frame) > 0
        }
        let hasRightNeighbor = neighbors.contains {
            abs($0.frame.standardized.minX - frame.maxX) <= tolerance && verticalOverlap(with: $0.frame) > 0
        }
        let hasTopNeighbor = neighbors.contains {
            abs($0.frame.standardized.maxY - frame.minY) <= tolerance && horizontalOverlap(with: $0.frame) > 0
        }
        let hasBottomNeighbor = neighbors.contains {
            abs($0.frame.standardized.minY - frame.maxY) <= tolerance && horizontalOverlap(with: $0.frame) > 0
        }

        let leftMargin: CGFloat
        if abs(frame.minX - bounds.minX) <= tolerance {
            leftMargin = fullMargin
        } else if hasLeftNeighbor {
            leftMargin = sharedMargin
        } else {
            leftMargin = fullMargin
        }

        let rightMargin: CGFloat
        if abs(frame.maxX - bounds.maxX) <= tolerance {
            rightMargin = fullMargin
        } else if hasRightNeighbor {
            rightMargin = sharedMargin
        } else {
            rightMargin = fullMargin
        }

        let topMargin: CGFloat
        if abs(frame.minY - bounds.minY) <= tolerance {
            topMargin = fullMargin
        } else if hasTopNeighbor {
            topMargin = sharedMargin
        } else {
            topMargin = fullMargin
        }

        let bottomMargin: CGFloat
        if abs(frame.maxY - bounds.maxY) <= tolerance {
            bottomMargin = fullMargin
        } else if hasBottomNeighbor {
            bottomMargin = sharedMargin
        } else {
            bottomMargin = fullMargin
        }

        return ZoneEdgeMargins(
            top: max(0, topMargin),
            left: max(0, leftMargin),
            bottom: max(0, bottomMargin),
            right: max(0, rightMargin)
        )
    }

    private func zoneAccessibilityFrame(_ zone: Zone, descriptor: ScreenDescriptor) -> CGRect {
        descriptor.screenToAccessibility(zone.frame)
    }

    private func zoneOverlayDescriptors() -> [ZoneOverlayDescriptor] {
        var descriptors: [ZoneOverlayDescriptor] = []
        for (screenId, context) in screenContexts {
            let descriptor = context.descriptor
            for zone in context.zoneController.allZones {
                let cocoaFrame = descriptor.screenToCocoa(zone.frame)
                descriptors.append(
                    ZoneOverlayDescriptor(
                        key: ZoneKey(screenId: screenId, index: zone.index),
                        cocoaFrame: cocoaFrame,
                        isEmpty: zone.isEmpty
                    )
                )
            }
        }
        return descriptors
    }

    private func screenOrderIndex(for screenId: CGDirectDisplayID) -> Int {
        screenOrder.firstIndex(of: screenId) ?? Int.max
    }

    private func prefersCandidate(_ candidate: ZoneKey, over current: ZoneKey?) -> Bool {
        guard let current else {
            return true
        }

        if candidate.screenId == current.screenId {
            return candidate.index < current.index
        }

        return screenOrderIndex(for: candidate.screenId) < screenOrderIndex(for: current.screenId)
    }

    private func resolveDropTarget(for accessibilityFrame: CGRect) -> ZoneKey? {
        let normalizedFrame = accessibilityFrame.standardized
        let center = CGPoint(x: normalizedFrame.midX, y: normalizedFrame.midY)

        var bestKey: ZoneKey?
        var bestScore: CGFloat = 0
        var bestIntersection: CGFloat = 0

        for (screenId, context) in screenContexts {
            let descriptor = context.descriptor
            for zone in context.zoneController.allZones {
                let accessibilityZone = zoneAccessibilityFrame(zone, descriptor: descriptor)
                let intersection = normalizedFrame.intersection(accessibilityZone)
                let intersectionArea: CGFloat
                if intersection.isNull {
                    intersectionArea = 0
                } else {
                    intersectionArea = intersection.width * intersection.height
                }

                let zoneArea = accessibilityZone.width * accessibilityZone.height
                let containsCenter = accessibilityZone.contains(center)
                let score = intersectionArea + (containsCenter ? zoneArea : 0)

                guard score > 0 else {
                    continue
                }

                let candidateKey = ZoneKey(screenId: screenId, index: zone.index)
                if score > bestScore ||
                    (score == bestScore && (intersectionArea > bestIntersection ||
                        (intersectionArea == bestIntersection && prefersCandidate(candidateKey, over: bestKey)))) {
                    bestScore = score
                    bestIntersection = intersectionArea
                    bestKey = candidateKey
                }
            }
        }

        return bestKey
    }

    private func recordDragUpdate(windowId: Int, frame: CGRect) {
        guard var session = dragSession, session.windowId == windowId else {
            return
        }
        session.latestFrame = frame
        let targetKey = resolveDropTarget(for: frame)
        session.hoveredZoneKey = targetKey
        dragSession = session
        dragOverlayManager.updateHighlight(to: targetKey)
    }

    private func handleDropCancellation(session: DragSession) {
        Logger.debug("Drag cancelled for window \(session.windowId); reverting to original assignment if needed")
    }

    private func performDrop(session: DragSession, targetKey: ZoneKey) -> DropResult? {
        guard let managed = windowController.window(withId: session.windowId) else {
            return nil
        }

        guard let targetContext = screenContexts[targetKey.screenId],
              let targetZone = targetContext.zoneController.zone(at: targetKey.index) else {
            return nil
        }

        if targetZone.windowId == session.windowId {
            Logger.debug("Window \(session.windowId) already assigned to target zone \(targetKey.index); no swap needed")
            setManagedWindow(managed, screenId: targetKey.screenId, zoneIndex: targetKey.index)
            return DropResult(displacedWindow: nil, preferredScreenId: nil)
        }

        let sourceKey = session.originZoneKey

        if let sourceKey,
           sourceKey == targetKey {
            Logger.debug("Window \(session.windowId) dropped back into its original zone \(targetKey.index)")
            return DropResult(displacedWindow: nil, preferredScreenId: nil)
        }

        if let sourceKey,
           let sourceContext = screenContexts[sourceKey.screenId] {
            sourceContext.zoneController.removeWindow(windowId: session.windowId)
        }

        var displacedWindow: ManagedWindow?
        if let displacedWindowId = targetZone.windowId,
           displacedWindowId != session.windowId,
           let occupant = windowController.window(withId: displacedWindowId) {
            targetContext.zoneController.removeWindow(windowId: displacedWindowId)
            displacedWindow = occupant
        }

        targetContext.zoneController.assignWindow(windowId: session.windowId, toZoneIndex: targetKey.index)
        setManagedWindow(managed, screenId: targetKey.screenId, zoneIndex: targetKey.index)
        Logger.debug("Assigned window \(session.windowId) to zone \(targetKey.index) on display \(targetKey.screenId)")

        if let displaced = displacedWindow,
           let sourceKey,
           let sourceContext = screenContexts[sourceKey.screenId] {
            sourceContext.zoneController.assignWindow(windowId: displaced.windowId, toZoneIndex: sourceKey.index)
            setManagedWindow(displaced, screenId: sourceKey.screenId, zoneIndex: sourceKey.index)
            if displaced.isPlaceholder {
                recordPlaceholder(displaced, key: sourceKey)
            }
            Logger.debug("Swapped displaced window \(displaced.windowId) back into original zone \(sourceKey.index)")
            return DropResult(displacedWindow: nil, preferredScreenId: nil)
        }

        if let displaced = displacedWindow {
            if displaced.isPlaceholder {
                Logger.debug("Closing displaced placeholder \(displaced.windowId) after drop")
                windowController.closeWindow(displaced)
                forgetPlaceholder(windowId: displaced.windowId)
                return DropResult(displacedWindow: nil, preferredScreenId: nil)
            }
            clearManagedWindowZone(displaced)
            Logger.debug("Window \(displaced.windowId) displaced from zone \(targetKey.index); will reassign later")
            return DropResult(displacedWindow: displaced, preferredScreenId: targetKey.screenId)
        }

        return DropResult(displacedWindow: nil, preferredScreenId: nil)
    }

    /// Convert a content frame (placeholder or occupant window) back into the zone frame.
    private func zoneFrame(fromContentFrame frame: CGRect, for zone: Zone, in context: ScreenContext) -> CGRect {
        let margins = zoneMargins(for: zone, in: context.zoneController)

        var zoneFrame = frame.standardized
        zoneFrame.origin.x -= margins.left
        zoneFrame.origin.y -= margins.top
        zoneFrame.size.width += margins.left + margins.right
        zoneFrame.size.height += margins.top + margins.bottom
        zoneFrame = clamp(frame: zoneFrame, to: context.zoneController.layoutBounds)
        return zoneFrame
    }

    private func applyPlaceholderResize(zoneKey: ZoneKey, placeholderFrame: CGRect, finalize: Bool) {
        guard let context = screenContexts[zoneKey.screenId] else {
            return
        }

        guard let zone = context.zoneController.zone(at: zoneKey.index) else {
            return
        }

        let zoneFrame = zoneFrame(fromContentFrame: placeholderFrame, for: zone, in: context)
        guard context.zoneController.resizeZone(at: zoneKey.index, to: zoneFrame) else {
            return
        }

        if finalize {
            Logger.debug("Placeholder for zone \(zoneKey.index) on display \(zoneKey.screenId) resize finalized")
            syncWindowsToZones()
        } else {
            syncWindowsToZones(excluding: Set([zoneKey]))
        }
    }

    private func clamp(frame: CGRect, to bounds: CGRect) -> CGRect {
        var normalized = frame.standardized

        let originX = max(bounds.minX, normalized.origin.x)
        let originY = max(bounds.minY, normalized.origin.y)
        let maxX = min(bounds.maxX, normalized.maxX)
        let maxY = min(bounds.maxY, normalized.maxY)

        normalized.origin = CGPoint(x: originX, y: originY)
        normalized.size.width = max(0, maxX - originX)
        normalized.size.height = max(0, maxY - originY)

        return normalized
    }

    private static func displayId(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    private func activeScreenId() -> CGDirectDisplayID {
        if let main = NSScreen.main,
           let id = AppController.displayId(for: main),
           screenContexts[id] != nil {
            return id
        }
        return primaryScreenId
    }

    private func descriptor(for screenId: CGDirectDisplayID) -> ScreenDescriptor? {
        screenContexts[screenId]?.descriptor
    }

    private func zoneController(for screenId: CGDirectDisplayID) -> ZoneController? {
        screenContexts[screenId]?.zoneController
    }

    private func removeWindowFromAllZones(windowId: Int, reason: String = "unspecified") {
        var removed = false

        for (screenId, context) in screenContexts {
            if let zone = context.zoneController.zoneForWindow(windowId: windowId) {
                Logger.debug(
                    "Removing window \(windowId) from zone \(zone.index) on \(context.descriptor.localizedName) [\(screenId)] (reason: \(reason))"
                )
                context.zoneController.removeWindow(windowId: windowId)
                removed = true
            } else {
                context.zoneController.removeWindow(windowId: windowId)
            }
        }

        if !removed, reason != "place-new-window" {
            Logger.debug("Requested removal of window \(windowId) from all zones but none were assigned (reason: \(reason))")
        }
    }

    private func zoneKey(for screenId: CGDirectDisplayID, index: Int) -> ZoneKey {
        ZoneKey(screenId: screenId, index: index)
    }

    private func setManagedWindow(_ managed: ManagedWindow, screenId: CGDirectDisplayID, zoneIndex: Int?) {
        managed.screenDisplayId = screenId
        managed.zoneIndex = zoneIndex
    }

    private func clearManagedWindowZone(_ managed: ManagedWindow) {
        managed.zoneIndex = nil
        managed.screenDisplayId = nil
    }

    private func recordPlaceholder(_ placeholder: ManagedWindow, key: ZoneKey) {
        placeholderIdToZoneKey[placeholder.windowId] = key
        windowController.refreshPlaceholderMetadata(placeholder, screenId: key.screenId, zoneIndex: key.index)
    }

    private func forgetPlaceholder(windowId: Int) {
        placeholderIdToZoneKey.removeValue(forKey: windowId)
    }

    private func detectScreenId(for managed: ManagedWindow) -> CGDirectDisplayID? {
        if let existing = managed.screenDisplayId, screenContexts[existing] != nil {
            return existing
        }

        guard let cocoaFrame = cocoaFrame(for: managed) else {
            return nil
        }

        var bestId: CGDirectDisplayID?
        var largestArea: CGFloat = 0

        for (screenId, context) in screenContexts {
            let intersection = cocoaFrame.intersection(context.descriptor.cocoaBounds)
            if intersection.isNull {
                continue
            }
            let area = intersection.width * intersection.height
            if area > largestArea {
                largestArea = area
                bestId = screenId
            }
        }

        if let bestId, largestArea > 0 {
            return bestId
        }

        for (screenId, context) in screenContexts {
            if context.descriptor.cocoaBounds.contains(cocoaFrame.origin) {
                return screenId
            }
        }

        return nil
    }

    private func cocoaFrame(for managed: ManagedWindow) -> CGRect? {
        switch managed.backing {
        case .appKit(let window):
            return window.frame
        case .accessibility(let element, _, _):
            guard let position = ManagedWindow.copyCGPointValue(element: element, attribute: kAXPositionAttribute as CFString),
                  let size = ManagedWindow.copyCGSizeValue(element: element, attribute: kAXSizeAttribute as CFString) else {
                return nil
            }
            let accessibilityFrame = CGRect(origin: position, size: size)
            return CoordinateConversion.accessibilityToCocoa(
                accessibilityFrame: accessibilityFrame,
                primaryScreenBounds: primaryScreenBounds
            )
        }
    }

    // MARK: - WindowControllerDelegate

    func windowFocusChanged(pid: pid_t) {
        // When focus changes in an application, validate its windows
        // This catches window closures that didn't fire destroy notifications
        validateWindowsForApplication(pid: pid, reason: "focus-changed")
    }

    func placeholderCloseRequested(screenId: CGDirectDisplayID, zoneIndex: Int) {
        Logger.debug("Placeholder close requested for zone \(zoneIndex) on display \(screenId)")
        _ = performRemoveZone(at: zoneIndex, on: screenId, announce: false)
    }

    func placeholderActivated(screenId: CGDirectDisplayID, zoneIndex: Int) {
        Logger.debug("Placeholder activated for zone \(zoneIndex) on display \(screenId)")
        setTargetedZone(zoneKey(for: screenId, index: zoneIndex), reason: "placeholder-activated")
    }

    func zoneIndicatorActivated(_ key: ZoneKey) {
        Logger.debug("Zone indicator activated for zone \(key.index) on display \(key.screenId)")
        setTargetedZone(key, reason: "indicator-clicked")
    }

    func windowWillClose(windowId: Int) {
        Logger.debug("Window \(windowId) will close")
        if let managed = windowController.window(withId: windowId), managed.isPlaceholder {
            forgetPlaceholder(windowId: windowId)
        }
        if dragSession?.windowId == windowId {
            dragOverlayManager.tearDown()
            dragSession = nil
        }
        removeWindowFromAllZones(windowId: windowId, reason: "delegate-will-close")
        syncWindowsToZones()
    }

    func windowDidMiniaturize(windowId: Int) {
        Logger.debug("Window \(windowId) did miniaturize")
        if dragSession?.windowId == windowId {
            dragOverlayManager.tearDown()
            dragSession = nil
        }
        removeWindowFromAllZones(windowId: windowId, reason: "delegate-did-miniaturize")
        syncWindowsToZones()
    }

    func windowDidDeminiaturize(windowId: Int) {
        Logger.debug("Window \(windowId) did deminiaturize")
        guard let managed = windowController.window(withId: windowId) else { return }
        placeNewWindow(managed)
    }

    func placeholderLiveResizeDidBegin(screenId: CGDirectDisplayID, zoneIndex: Int) {
        liveResizingZoneKey = ZoneKey(screenId: screenId, index: zoneIndex)
    }

    func placeholderLiveResized(screenId: CGDirectDisplayID, zoneIndex: Int, to frame: CGRect) {
        let key = ZoneKey(screenId: screenId, index: zoneIndex)
        guard liveResizingZoneKey == key else {
            return
        }

        applyPlaceholderResize(zoneKey: key, placeholderFrame: frame, finalize: false)
    }

    func placeholderLiveResizeDidEnd(screenId: CGDirectDisplayID, zoneIndex: Int, to frame: CGRect) {
        let key = ZoneKey(screenId: screenId, index: zoneIndex)
        if liveResizingZoneKey == key {
            liveResizingZoneKey = nil
        }

        applyPlaceholderResize(zoneKey: key, placeholderFrame: frame, finalize: true)
    }

    func windowManualResizeDidEnd(windowId: Int, screenId: CGDirectDisplayID?, frame: CGRect) {
        guard let screenId,
              let context = screenContexts[screenId],
              let managed = windowController.window(withId: windowId),
              let zoneIndex = managed.zoneIndex else {
            Logger.debug("Resize completed for window \(windowId) without a zone assignment")
            return
        }

        guard let zone = context.zoneController.zone(at: zoneIndex) else {
            Logger.debug("Zone \(zoneIndex) not found during resize for window \(windowId)")
            return
        }

        let zoneFrame = zoneFrame(fromContentFrame: frame, for: zone, in: context)
        guard context.zoneController.resizeZone(at: zoneIndex, to: zoneFrame, allowOccupied: true) else {
            Logger.debug("Failed to resize zone \(zoneIndex) from window \(windowId)")
            return
        }

        Logger.debug("Applied window-driven resize for zone \(zoneIndex) from window \(windowId)")
        syncWindowsToZones()
    }

    func windowManualMoveDidBegin(windowId: Int, frame: CGRect) {
        guard let managed = windowController.window(withId: windowId), !managed.isPlaceholder else {
            return
        }

        let originZoneKey: ZoneKey?
        if let screenId = managed.screenDisplayId, let zoneIndex = managed.zoneIndex {
            originZoneKey = ZoneKey(screenId: screenId, index: zoneIndex)
        } else {
            originZoneKey = nil
        }

        let originScreenId = managed.screenDisplayId ?? detectScreenId(for: managed)
        dragSession = DragSession(
            windowId: windowId,
            originZoneKey: originZoneKey,
            originScreenId: originScreenId,
            originFrame: frame,
            latestFrame: frame,
            hoveredZoneKey: nil,
            beganAt: Date()
        )
        Logger.debug("Drag session began for window \(windowId)")
        dragOverlayManager.present(over: zoneOverlayDescriptors())
        recordDragUpdate(windowId: windowId, frame: frame)
    }

    func windowManualMoveDidUpdate(windowId: Int, frame: CGRect) {
        recordDragUpdate(windowId: windowId, frame: frame)
    }

    func windowManualMoveDidEnd(windowId: Int, finalFrame: CGRect) {
        recordDragUpdate(windowId: windowId, frame: finalFrame)

        guard let session = dragSession, session.windowId == windowId else {
            dragOverlayManager.tearDown()
            syncWindowsToZones()
            return
        }

        dragOverlayManager.tearDown()

        var displacedWindow: ManagedWindow?
        var displacedPreferredScreen: CGDirectDisplayID?

        if let targetKey = session.hoveredZoneKey ?? resolveDropTarget(for: finalFrame) {
            if let result = performDrop(session: session, targetKey: targetKey) {
                displacedWindow = result.displacedWindow
                displacedPreferredScreen = result.preferredScreenId
            }
        } else {
            handleDropCancellation(session: session)
        }

        dragSession = nil

        if let displacedWindow {
            let preferredScreen = displacedPreferredScreen ?? session.originScreenId
            placeNewWindow(displacedWindow, preferredScreenId: preferredScreen)
        }

        syncWindowsToZones()
    }

    func placeholderAllowedResizeAxes(screenId: CGDirectDisplayID, zoneIndex: Int) -> PlaceholderResizeAxes {
        guard let context = screenContexts[screenId],
              let zone = context.zoneController.zone(at: zoneIndex), zone.isEmpty else {
            return []
        }

        let zoneCount = context.zoneController.allZones.count
        switch zoneCount {
        case 0, 1:
            return []
        case 2:
            return [.horizontal]
        case 3:
            if zoneIndex == 1 {
                return [.horizontal]
            } else {
                return [.horizontal, .vertical]
            }
        default:
            return []
        }
    }

    func windowController(_ controller: WindowController, didCaptureExternalWindow window: ManagedWindow) {
        placeNewWindow(window)
    }

    func screenDescriptor(for screenId: CGDirectDisplayID) -> ScreenDescriptor? {
        descriptor(for: screenId)
    }

    // MARK: - Startup helpers

    private func prepareExistingApplicationWindows() {
        var windowsByScreen: [CGDirectDisplayID: [ManagedWindow]] = [:]
        let visibleBundleIds = bundleIdsWithVisibleWindows()

        for application in NSWorkspace.shared.runningApplications {
            guard shouldManage(application: application, visibleBundleIds: visibleBundleIds) else {
                continue
            }

            let windows = windowController.captureWindows(for: application, notifyDelegate: false, allowExisting: false)
            for window in windows {
                let resolvedScreenId = detectScreenId(for: window) ?? primaryScreenId
                guard screenContexts[resolvedScreenId] != nil else {
                    continue
                }
                windowsByScreen[resolvedScreenId, default: []].append(window)
            }
        }

        for (screenId, windows) in windowsByScreen {
            guard let context = screenContexts[screenId] else {
                continue
            }

            let sortedWindows = windows.sorted { lhs, rhs in
                let leftX = screenMinX(for: lhs, descriptor: context.descriptor)
                let rightX = screenMinX(for: rhs, descriptor: context.descriptor)
                if leftX == rightX {
                    return lhs.windowId < rhs.windowId
                }
                return leftX < rightX
            }

            let desiredZoneCount = max(1, min(windows.count, 3))
            let removedWindowIds = context.zoneController.setZoneCount(to: desiredZoneCount)

            for removedId in removedWindowIds {
                if let removedWindow = windowController.window(withId: removedId) {
                    clearManagedWindowZone(removedWindow)
                    windowController.minimizeWindow(removedWindow)
                }
            }

            let managedCandidates = sortedWindows.prefix(desiredZoneCount)
            let excessWindows = sortedWindows.dropFirst(desiredZoneCount)

            for window in managedCandidates {
                placeNewWindow(window, preferredScreenId: screenId)
            }

            for window in excessWindows {
                clearManagedWindowZone(window)
                windowController.minimizeWindow(window)
            }
        }

        for (screenId, context) in screenContexts where windowsByScreen[screenId] == nil {
            context.zoneController.setZoneCount(to: 1)
        }
    }

    /// Compute the left edge of a window in screen coordinates for ordering.
    private func screenMinX(for managed: ManagedWindow, descriptor: ScreenDescriptor) -> CGFloat {
        guard let cocoaFrame = cocoaFrame(for: managed) else {
            return .greatestFiniteMagnitude
        }
        return descriptor.cocoaToScreen(cocoaFrame).minX
    }

    private enum HotKeyID: UInt32 {
        case addZone = 1
        case removeZone = 2
    }

    private func setupKeyboardShortcuts() {
        registerGlobalHotKeys()

        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self = self else { return event }
            if self.handleLocalShortcut(event: event) {
                return nil
            }
            return event
        }) {
            eventMonitors.append(localMonitor)
        }
    }

    private func setupApplicationMonitoring() {
        let center = NSWorkspace.shared.notificationCenter

        let activationObserver = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication

            // When switching applications, validate windows for the previously active app
            // This catches window closures that happened while the app was active
            if let previousPid = self.lastActiveApplicationPid {
                self.validateWindowsForApplication(pid: previousPid, reason: "workspace-activation-previous-app")
            }

            if let application = application {
                self.lastActiveApplicationPid = application.processIdentifier
            }

            self.handleApplicationEvent(application)
        }
        workspaceObservers.append(activationObserver)

        let launchObserver = center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.handleApplicationEvent(application)
        }
        workspaceObservers.append(launchObserver)

        let unhideObserver = center.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.handleApplicationEvent(application)
        }
        workspaceObservers.append(unhideObserver)

        // Listen to deactivation and hide events to detect window changes
        let deactivationObserver = center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.handleApplicationStateChange(application)
        }
        workspaceObservers.append(deactivationObserver)

        let hideObserver = center.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.handleApplicationStateChange(application)
        }
        workspaceObservers.append(hideObserver)

        let terminateObserver = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.handleApplicationTermination(application)
        }
        workspaceObservers.append(terminateObserver)

        if let frontmost = NSWorkspace.shared.frontmostApplication {
            lastActiveApplicationPid = frontmost.processIdentifier
            handleApplicationEvent(frontmost)
        }
    }

    private func handleApplicationEvent(_ application: NSRunningApplication?) {
        guard let application else {
            return
        }

        guard shouldManage(application: application) else {
            return
        }

        scheduleCapture(for: application, delay: 0.0)
        scheduleCapture(for: application, delay: 0.4)
    }

    private func handleApplicationStateChange(_ application: NSRunningApplication?) {
        guard let application else {
            return
        }

        guard shouldManage(application: application) else {
            return
        }

        // When an application changes state (deactivate/hide), validate all its windows
        // This catches window closures that didn't fire destroy notifications
        validateWindowsForApplication(pid: application.processIdentifier, reason: "workspace-state-change")
    }

    private func handleApplicationTermination(_ application: NSRunningApplication?) {
        guard let application else {
            Logger.debug("NSWorkspace notification received: didTerminateApplication (no application payload)")
            return
        }

        let name = application.localizedName ?? "Unknown App"
        var details = "\(name), pid \(application.processIdentifier)"
        if let bundleId = application.bundleIdentifier {
            details += ", bundle \(bundleId)"
        }
        Logger.debug("NSWorkspace notification received: didTerminateApplication (\(details))")

        // When an application terminates, remove all of its managed windows immediately
        let removedWindowIds = windowController.removeAllWindows(forPid: application.processIdentifier)
        if removedWindowIds.isEmpty {
            Logger.debug("Application terminated, but no managed windows were associated with pid \(application.processIdentifier)")
            return
        }

        Logger.debug("Application terminated, pruned \(removedWindowIds.count) windows")
        cancelValidationRetry(for: application.processIdentifier)
        for windowId in removedWindowIds {
            if dragSession?.windowId == windowId {
                dragOverlayManager.tearDown()
                dragSession = nil
            }
            removeWindowFromAllZones(windowId: windowId, reason: "application-termination")
        }
        syncWindowsToZones()
    }

    @discardableResult
    private func validateWindowsForApplication(pid: pid_t, reason: String = "unspecified") -> [Int] {
        let prunedWindowIds = windowController.pruneDestroyedWindowsForPid(pid)
        if prunedWindowIds.isEmpty {
            let baseReason = validationRetryEntries[pid]?.baseReason ?? reason
            let isRetry = reason.hasPrefix("retry")
            if !isRetry {
                Logger.debug("Validated windows for pid \(pid) (\(reason)), no destroyed windows detected")
            }
            if hasManagedWindows(for: pid) {
                scheduleValidationRetry(for: pid, reason: baseReason)
            } else {
                cancelValidationRetry(for: pid)
            }
            return []
        }

        Logger.debug(
            "Validated windows for pid \(pid) (\(reason)), pruned \(prunedWindowIds.count) destroyed windows: \(prunedWindowIds)"
        )
        cancelValidationRetry(for: pid)
        for windowId in prunedWindowIds {
            removeWindowFromAllZones(windowId: windowId, reason: "validate-application")
        }
        syncWindowsToZones()
        return prunedWindowIds
    }

    private func scheduleCapture(for application: NSRunningApplication, delay: TimeInterval) {
        let pid = application.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            guard let refreshedApplication = NSRunningApplication(processIdentifier: pid) else { return }
            guard self.shouldManage(application: refreshedApplication) else { return }

            let newWindows = self.windowController.captureWindows(for: refreshedApplication, notifyDelegate: false, allowExisting: false)
            for window in newWindows {
                self.placeNewWindow(window)
            }
        }
    }

    private func shouldManage(application: NSRunningApplication, visibleBundleIds: Set<String>? = nil) -> Bool {
        guard !application.isTerminated else {
            return false
        }
        if application.processIdentifier == getpid() {
            return false
        }
        guard let bundleId = application.bundleIdentifier else {
            return false
        }
        if let visibleBundleIds = visibleBundleIds,
           !visibleBundleIds.contains(bundleId) {
            return false
        }
        if configuration.ignoredBundleIdentifiers.contains(bundleId) {
            return false
        }
        if application.activationPolicy != .regular {
            return false
        }
        if isXpcOrHelperProcess(application) {
            return false
        }
        return true
    }

    private func bundleIdsWithVisibleWindows() -> Set<String> {
        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var bundleIds: Set<String> = []
        for info in windowInfoList {
            guard let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: ownerPid),
                  let bundleId = app.bundleIdentifier else {
                continue
            }
            bundleIds.insert(bundleId)
        }
        return bundleIds
    }

    private func isXpcOrHelperProcess(_ application: NSRunningApplication) -> Bool {
        guard let url = application.bundleURL else {
            return false
        }

        let path = url.path
        return path.hasSuffix(".xpc") ||
            path.contains("/Contents/XPCServices/") ||
            path.contains(".xpc/")
    }

    @discardableResult
    private func handleLocalShortcut(event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              event.modifierFlags.contains(.control) else {
            return false
        }

        switch Int(event.keyCode) {
        case kVK_ANSI_Equal:
            Logger.debug("Local shortcut add zone triggered")
            triggerShortcut(.addZone)
            return true
        case kVK_ANSI_Minus:
            Logger.debug("Local shortcut remove zone triggered")
            triggerShortcut(.removeZone)
            return true
        default:
            return false
        }
    }

    fileprivate func handleHotKeyEvent(event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr, hotKeyID.signature == hotKeySignature else {
            return status
        }

        switch HotKeyID(rawValue: hotKeyID.id) {
        case .addZone:
            Logger.debug("Hotkey add zone triggered")
            triggerShortcut(.addZone)
        case .removeZone:
            Logger.debug("Hotkey remove zone triggered")
            triggerShortcut(.removeZone)
        case .none:
            break
        }

        return noErr
    }

    private func registerGlobalHotKeys() {
        installHotKeyEventHandler()
        registerHotKey(keyCode: UInt32(kVK_ANSI_Equal), id: HotKeyID.addZone.rawValue)
        registerHotKey(keyCode: UInt32(kVK_ANSI_Minus), id: HotKeyID.removeZone.rawValue)
    }

    private func installHotKeyEventHandler() {
        guard hotKeyEventHandler == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            AppControllerHotKeyHandler,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &hotKeyEventHandler
        )

        if status != noErr {
            Logger.debug("Failed to install hotkey handler with status \(status)")
        }
    }

    private func registerHotKey(keyCode: UInt32, id: UInt32) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: id)
        let modifierFlags = UInt32(cmdKey | controlKey)
        let status = RegisterEventHotKey(
            keyCode,
            modifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr, let hotKeyRef {
            hotKeyRefs.append(hotKeyRef)
            Logger.debug("Registered hotkey id \(id) keyCode \(keyCode)")
        } else if status != noErr {
            Logger.debug("Failed to register hotkey \(id) with status \(status)")
        }
    }

    private func triggerShortcut(_ action: HotKeyID) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch action {
            case .addZone:
                self.addZone()
            case .removeZone:
                let screenId = self.activeScreenId()
                guard let removalIndex = self.zoneIndexForShortcutRemoval(on: screenId) else { return }
                if let context = self.screenContexts[screenId],
                   let zone = context.zoneController.zone(at: removalIndex) {
                    let targetedMatch = (self.targetedZoneKey?.screenId == screenId) && (self.targetedZoneKey?.index == removalIndex)
                    Logger.debug(
                        "Shortcut remove about to remove zone \(removalIndex) on \(context.descriptor.localizedName) " +
                        "[\(screenId)] (empty: \(zone.isEmpty), targeted: \(targetedMatch), window: \(zone.windowId.map(String.init) ?? "none"))"
                    )
                } else {
                    Logger.debug("Shortcut remove selected zone \(removalIndex) on display \(screenId), but zone details unavailable")
                }
                _ = self.performRemoveZone(at: removalIndex, on: screenId, announce: true)
            }
        }
    }

    private func zoneIndexForShortcutRemoval(on screenId: CGDirectDisplayID) -> Int? {
        guard let context = screenContexts[screenId] else {
            return nil
        }

        let zones = context.zoneController.allZones
        guard zones.count > 1 else {
            return nil
        }

        let activeIndices = activeZoneIndices(on: screenId)
        let activeList = activeIndices.sorted()
        Logger.debug(
            "Shortcut remove evaluating screen \(context.descriptor.localizedName) [\(screenId)] " +
            "with active zone indices: \(activeList)"
        )

        let targetedIndex: Int?
        if let targetedKey = targetedZoneKey, targetedKey.screenId == screenId {
            targetedIndex = targetedKey.index
        } else {
            targetedIndex = nil
        }

        let candidates = zones.filter { zone in
            return !activeIndices.contains(zone.index)
        }

        guard !candidates.isEmpty else {
            Logger.debug(
                "Shortcut remove found no removable zones on \(context.descriptor.localizedName) " +
                "[\(screenId)] (active zones: \(activeList), total zones: \(zones.count))"
            )
            return nil
        }

        let orderedCandidates = candidates.sorted { lhs, rhs in
            removalPriorityKey(for: lhs, targetedIndex: targetedIndex) <
                removalPriorityKey(for: rhs, targetedIndex: targetedIndex)
        }

        let description = orderedCandidates.map { zone -> String in
            let priority = removalPriorityKey(for: zone, targetedIndex: targetedIndex)
            let targetedFlag = (targetedIndex == zone.index)
            return "zone \(zone.index){empty:\(zone.isEmpty), targeted:\(targetedFlag), window:\(zone.windowId.map(String.init) ?? "none"), priority:\(priority)}"
        }.joined(separator: ", ")

        if let selected = orderedCandidates.first {
            Logger.debug(
                "Shortcut remove selected zone \(selected.index) on \(context.descriptor.localizedName) " +
                "[\(screenId)] from candidates [\(description)]"
            )
            return selected.index
        } else {
            Logger.debug(
                "Shortcut remove unable to choose among candidates on \(context.descriptor.localizedName) " +
                "[\(screenId)], descriptions: [\(description)]"
            )
            return nil
        }
    }

    private func removalPriorityKey(for zone: Zone, targetedIndex: Int?) -> (Int, Int, Int) {
        let emptinessRank = zone.isEmpty ? 0 : 1
        let targetedRank = (targetedIndex == zone.index) ? 1 : 0
        let indexRank = -zone.index
        return (emptinessRank, targetedRank, indexRank)
    }

    private func activeZoneIndices(on screenId: CGDirectDisplayID) -> Set<Int> {
        let screenName = screenContexts[screenId]?.descriptor.localizedName ?? "Unknown Screen"

        if let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           frontmostPid != getpid(),
           let managed = windowController.focusedWindowIfTracked(pid: frontmostPid),
           !managed.isPlaceholder,
           let zoneIndex = managed.zoneIndex,
           let managedScreenId = managed.screenDisplayId ?? detectScreenId(for: managed),
           managedScreenId == screenId {
            Logger.debug(
                "activeZoneIndices: using frontmost pid \(frontmostPid) -> zone \(zoneIndex) on \(screenName) [\(screenId)]"
            )
            return [zoneIndex]
        }

        if let lastPid = lastActiveApplicationPid,
           let managed = windowController.focusedWindowIfTracked(pid: lastPid),
           !managed.isPlaceholder,
           let zoneIndex = managed.zoneIndex,
           let managedScreenId = managed.screenDisplayId ?? detectScreenId(for: managed),
           managedScreenId == screenId {
            Logger.debug(
                "activeZoneIndices: using last active pid \(lastPid) -> zone \(zoneIndex) on \(screenName) [\(screenId)]"
            )
            return [zoneIndex]
        }

        guard let context = screenContexts[screenId] else {
            return []
        }

        var candidatePids: Set<pid_t> = []
        if let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           frontmostPid != getpid() {
            candidatePids.insert(frontmostPid)
        }
        if let lastPid = lastActiveApplicationPid,
           lastPid != getpid() {
            candidatePids.insert(lastPid)
        }

        var indices: Set<Int> = []
        for zone in context.zoneController.allZones {
            guard let windowId = zone.windowId,
                  let managedWindow = windowController.window(withId: windowId),
                  !managedWindow.isPlaceholder,
                  (managedWindow.screenDisplayId ?? detectScreenId(for: managedWindow)) == screenId else {
                if let windowId = zone.windowId,
                   let managedWindow = windowController.window(withId: windowId) {
                    let hasScreen = (managedWindow.screenDisplayId ?? detectScreenId(for: managedWindow)) != nil
                    Logger.debug(
                        "activeZoneIndices: skipping zone \(zone.index) on \(screenName) [\(screenId)] " +
                        "for window \(windowId) (placeholder: \(managedWindow.isPlaceholder), hasScreen: \(hasScreen))"
                    )
                } else if zone.windowId != nil {
                    Logger.debug(
                        "activeZoneIndices: no managed window for id \(zone.windowId!) in zone \(zone.index) on \(screenName) [\(screenId)]"
                    )
                }
                continue
            }

            switch managedWindow.backing {
            case .accessibility(_, let pid, _):
                if candidatePids.contains(pid) {
                    indices.insert(zone.index)
                } else {
                    Logger.debug(
                        "activeZoneIndices: window \(windowId) pid \(pid) not in candidate pid set \(candidatePids) " +
                        "for zone \(zone.index) on \(screenName) [\(screenId)]"
                    )
                }
            case .appKit(let nsWindow):
                if nsWindow.isKeyWindow {
                    indices.insert(zone.index)
                } else {
                    Logger.debug(
                        "activeZoneIndices: AppKit window \(windowId) in zone \(zone.index) is not key on \(screenName) [\(screenId)]"
                    )
                }
            }
        }
        Logger.debug(
            "activeZoneIndices: resolved indices \(indices.sorted()) for \(screenName) [\(screenId)] with candidate pids \(candidatePids)"
        )
        return indices
    }

    // MARK: - Inspection

    func listZones() {
        print("\nCurrent zones:")
        for screenId in screenOrder {
            guard let context = screenContexts[screenId] else { continue }
            print("  Screen \(context.descriptor.localizedName) [\(screenId)]:")
            for zone in context.zoneController.allZones {
                let windowInfo = zone.windowId.map { "window \($0)" } ?? "empty"
                print("    Zone \(zone.index): \(windowInfo), frame: \(zone.frame)")
            }
        }
        print("")
    }

    func printManagedWindows() {
        let windows = windowController.allWindows.sorted { $0.windowId < $1.windowId }
        print("\nManaged windows:")
        guard !windows.isEmpty else {
            print("  (none)")
            print("")
            return
        }

        for window in windows {
            let info = windowInfoJSON(windowId: window.windowId)
            let type = info["type"] as? String ?? "unknown"
            let zoneIndex = info["zone_index"] as? Int

            let screenId: CGDirectDisplayID? = {
                if let value = info["screen_display_id"] {
                    if let intValue = value as? Int {
                        return CGDirectDisplayID(intValue)
                    } else if let uintValue = value as? UInt32 {
                        return uintValue
                    }
                }
                return window.screenDisplayId
            }()

            let screenName = screenId.flatMap { descriptor(for: $0)?.localizedName } ?? "unknown screen"
            let pid = info["pid"] as? Int
            let appName = info["application_name"] as? String ?? "<unknown>"
            let bundleId = info["bundle_identifier"] as? String ?? "<unknown>"

            let zoneDescription: String
            if let zoneIndex, let screenId {
                zoneDescription = "zone \(zoneIndex) on \(screenName) [\(Int(screenId))]"
            } else if let zoneIndex {
                zoneDescription = "zone \(zoneIndex)"
            } else {
                zoneDescription = "unassigned"
            }

            let pidDescription: String
            if let pid {
                pidDescription = "pid \(pid) (\(appName), \(bundleId))"
            } else {
                pidDescription = "(no pid)"
            }

            print("  Window \(window.windowId): \(type), \(pidDescription), \(zoneDescription)")
        }
        print("")
    }

    func relayout() {
        for context in screenContexts.values {
            context.zoneController.relayout()
        }
        syncWindowsToZones()
        print("Layouts recalculated")
    }

    func windowInfo(windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        let type: String
        if managed.isPlaceholder {
            type = "placeholder"
        } else {
            switch managed.backing {
            case .appKit:
                type = "test"
            case .accessibility:
                type = "external"
            }
        }

        let screenId = managed.screenDisplayId ?? detectScreenId(for: managed)
        let screenDescriptor = screenId.flatMap { (id: CGDirectDisplayID) -> ScreenDescriptor? in
            descriptor(for: id)
        }
        let actualFrame: CGRect
        if let screenDescriptor {
            actualFrame = windowController.actualFrameInScreenCoordinates(for: managed, on: screenDescriptor)
        } else if let fallback = windowController.actualFrameInScreenCoordinates(for: managed) {
            actualFrame = fallback
        } else {
            actualFrame = .zero
        }

        print("\nWindow \(windowId):")
        print("  Type: \(type)")

        var owningPid: pid_t?
        switch managed.backing {
        case .appKit:
            owningPid = getpid()
        case .accessibility(_, let pid, _):
            owningPid = pid
        }

        if let pid = owningPid {
            if let application = NSRunningApplication(processIdentifier: pid) ?? (pid == getpid() ? NSRunningApplication.current : nil) {
                let name = application.localizedName ?? "<unknown>"
                let bundle = application.bundleIdentifier ?? "<unknown>"
                print("  PID: \(pid) (\(name), \(bundle))")
            } else {
                print("  PID: \(pid)")
            }
        } else {
            print("  PID: unknown")
        }
        if let screenId, let screenDescriptor {
            print("  Screen: \(screenDescriptor.localizedName) [\(screenId)]")
        } else {
            print("  Screen: unknown")
        }
        print("  Zone: \(managed.zoneIndex?.description ?? "none (minimized)")")
        print("  Actual frame: \(actualFrame)")

        if let zoneIndex = managed.zoneIndex,
           let screenId = managed.screenDisplayId,
           let zone = screenContexts[screenId]?.zoneController.zone(at: zoneIndex) {
            print("  Zone frame: \(zone.frame)")
        }
        print("")
    }

    func printFrames() {
        print("\nAll window frames:")
        for window in windowController.allWindows {
            let type: String
            if window.isPlaceholder {
                type = "placeholder"
            } else {
                switch window.backing {
                case .appKit:
                    type = "test"
                case .accessibility:
                    type = "external"
                }
            }
            let screenId = window.screenDisplayId ?? detectScreenId(for: window)
            let screenDescriptor = screenId.flatMap { (id: CGDirectDisplayID) -> ScreenDescriptor? in
                descriptor(for: id)
            }
            let actualFrame: CGRect
            if let screenDescriptor {
                actualFrame = windowController.actualFrameInScreenCoordinates(for: window, on: screenDescriptor)
            } else if let fallback = windowController.actualFrameInScreenCoordinates(for: window) {
                actualFrame = fallback
            } else {
                actualFrame = .zero
            }
            if let screenId, let screenDescriptor {
                print("  Window \(window.windowId) (\(type)) on \(screenDescriptor.localizedName) [\(screenId)]: \(actualFrame)")
            } else {
                print("  Window \(window.windowId) (\(type)) on unknown screen: \(actualFrame)")
            }
        }
        print("")
    }

    // MARK: - JSON API for Socket Server

    func addZoneJSON() -> [String: Any] {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId],
              let newZone = context.zoneController.addZone() else {
            return ["error": "Failed to add zone (max 3 zones)"]
        }
        syncWindowsToZones()
        return [
            "screen_display_id": screenId,
            "screen_name": context.descriptor.localizedName,
            "zone_index": newZone.index,
            "zone_count": context.zoneController.allZones.count
        ]
    }

    func removeZoneJSON(at index: Int) -> [String: Any] {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId],
              let removalResult = performRemoveZone(at: index, on: screenId, announce: false, context: context) else {
            return ["error": "Failed to remove zone \(index)"]
        }

        var response: [String: Any] = [
            "screen_display_id": screenId,
            "screen_name": context.descriptor.localizedName,
            "removed_index": index,
            "zone_count": context.zoneController.allZones.count,
            "removed_window_id": removalResult.removedWindowId as Any
        ]

        if let removedWindowId = removalResult.removedWindowId,
           let managed = windowController.window(withId: removedWindowId) {
            response["reassigned_window_id"] = managed.windowId
            response["reassigned_zone_index"] = managed.zoneIndex as Any
            response["reassigned_screen_display_id"] = managed.screenDisplayId as Any
        }

        return response
    }

    func resizeZoneJSON(at index: Int, frame: CGRect) -> [String: Any] {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId] else {
            return ["error": "Active screen not available"]
        }

        guard let zone = context.zoneController.zone(at: index) else {
            return ["error": "Zone \(index) not found on \(context.descriptor.localizedName)"]
        }

        guard zone.isEmpty else {
            return ["error": "Zone \(index) is occupied; minimize or close its window before resizing."]
        }

        guard context.zoneController.resizeZone(at: index, to: frame) else {
            return ["error": "Failed to resize zone \(index)"]
        }

        syncWindowsToZones()

        guard let updatedZone = context.zoneController.zone(at: index) else {
            return ["error": "Zone \(index) unavailable after resize"]
        }

        return [
            "screen_display_id": screenId,
            "screen_name": context.descriptor.localizedName,
            "zone_index": updatedZone.index,
            "frame": [
                "x": updatedZone.frame.origin.x,
                "y": updatedZone.frame.origin.y,
                "width": updatedZone.frame.width,
                "height": updatedZone.frame.height
            ],
            "zone_count": context.zoneController.allZones.count
        ]
    }

    func createWindowJSON() -> [String: Any] {
        let managed = windowController.createTestWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        placeNewWindow(managed)
        return [
            "window_id": managed.windowId,
            "zone_index": managed.zoneIndex as Any,
            "screen_display_id": managed.screenDisplayId as Any
        ]
    }

    func captureFrontmostWindowJSON() -> [String: Any] {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let bundleId = frontmost.bundleIdentifier,
           configuration.ignoredBundleIdentifiers.contains(bundleId) {
            return ["error": "Frontmost application \(bundleId) is configured to be ignored"]
        }

        guard let managed = windowController.captureFrontmostWindow() else {
            return ["error": "No frontmost window available or Accessibility permissions missing"]
        }

        if let zoneIndex = managed.zoneIndex,
           let screenId = managed.screenDisplayId,
           let zone = screenContexts[screenId]?.zoneController.zone(at: zoneIndex),
           zone.windowId == managed.windowId {
            syncWindowsToZones()
            return [
                "window_id": managed.windowId,
                "zone_index": zoneIndex,
                "screen_display_id": screenId,
                "screen_name": screenContexts[screenId]?.descriptor.localizedName as Any,
                "message": "Already managed"
            ]
        }

        placeNewWindow(managed)

        return [
            "window_id": managed.windowId,
            "zone_index": managed.zoneIndex as Any,
            "screen_display_id": managed.screenDisplayId as Any
        ]
    }

    func closeWindowJSON(withId windowId: Int) -> [String: Any] {
        guard let managed = windowController.window(withId: windowId) else {
            return ["error": "Window \(windowId) not found"]
        }

        removeWindowFromAllZones(windowId: windowId, reason: "socket-close-window")
        windowController.closeWindow(managed)
        syncWindowsToZones()

        return ["window_id": windowId]
    }

    func minimizeWindowJSON(withId windowId: Int) -> [String: Any] {
        guard let managed = windowController.window(withId: windowId) else {
            return ["error": "Window \(windowId) not found"]
        }

        windowController.minimizeWindow(managed)
        removeWindowFromAllZones(windowId: windowId, reason: "socket-minimize")
        syncWindowsToZones()

        return ["window_id": windowId]
    }

    func unminimizeWindowJSON(withId windowId: Int) -> [String: Any] {
        guard let managed = windowController.window(withId: windowId) else {
            return ["error": "Window \(windowId) not found"]
        }

        windowController.unminimizeWindow(managed)
        placeNewWindow(managed)

        return [
            "window_id": windowId,
            "zone_index": managed.zoneIndex as Any,
            "screen_display_id": managed.screenDisplayId as Any
        ]
    }

    func listZonesJSON() -> [String: Any] {
        let zones = screenOrder.flatMap { screenId -> [[String: Any]] in
            guard let context = screenContexts[screenId] else { return [] }
            return context.zoneController.allZones.map { zone in
                [
                    "screen_display_id": screenId,
                    "screen_name": context.descriptor.localizedName,
                    "index": zone.index,
                    "window_id": zone.windowId as Any,
                    "frame": [
                        "x": zone.frame.origin.x,
                        "y": zone.frame.origin.y,
                        "width": zone.frame.width,
                        "height": zone.frame.height
                    ]
                ]
            }
        }
        return ["zones": zones]
    }

    func relayoutJSON() -> [String: Any] {
        for context in screenContexts.values {
            context.zoneController.relayout()
        }
        syncWindowsToZones()
        let screenSummaries = screenOrder.compactMap { screenId -> [String: Any]? in
            guard let context = screenContexts[screenId] else { return nil }
            return [
                "screen_display_id": screenId,
                "screen_name": context.descriptor.localizedName,
                "zone_count": context.zoneController.allZones.count
            ]
        }
        return ["screens": screenSummaries]
    }

    func windowInfoJSON(windowId: Int) -> [String: Any] {
        guard let managed = windowController.window(withId: windowId) else {
            return ["error": "Window \(windowId) not found"]
        }

        let type: String
        if managed.isPlaceholder {
            type = "placeholder"
        } else {
            switch managed.backing {
            case .appKit:
                type = "test"
            case .accessibility:
                type = "external"
            }
        }

        let screenId = managed.screenDisplayId ?? detectScreenId(for: managed)
        let screenDescriptor = screenId.flatMap { (id: CGDirectDisplayID) -> ScreenDescriptor? in
            descriptor(for: id)
        }
        let actualFrame: CGRect
        if let screenDescriptor {
            actualFrame = windowController.actualFrameInScreenCoordinates(for: managed, on: screenDescriptor)
        } else if let fallback = windowController.actualFrameInScreenCoordinates(for: managed) {
            actualFrame = fallback
        } else {
            actualFrame = .zero
        }

        var result: [String: Any] = [
            "window_id": windowId,
            "type": type,
            "is_placeholder": managed.isPlaceholder,
            "zone_index": managed.zoneIndex as Any,
            "actual_frame": [
                "x": actualFrame.origin.x,
                "y": actualFrame.origin.y,
                "width": actualFrame.width,
                "height": actualFrame.height
            ]
        ]

        var owningPid: pid_t?
        switch managed.backing {
        case .appKit:
            owningPid = getpid()
        case .accessibility(_, let pid, _):
            owningPid = pid
        }

        if let pid = owningPid {
            result["pid"] = Int(pid)

            if let application = NSRunningApplication(processIdentifier: pid) ?? (pid == getpid() ? NSRunningApplication.current : nil) {
                if let name = application.localizedName {
                    result["application_name"] = name
                }
                if let bundleId = application.bundleIdentifier {
                    result["bundle_identifier"] = bundleId
                }
            }
        }

        if let screenId, let screenDescriptor {
            result["screen_display_id"] = screenId
            result["screen_name"] = screenDescriptor.localizedName
        }

        if let zoneIndex = managed.zoneIndex,
           let screenId = managed.screenDisplayId,
           let zone = screenContexts[screenId]?.zoneController.zone(at: zoneIndex) {
            result["zone_frame"] = [
                "x": zone.frame.origin.x,
                "y": zone.frame.origin.y,
                "width": zone.frame.width,
                "height": zone.frame.height
            ]
        }

        switch managed.backing {
        case .accessibility(_, _, let windowNumber?):
            result["window_number"] = windowNumber
        default:
            break
        }

        return result
    }

    func managedWindowsJSON() -> [String: Any] {
        let windows = windowController.allWindows
            .sorted { $0.windowId < $1.windowId }
            .map { managed -> [String: Any] in
                windowInfoJSON(windowId: managed.windowId)
            }

        var response: [String: Any] = ["windows": windows]

        if let targeted = targetedZoneKey,
           let descriptor = descriptor(for: targeted.screenId) {
            response["targeted_zone"] = [
                "screen_display_id": targeted.screenId,
                "screen_name": descriptor.localizedName,
                "index": targeted.index
            ]
        }

        return response
    }

    func validateApplicationJSON(pid: pid_t) -> [String: Any] {
        let prunedIds = validateWindowsForApplication(pid: pid, reason: "socket-request")
        return [
            "pid": Int(pid),
            "pruned_window_ids": prunedIds
        ]
    }

    func printFramesJSON() -> [String: Any] {
        let frames = windowController.allWindows.map { window -> [String: Any] in
            let type: String
            if window.isPlaceholder {
                type = "placeholder"
            } else {
                switch window.backing {
                case .appKit:
                    type = "test"
                case .accessibility:
                    type = "external"
                }
            }
            let screenId = window.screenDisplayId ?? detectScreenId(for: window)
            let screenDescriptor = screenId.flatMap { (id: CGDirectDisplayID) -> ScreenDescriptor? in
                descriptor(for: id)
            }
            let actualFrame: CGRect
            if let screenDescriptor {
                actualFrame = windowController.actualFrameInScreenCoordinates(for: window, on: screenDescriptor)
            } else if let fallback = windowController.actualFrameInScreenCoordinates(for: window) {
                actualFrame = fallback
            } else {
                actualFrame = .zero
            }
            return [
                "window_id": window.windowId,
                "type": type,
                "is_placeholder": window.isPlaceholder,
                "screen_display_id": screenId as Any,
                "screen_name": screenDescriptor?.localizedName as Any,
                "frame": [
                    "x": actualFrame.origin.x,
                    "y": actualFrame.origin.y,
                    "width": actualFrame.width,
                    "height": actualFrame.height
                ]
            ]
        }
        return ["windows": frames]
    }
}
