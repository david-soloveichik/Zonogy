import Foundation
import AppKit
import ApplicationServices

/// Window eligibility checks and validation for management criteria.
extension WindowController {
    /// Check if a window is minimized.
    internal func isWindowMinimized(_ element: AXUIElement) -> Bool {
        var minimizedValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimizedValue)
        guard status == .success, let minimizedValue else {
            return false
        }
        if CFGetTypeID(minimizedValue) == CFBooleanGetTypeID() {
            return CFBooleanGetValue(unsafeBitCast(minimizedValue, to: CFBoolean.self))
        }
        if let number = minimizedValue as? NSNumber {
            return number.boolValue
        }
        return false
    }

    /// Ensure accessibility permissions are granted.
    internal func ensureAccessibilityPermissions() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        if !accessibilityPermissionWarningShown {
            accessibilityPermissionWarningShown = true
            print("Zonogy requires Accessibility access. Enable it in System Settings > Privacy & Security > Accessibility.")
        }
        return false
    }

    /// Check if a window meets the standard window management criteria.
    internal func isStandardWindow(
        _ element: AXUIElement,
        pid: pid_t,
        cgWindowId: CGWindowID,
        skipSubroleCheck: Bool = false
    ) -> Bool {
        let contextPrefix = "isStandardWindow(pid: \(pid), cgWindowId: \(cgWindowId))"

        var roleObject: AnyObject?
        let roleStatus = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleObject)
        guard roleStatus == .success, let role = roleObject as? String, role == kAXWindowRole as String else {
            if roleStatus != .success {
                Logger.debug("\(contextPrefix): Failed to get role attribute, AX error \(roleStatus.rawValue)")
            }
            return false
        }

        var subroleObject: AnyObject?
        let subroleStatus = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleObject)
        if subroleStatus == .success, let subrole = subroleObject as? String {
            if skipSubroleCheck {
                Logger.debug("\(contextPrefix): Skipping subrole check for minimized window (subrole: \(subrole))")
            } else {
                guard subrole == kAXStandardWindowSubrole as String else {
                    Logger.debug("\(contextPrefix): Window has non-standard subrole: \(subrole)")
                    return false
                }
            }
        } else if subroleStatus != .success {
            Logger.debug("\(contextPrefix): Failed to get subrole attribute, AX error \(subroleStatus.rawValue)")
        }

        // By default, manage windows with empty titles; apps can opt out via disallowEmptyTitleWindows
        var titleValue: AnyObject?
        let titleStatus = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
        let windowTitle = (titleStatus == .success) ? (titleValue as? String) ?? "" : ""
        if windowTitle.isEmpty {
            if let app = NSRunningApplication(processIdentifier: pid),
               let bundleId = app.bundleIdentifier,
               applicationExceptionPolicy.disallowsEmptyTitleWindows(forBundleIdentifier: bundleId) {
                Logger.debug("\(contextPrefix): Window has empty title and bundle \(bundleId) disallows empty-title windows")
                return false
            } else {
                Logger.debug("\(contextPrefix): Window has empty title (allowed by default)")
            }
        }

        // Check if this window title is excluded for this app
        if !windowTitle.isEmpty,
           let app = NSRunningApplication(processIdentifier: pid),
           let bundleId = app.bundleIdentifier {
            let excludedTitles = applicationExceptionPolicy.excludedWindowTitles(forBundleIdentifier: bundleId)
            if excludedTitles.contains(windowTitle) {
                Logger.debug("\(contextPrefix): Window title '\(windowTitle)' is excluded for bundle \(bundleId)")
                return false
            }
        }

        // Check isMovable attribute (per SPECIFICATION.md)
        // Use the same approach as winmanmon: check if position is settable
        var isPositionSettable: DarwinBoolean = false
        let settableStatus = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &isPositionSettable)
        if settableStatus != .success || !isPositionSettable.boolValue {
            if settableStatus != .success {
                Logger.debug("\(contextPrefix): Failed to check if position is settable, AX error \(settableStatus.rawValue)")
            } else {
                Logger.debug("\(contextPrefix): Window position is not settable (not movable)")
            }
            return false
        }

        // Check for zoom button (hasZoom) attribute (per SPECIFICATION.md)
        var zoomButtonValue: CFTypeRef?
        let zoomStatus = AXUIElementCopyAttributeValue(element, kAXZoomButtonAttribute as CFString, &zoomButtonValue)

        var hasZoomButton = false
        if zoomStatus == .success {
            if let zoomButtonValue {
                let typeId = CFGetTypeID(zoomButtonValue)
                if typeId == CFNullGetTypeID() {
                    Logger.debug("\(contextPrefix): Zoom button attribute returned CFNull (no zoom button)")
                } else if typeId == AXValueGetTypeID() {
                    let axValue = zoomButtonValue as! AXValue
                    let valueType = AXValueGetType(axValue)
                    let axErrorTypeRawValue: UInt32 = 5  // kAXValueAXErrorType
                    if valueType.rawValue == axErrorTypeRawValue {
                        var underlyingError = AXError.success
                        if AXValueGetValue(axValue, valueType, &underlyingError) {
                            Logger.debug("\(contextPrefix): Zoom button attribute returned AX error \(underlyingError.rawValue)")
                        } else {
                            Logger.debug("\(contextPrefix): Zoom button attribute returned AX error type value without readable code")
                        }
                    } else {
                        hasZoomButton = true
                    }
                } else {
                    hasZoomButton = true
                }
            } else {
                Logger.debug("\(contextPrefix): Zoom button attribute returned nil (no zoom button)")
            }
        } else if zoomStatus == .noValue {
            Logger.debug("\(contextPrefix): Zoom button attribute reports no value (no zoom button)")
        } else {
            Logger.debug("\(contextPrefix): Failed to get zoom button attribute, AX error \(zoomStatus.rawValue)")
        }

        if !hasZoomButton {
            if let app = NSRunningApplication(processIdentifier: pid),
               let bundleId = app.bundleIdentifier,
               applicationExceptionPolicy.ignoresZoomButtonRequirement(forBundleIdentifier: bundleId) {
                Logger.debug("\(contextPrefix): Window has no zoom button, but bundle \(bundleId) is configured to ignore zoom button requirement; treating as standard")
            } else {
                Logger.debug("\(contextPrefix): Window has no zoom button")
                return false
            }
        }

        // Check window height (must be >= 250px tall)
        if let size = ManagedWindow.copyCGSizeValue(element: element, attribute: kAXSizeAttribute as CFString) {
            if size.height < 250 {
                if let app = NSRunningApplication(processIdentifier: pid),
                   let bundleId = app.bundleIdentifier,
                   applicationExceptionPolicy.ignoresHeightRequirement(forBundleIdentifier: bundleId) {
                    Logger.debug("\(contextPrefix): Window height \(size.height) is less than 250px minimum, but bundle \(bundleId) is configured to ignore height requirement; treating as standard")
                } else {
                    Logger.debug("\(contextPrefix): Window height \(size.height) is less than 250px minimum")
                    return false
                }
            }
        } else {
            // If we can't get the size, we treat it as not meeting the criteria
            Logger.debug("\(contextPrefix): Unable to get window size for height check")
            return false
        }

        return true
    }

    // MARK: - CGWindowID Retrieval

    /// Get the external identifier for an accessibility element.
    internal func externalIdentifier(for element: AXUIElement) -> ExternalWindowIdentifier? {
        var pid: pid_t = 0
        let pidStatus = AXUIElementGetPid(element, &pid)
        guard pidStatus == .success else {
            return nil
        }

        let result = cgWindowIdWithStatus(for: element, pid: pid, context: "externalIdentifier")
        guard let cgWindowId = result.id else {
            return nil
        }

        return ExternalWindowIdentifier(pid: pid, cgWindowId: Int(cgWindowId))
    }

    /// Get the CGWindowID for an accessibility element with status information.
    internal func cgWindowIdWithStatus(for element: AXUIElement, pid: pid_t, context: String) -> (id: CGWindowID?, axError: AXError?) {
        var cgWindowId: CGWindowID = 0
        let status = _AXUIElementGetWindow(element, &cgWindowId)
        guard status == .success else {
            Logger.debug("cgWindowId(\(context)): _AXUIElementGetWindow failed for pid \(pid) with AXError \(status.logDescription)")
            return (nil, status)
        }
        guard cgWindowId != 0 else {
            Logger.debug("cgWindowId(\(context)): Received CGWindowID 0 for pid \(pid); treating as missing")
            return (nil, nil)
        }
        return (cgWindowId, nil)
    }

    /// AX errors that indicate a retry may succeed.
    internal var retryableAXWindowErrors: Set<AXError> {
        [.cannotComplete, .illegalArgument]
    }
}
