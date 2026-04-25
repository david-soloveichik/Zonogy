/// Shared pre-positioning + unminimize sequencing for minimized windows.
///
/// Several flows (Launcher selection, WinShot restore, cursor-driven drops, floating
/// drag revert) move a minimized window's frame to its destination zone before
/// unminimizing it, so the unminimize animation reveals the window already at its
/// target position. This behavior can be disabled via the Debug preferences toggle.
///
/// All such call sites go through `unminimizeWithPrePositioning` so the pre-position
/// step and the toggle-aware synchronous unminimize stay paired. Doing this in one
/// place prevents future drift between sites.
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
    ///   - suppressAXNotifications: When true, the pre-position AX writes run inside
    ///     `performProgrammaticUpdate` so the resulting moved/resized notifications are
    ///     not misclassified as user drags/resizes. Required by WinShot restore.
    ///   - raise: Forwarded to `WindowController.unminimizeWindow`.
    internal func unminimizeWithPrePositioning(
        _ managed: ManagedWindow,
        targetFrame: CGRect? = nil,
        on screen: ScreenDescriptor? = nil,
        reason: String,
        suppressAXNotifications: Bool = false,
        raise: Bool = true
    ) {
        if let targetFrame, let screen {
            prePositionMinimizedWindow(
                managed,
                to: targetFrame,
                on: screen,
                reason: reason,
                suppressAXNotifications: suppressAXNotifications
            )
        }
        windowController.unminimizeWindow(
            managed,
            synchronous: isDisablePrePositionBeforeUnminimizeInSettings,
            raise: raise
        )
    }

    private func prePositionMinimizedWindow(
        _ managed: ManagedWindow,
        to screenFrame: CGRect,
        on screen: ScreenDescriptor,
        reason: String,
        suppressAXNotifications: Bool
    ) {
        if isDisablePrePositionBeforeUnminimizeInSettings {
            Logger.debug("Pre-position skipped for window \(managed.windowId) (\(reason), debug toggle)")
            return
        }

        let effectiveScreenFrame = windowController.resolvedTargetScreenFrame(
            for: managed,
            requestedFrame: screenFrame,
            on: screen
        )
        let element = managed.backing.element
        let accessibilityFrame = screen.screenToAccessibility(effectiveScreenFrame)

        let apply = {
            var position = accessibilityFrame.origin
            if let positionValue = AXValueCreate(.cgPoint, &position) {
                AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
            }
            var size = accessibilityFrame.size
            if let sizeValue = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
            }
        }

        if suppressAXNotifications {
            windowController.performProgrammaticUpdate(for: managed.windowId, apply)
        } else {
            apply()
        }

        Logger.debug("Pre-positioned minimized window \(managed.windowId) to \(effectiveScreenFrame) (\(reason))")
    }
}
