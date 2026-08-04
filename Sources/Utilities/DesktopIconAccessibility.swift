import ApplicationServices
import AppKit

/// Reads desktop icon frames from Finder's accessibility hierarchy.
///
/// Structure (verified on macOS 15): Finder's application element holds one AXScrollArea per
/// display (the desktop); each contains a display-sized AXGroup whose AXImage children are the
/// icons. An icon's AX frame covers only the icon image — the filename label below it has no
/// accessibility element (its extent lives solely in Finder's hit-testing) — so callers that
/// want the label area must approximate it. Non-file desktop elements (e.g. widget regions)
/// report other roles and are skipped.
enum DesktopIconAccessibility {
    /// Returns the frame of every desktop icon in screen coordinates (y:0 at the primary
    /// screen's top-left, the space AX and WindowServer geometry share). Returns nil whenever
    /// the walk cannot vouch for completeness — Finder not running, no desktop scroll area
    /// present, a scroll area missing its desktop group, or any element read failing mid-walk
    /// (Finder mid-relaunch, AX hiccup) — so callers can distinguish "no icons" from "couldn't
    /// look" and keep their previous snapshot. An empty array is returned only when every
    /// level of the hierarchy read completely and there were genuinely no icons.
    static func iconFrames() -> [CGRect]? {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(finder.processIdentifier)
        guard let appChildren = children(of: appElement) else {
            return nil
        }

        var frames: [CGRect] = []
        var foundScrollArea = false
        for child in appChildren {
            guard let childRole = role(of: child) else {
                return nil
            }
            guard childRole == kAXScrollAreaRole else {
                continue
            }
            foundScrollArea = true
            guard let desktopGroups = children(of: child), !desktopGroups.isEmpty else {
                // The desktop scroll area always holds a desktop group; its absence means
                // Finder is mid-rebuild, not that the Desktop is empty.
                return nil
            }
            for desktopGroup in desktopGroups {
                guard let iconCandidates = children(of: desktopGroup) else {
                    return nil
                }
                for candidate in iconCandidates {
                    switch classify(candidate) {
                    case .image(let frame):
                        frames.append(frame)
                    case .nonImage:
                        continue
                    case .unreadable:
                        // Can't prove this element isn't an icon; don't let a partial
                        // walk masquerade as a complete snapshot.
                        return nil
                    }
                }
            }
        }
        guard foundScrollArea else {
            return nil
        }
        return frames
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXCall.copyAttribute(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement]
    }

    private static func role(of element: AXUIElement) -> String? {
        copyAttribute(element, kAXRoleAttribute) as? String
    }

    /// One desktop-group child, classified: a readable icon with its frame, a readable
    /// non-icon element (e.g. a widget region), or an element the walk could not vouch for.
    private enum IconCandidate {
        case image(CGRect)
        case nonImage
        case unreadable
    }

    /// Reads role, position, and size in a single AX round-trip. `.nonImage` requires a
    /// successfully read role — anything short of proof (batch failure, unreadable role, or
    /// an icon whose geometry can't be decoded) is `.unreadable` so the caller can treat the
    /// walk as incomplete rather than silently dropping an icon.
    private static func classify(_ element: AXUIElement) -> IconCandidate {
        let attributes = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute] as CFArray
        var valuesArray: CFArray?
        // Empty options: don't stop on per-attribute errors; failed entries arrive as
        // AXValue error placeholders and fail the type checks below.
        guard AXCall.copyMultipleAttributes(element, attributes, AXCopyMultipleAttributeOptions(), &valuesArray) == .success,
              let values = valuesArray as? [AnyObject], values.count == 3 else {
            return .unreadable
        }
        guard let role = values[0] as? String else {
            return .unreadable
        }
        guard role == kAXImageRole else {
            return .nonImage
        }
        guard CFGetTypeID(values[1]) == AXValueGetTypeID(),
              CFGetTypeID(values[2]) == AXValueGetTypeID() else {
            return .unreadable
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(values[1] as! AXValue, .cgPoint, &position),
              AXValueGetValue(values[2] as! AXValue, .cgSize, &size) else {
            return .unreadable
        }
        return .image(CGRect(origin: position, size: size))
    }
}
