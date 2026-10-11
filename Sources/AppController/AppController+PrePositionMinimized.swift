/// Pre-positioning of minimized windows: moving a minimized window's frame to its destination zone
/// before it is unminimized, so the unminimize animation reveals the window already in place. The
/// frame comes from Zonogy's records, and the writes are marked as Zonogy's own.
///
/// Zonogy's own unminimizes (Launcher selection, WinShot restore, cursor-driven drops, floating
/// drag revert) go through `unminimizeWithPrePositioning`, which keeps the pre-position step and the
/// toggle-aware unminimize paired so the flows cannot drift apart. An application may also unminimize
/// a window itself when the user clicks one of its notifications; its minimized windows are
/// pre-positioned when the press lands, before Notification Center passes the click on. Both can be
/// disabled via the Debug preferences toggle.
import ApplicationServices
import CoreGraphics
import Foundation

extension AppController {
    /// Pre-positions `managed` (if a target frame is provided) and unminimizes it,
    /// threading the debug toggle so all flows behave identically.
    ///
    /// When the "Disable pre-position before unminimize" debug toggle is on:
    /// - Pre-positioning is skipped.
    /// - Unminimize runs synchronously, so any post-unminimize frame writes from the
    ///   caller hit a window that is already unminimized.
    ///
    /// When the toggle is off:
    /// - Pre-positioning writes the target frame to the still-minimized window.
    /// - Unminimize is dispatched asynchronously after a small settle delay so the
    ///   pre-position writes are visible before the unminimize animation begins.
    ///
    /// - Parameters:
    ///   - managed: The minimized managed window.
    ///   - targetFrame: Target frame in screen coordinates. Pre-positioning is skipped
    ///     when this (or `screen`) is nil — useful for callers that position the window
    ///     after unminimize via a different code path (e.g., `WindowController.showWindow`).
    ///   - screen: Descriptor for the destination screen (used for coordinate conversion).
    ///   - reason: Short tag for log messages identifying the calling flow.
    ///   - focusAfterPlacement: When true, the deminiaturize handling will focus the
    ///     window that becomes visible after placement or native-tab adoption settles.
    internal func unminimizeWithPrePositioning(
        _ managed: ManagedWindow,
        targetFrame: CGRect? = nil,
        on screen: ScreenDescriptor? = nil,
        reason: String,
        focusAfterPlacement: Bool = false
    ) {
        if let targetFrame, let screen {
            prePositionMinimizedWindow(managed, to: targetFrame, on: screen, reason: reason)
        }
        if focusAfterPlacement {
            pendingExplicitUnminimizeFocusWindowIds.insert(managed.windowId)
        }
        windowController.unminimizeWindow(
            managed,
            synchronous: isDisablePrePositionBeforeUnminimizeInSettings
        )
    }

    /// The frame `managed` takes when placed into `destination`, from Zonogy's records, to
    /// pre-position it there.
    internal func prePositionFrame(
        for managed: ManagedWindow,
        in destination: TargetedZoneManager.TargetedDestination
    ) -> (frame: CGRect, descriptor: ScreenDescriptor)? {
        switch destination {
        case .floating(let screenId):
            guard let descriptor = descriptor(for: screenId),
                  let frame = floatingZoneCoordinator.computePlacementFrame(for: managed, on: screenId) else {
                return nil
            }
            return (frame, descriptor)
        case .tiled(let targetedKey):
            guard let context = screenContexts[targetedKey.screenId],
                  let descriptor = descriptor(for: targetedKey.screenId),
                  let zone = context.zoneController.zone(at: targetedKey.index) else {
                return nil
            }
            return (frameWithMargin(for: zone, in: context.zoneController), descriptor)
        }
    }

    /// Writes `screenFrame` to the still-minimized `managed`, asking the application nothing (a
    /// width-preserving application's width comes from Zonogy's records too). The writes are marked as
    /// Zonogy's own, so the moves and resizes they cause are neither taken for the user's nor read
    /// back while the window is in no zone, when its application may be busy restoring it.
    ///
    /// Zonogy's own unminimize follows a short settle delay that only works once the application has
    /// handled the writes, so it waits for each answer; `waitingForApplication: false` sends them
    /// without waiting (see the notification-press path below).
    private func prePositionMinimizedWindow(
        _ managed: ManagedWindow,
        to screenFrame: CGRect,
        on screen: ScreenDescriptor,
        reason: String,
        waitingForApplication: Bool = true
    ) {
        if isDisablePrePositionBeforeUnminimizeInSettings {
            Logger.debug("Pre-position skipped for window \(managed.windowId) (\(reason), debug toggle)")
            return
        }

        let effectiveScreenFrame = windowController.resolvedTargetScreenFrame(
            for: managed,
            requestedFrame: screenFrame,
            on: screen,
            currentScreenFrame: managed.cachedFrame.map(screen.accessibilityToScreen)
        )
        let element = managed.backing.element
        let accessibilityFrame = screen.screenToAccessibility(effectiveScreenFrame)

        // Size, position, then size again. An application can drop the height change written
        // after moving a minimized window to another display, so the size goes first; the final
        // write keeps position-then-size as the tail for moves where that order works.
        //
        // Without waiting, each write returns within about 1 ms of being sent, answered or not. That
        // is best effort: nothing confirms the application handles the requests, though Messages
        // and Slack were seen to handle all three in order. Waiting for each answer holds up the
        // caller while an application that is slow to resize (Messages lays out its window again on
        // every size write) handles each one.
        let apply = {
            var size = accessibilityFrame.size
            var position = accessibilityFrame.origin
            guard let sizeValue = AXValueCreate(.cgSize, &size),
                  let positionValue = AXValueCreate(.cgPoint, &position) else {
                return
            }
            if !waitingForApplication {
                AXUIElementSetMessagingTimeout(element, 0.001)
            }
            _ = AXCall.setAttribute(element, kAXSizeAttribute as CFString, sizeValue)
            _ = AXCall.setAttribute(element, kAXPositionAttribute as CFString, positionValue)
            _ = AXCall.setAttribute(element, kAXSizeAttribute as CFString, sizeValue)
            if !waitingForApplication {
                AXUIElementSetMessagingTimeout(element, 0)  // back to the global timeout
            }
        }

        windowController.performProgrammaticUpdate(for: managed.windowId, apply)

        if waitingForApplication {
            Logger.debug("Pre-positioned minimized window \(managed.windowId) to \(effectiveScreenFrame) (\(reason))")
        } else {
            Logger.debug("Sent pre-position writes for minimized window \(managed.windowId) to \(effectiveScreenFrame) (\(reason), not waiting for the application)")
        }
    }
}

// MARK: - Before an application's own unminimize

extension AppController {
    /// The user is pressing a notification of `pid`, which may then restore one of its minimized
    /// windows itself. Pre-position each of them to the frame it would take in the targeted zone
    /// (whichever one is restored goes there), so a restored window animates straight into its zone.
    ///
    /// The press waits for this, and a napping application can take tens of milliseconds to answer,
    /// so nothing here waits on the application: its minimized windows come from Zonogy's records
    /// (its managed windows in no zone, other than a full-screen one and a displaced one still
    /// visible until its deferred minimize; see `ManagedWindow.isPlacedInZone`), and the writes go
    /// out without waiting for answers. They are sent before Notification Center receives the press.
    internal func prePositionMinimizedWindows(ofApplication pid: pid_t, reason: String) {
        guard !sleepWakeProtectionActive else { return }
        // Most recent first: the window the application most likely restores gets its writes first.
        let minimized = windowController.allWindowsOrderedByRecency().filter {
            $0.backing.pid == pid && !$0.isPlacedInZone && !isTrackedFullScreenWindow($0)
                && !deferredMinimizationCoordinator.isPending(windowId: $0.windowId)
        }
        Logger.debug("Pre-positioning \(minimized.count) minimized window(s) of pid \(pid) (\(reason))")
        guard !minimized.isEmpty else { return }
        guard isTargetedDisplayAvailableForPlacement(),
              let destination = targetedZoneManager.targetedDestination else {
            Logger.debug("Minimized windows of pid \(pid) not pre-positioned (\(reason), no targeted display available)")
            return
        }
        for managed in minimized {
            guard let target = prePositionFrame(for: managed, in: destination) else {
                continue
            }
            prePositionMinimizedWindow(
                managed,
                to: target.frame,
                on: target.descriptor,
                reason: reason,
                waitingForApplication: false
            )
        }
    }
}
