import Foundation

/// Decides how to handle a tracked window whose cached Accessibility element may be stale.
///
/// An `AXUIElementDestroyed` notification or failed AX read only proves that an
/// *accessibility element* is unavailable — not necessarily that the window is gone.
/// Some apps recycle elements in place, and AX can become temporarily unavailable while
/// the login screen is active. WindowServer is the ground truth for whether the window
/// still exists; this pure policy maps the available facts to a safe action.
enum SpuriousDestroyPolicy {
    enum Resolution: Equatable {
        /// WindowServer confirms that the window is gone: proceed with deferred pruning.
        case prune
        /// The window is still present and the element we already hold still works:
        /// keep it and leave the window in its zone.
        case keepCurrentElement
        /// The window is still present but our element is dead: rebind to the fresh
        /// element the application recycled in and leave the window in its zone.
        case rebindToReplacement
        /// The window still exists, but AX cannot currently provide any usable element.
        /// Keep its managed identity and zone until AX recovers or WindowServer removes it.
        case preserve
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
        return .preserve
    }
}
