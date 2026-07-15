import AppKit
import Foundation

/// Control-Command + arrow-key window-focus navigation: builds the navigable window set, resolves the
/// selection as the gesture proceeds, marks it with the blue-dot overlay, and focuses it on release.
/// The gesture lifecycle is driven by `WindowFocusNavigationInterceptor`; the selection geometry is
/// the pure `WindowFocusNavigation`.
extension AppController {
    /// Live state for an in-progress window-focus gesture. Candidates are snapshotted at engage time
    /// so the dot stays stable for the (brief) duration of the gesture.
    struct WindowFocusNavigationState {
        let candidates: [WindowFocusNavigation.Candidate]
        let anchor: WindowFocusNavigation.Anchor
        var selection: WindowFocusNavigation.Selection?
    }
}

extension AppController: WindowFocusNavigationInterceptorDelegate {
    func windowFocusNavigationShouldHandleEvents(_ interceptor: WindowFocusNavigationInterceptor) -> Bool {
        !hotkeyService.isSuspended && !sleepWakeProtectionActive
    }

    func windowFocusNavigationShouldBegin(_ interceptor: WindowFocusNavigationInterceptor) -> Bool {
        // Don't start a focus gesture while a chooser owns the keyboard/overlay space, or when there
        // is no window to focus — declining keeps the arrow keys from being swallowed for nothing.
        // This runs synchronously in the event-tap callback, so the check stays cheap (no AX reads).
        !launcherController.isActive
            && !cmdTabController.isActive
            && !winShotChooserController.isActive
            && hasNavigableFocusWindow()
    }

    func windowFocusNavigation(_ interceptor: WindowFocusNavigationInterceptor, didBegin direction: ZoneNavigationDirection) {
        beginWindowFocusNavigation(direction: direction)
    }

    func windowFocusNavigation(_ interceptor: WindowFocusNavigationInterceptor, didMove direction: ZoneNavigationDirection) {
        moveWindowFocusNavigation(direction: direction)
    }

    func windowFocusNavigationDidCommit(_ interceptor: WindowFocusNavigationInterceptor) {
        commitWindowFocusNavigation()
    }

    func windowFocusNavigationDidCancel(_ interceptor: WindowFocusNavigationInterceptor) {
        cancelWindowFocusNavigation(reason: "interceptor-cancel")
    }
}

extension AppController {
    private func beginWindowFocusNavigation(direction: ZoneNavigationDirection) {
        let candidates = windowFocusNavigationCandidates()
        guard !candidates.isEmpty else {
            // `shouldBegin` already gates on `hasNavigableFocusWindow()`, so this only happens if the
            // windows vanished (or their frames became unreadable) between engaging and now. Drop the
            // interceptor's engaged state too so it stops swallowing arrows for a dead session.
            Logger.debug("Window-focus navigation (\(direction)): no filled windows to navigate; ignoring")
            windowFocusNavigationInterceptor.resetEngagement()
            clearWindowFocusNavigation()
            return
        }

        let resolved = windowFocusNavigationAnchor(candidates: candidates)
        let selection = WindowFocusNavigation.initialSelection(
            direction: direction,
            focusedWindowId: resolved.focusedWindowId,
            anchor: resolved.anchor,
            targetOccupantWindowId: resolved.targetOccupantWindowId,
            candidates: candidates
        )

        windowFocusNavigationState = WindowFocusNavigationState(
            candidates: candidates,
            anchor: resolved.anchor,
            selection: selection
        )
        updateWindowFocusDot(selection: selection)
        Logger.debug("Window-focus navigation begun (\(direction)); selection: \(selection.map { String($0.windowId) } ?? "none")")
    }

    private func moveWindowFocusNavigation(direction: ZoneNavigationDirection) {
        guard var state = windowFocusNavigationState else { return }
        let next = WindowFocusNavigation.nextSelection(
            direction: direction,
            currentSelection: state.selection,
            anchor: state.anchor,
            candidates: state.candidates
        )
        state.selection = next
        windowFocusNavigationState = state
        updateWindowFocusDot(selection: next)
    }

    private func commitWindowFocusNavigation() {
        guard let state = windowFocusNavigationState else { return }
        clearWindowFocusNavigation()

        guard let selection = state.selection,
              let managed = windowController.window(withId: selection.windowId) else {
            Logger.debug("Window-focus navigation committed with no selection")
            return
        }

        // Focus only — targeting is intentionally left unchanged. Mirror the activation path used by
        // "Focus the targeted zone's window": floating occupants take the floating-zone raise path.
        Logger.debug("Window-focus navigation focusing window \(selection.windowId)")
        if managed.isInFloatingZone {
            activateFloatingZoneWindow(managed, reason: "window-focus-navigation")
        } else {
            raiseWindow(managed)
        }
    }

    /// Drop the gesture without focusing and tear down the dot.
    internal func cancelWindowFocusNavigation(reason: String) {
        guard windowFocusNavigationState != nil else { return }
        Logger.debug("Window-focus navigation cancelled (\(reason))")
        clearWindowFocusNavigation()
    }

    private func clearWindowFocusNavigation() {
        windowFocusNavigationState = nil
        windowFocusDotOverlay.hide()
    }

    /// Cheap "is there anything to focus?" check used to gate engagement synchronously in the
    /// event-tap callback. Mirrors `windowFocusNavigationCandidates` minus the AX frame reads.
    private func hasNavigableFocusWindow() -> Bool {
        for screenId in screenOrder {
            guard !isScreenPausedForFullScreen(screenId), let context = screenContexts[screenId] else {
                continue
            }
            if context.zoneController.allZones.contains(where: { $0.occupantWindowId != nil }) {
                return true
            }
            if floatingZoneOccupant(on: screenId) != nil {
                return true
            }
        }
        return false
    }

    /// Every window occupying a filled zone — each tiling-zone occupant plus each screen's
    /// floating-zone occupant — by its actual rectangle in accessibility coordinates. Skips every
    /// screen paused for a full-screen window (including the all-screens-full-screen fallback that
    /// target navigation keeps reachable), per the spec's "skip paused screens" rule.
    private func windowFocusNavigationCandidates() -> [WindowFocusNavigation.Candidate] {
        var candidates: [WindowFocusNavigation.Candidate] = []
        for screenId in screenOrder {
            guard !isScreenPausedForFullScreen(screenId),
                  let context = screenContexts[screenId] else {
                continue
            }
            for zone in context.zoneController.allZones {
                guard let windowId = zone.occupantWindowId,
                      let managed = windowController.window(withId: windowId),
                      let frame = windowController.actualFrameInAccessibilityCoordinates(for: managed) else {
                    continue
                }
                candidates.append(.init(
                    windowId: windowId,
                    frame: frame,
                    screenId: screenId,
                    isFloating: false,
                    zoneIndex: zone.index
                ))
            }
            if let managed = floatingZoneOccupant(on: screenId),
               let frame = windowController.actualFrameInAccessibilityCoordinates(for: managed) {
                candidates.append(.init(
                    windowId: managed.windowId,
                    frame: frame,
                    screenId: screenId,
                    isFloating: true,
                    zoneIndex: nil
                ))
            }
        }
        return candidates
    }

    /// Resolves where navigation starts: the focused managed window when it is among the candidates,
    /// otherwise the targeted zone (its rectangle plus its occupant, if any).
    private func windowFocusNavigationAnchor(
        candidates: [WindowFocusNavigation.Candidate]
    ) -> (anchor: WindowFocusNavigation.Anchor, focusedWindowId: Int?, targetOccupantWindowId: Int?) {
        func anchor(at candidate: WindowFocusNavigation.Candidate) -> WindowFocusNavigation.Anchor {
            .init(frame: candidate.frame, screenId: candidate.screenId)
        }

        if let focusedId = currentFrontmostManagedWindowId,
           let focused = candidates.first(where: { $0.windowId == focusedId }) {
            return (anchor(at: focused), focusedId, nil)
        }

        func candidateOccupant(_ windowId: Int?) -> Int? {
            guard let windowId, candidates.contains(where: { $0.windowId == windowId }) else { return nil }
            return windowId
        }

        if let key = targetedZoneKey,
           let context = screenContexts[key.screenId],
           let zone = context.zoneController.zone(at: key.index) {
            let frame = context.descriptor.screenToAccessibility(zone.frame)
            return (
                .init(frame: frame, screenId: key.screenId),
                nil,
                candidateOccupant(zone.occupantWindowId)
            )
        }

        if let screenId = targetedFloatingScreenId,
           let descriptor = descriptor(for: screenId),
           let frames = floatingIndicatorFrames(for: descriptor) {
            return (
                .init(frame: frames.accessibility, screenId: screenId),
                nil,
                candidateOccupant(floatingZoneOccupant(on: screenId)?.windowId)
            )
        }

        // No focused window and no resolvable target: anchor at the first candidate so a direction
        // press can still reach a neighbor.
        return (anchor(at: candidates[0]), nil, nil)
    }

    private func updateWindowFocusDot(selection: WindowFocusNavigation.Selection?) {
        guard let selection,
              let candidate = windowFocusNavigationState?.candidates.first(where: { $0.windowId == selection.windowId }),
              let descriptor = descriptor(for: candidate.screenId) else {
            windowFocusDotOverlay.hide()
            return
        }
        let screenFrame = descriptor.accessibilityToScreen(candidate.frame)
        let cocoaFrame = descriptor.screenToCocoa(screenFrame)
        windowFocusDotOverlay.show(centeredIn: cocoaFrame)
    }
}
