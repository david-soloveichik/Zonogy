import Foundation

/// Decides how to handle an `AXUIElementDestroyed` notification for a tracked window.
///
/// An `AXUIElementDestroyed` notification reports that an *accessibility element* went
/// away — not necessarily the window. Some apps (e.g. Finder) emit it while the window
/// stays open, sometimes keeping the same element valid and sometimes recycling in a
/// fresh one. The WindowServer is the ground truth for whether the window still exists;
/// combined with whether we can still hold a live element for it, this pure policy maps
/// the situation to an action so the (OS-dependent) handler stays a thin shell over it.
enum SpuriousDestroyPolicy {
    enum Resolution: Equatable {
        /// The window is gone (or still listed but no live element can be bound):
        /// proceed with deferred pruning.
        case prune
        /// The window is still present and the element we already hold still works:
        /// keep it and leave the window in its zone.
        case keepCurrentElement
        /// The window is still present but our element is dead: rebind to the fresh
        /// element the application recycled in and leave the window in its zone.
        case rebindToReplacement
    }

    /// - Parameters:
    ///   - windowStillListed: Whether the WindowServer still lists the window's `(pid, CGWindowID)`.
    ///   - currentElementResolves: Whether the element we currently hold still resolves to the window.
    ///   - replacementElementAvailable: Whether a *different* live element for the window could be found.
    static func resolve(
        windowStillListed: Bool,
        currentElementResolves: Bool,
        replacementElementAvailable: Bool
    ) -> Resolution {
        guard windowStillListed else {
            return .prune
        }
        if currentElementResolves {
            return .keepCurrentElement
        }
        if replacementElementAvailable {
            return .rebindToReplacement
        }
        return .prune
    }
}
