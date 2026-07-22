import Foundation

/// Decides how to handle a tracked window whose cached Accessibility element may be stale.
///
/// An `AXUIElementDestroyed` notification or failed AX read only proves that an
/// *accessibility element* is unavailable — not necessarily that the window is gone.
/// Some apps recycle elements in place, AX can become temporarily unavailable while the
/// login screen is active, and some apps leave a closed window registered with WindowServer.
/// This pure policy combines the available WindowServer and AX evidence into a safe action.
enum SpuriousDestroyPolicy {
    enum ReplacementLookup: Equatable {
        /// A fresh AX element still resolves to the tracked CGWindowID.
        case available
        /// AX returned a complete application-window list without the tracked CGWindowID.
        case absent
        /// AX could not provide a complete, inspectable application-window list.
        case unavailable
    }

    enum Resolution: Equatable {
        /// The combined evidence confirms that the application window is gone.
        case prune
        /// The window is still present and the element we already hold still works:
        /// keep it and leave the window in its zone.
        case keepCurrentElement
        /// The window is still present but our element is dead: rebind to the fresh
        /// element the application recycled in and leave the window in its zone.
        case rebindToReplacement
        /// WindowServer still lists the surface, but AX cannot provide conclusive evidence.
        /// Keep the managed identity and zone until stronger liveness evidence arrives.
        case preserve
    }

    /// - Parameters:
    ///   - windowStillListed: Whether the WindowServer still lists the window's `(pid, CGWindowID)`.
    ///   - currentElementResolves: Whether the element we currently hold still resolves to the window.
    ///   - replacementLookup: Result of looking for a *different* live element for the window.
    ///   - confirmedAXAbsenceIsAuthoritative: Whether a successful AX absence is backed by an
    ///     explicit destroy notification and may therefore override a stale WindowServer entry.
    static func resolve(
        windowStillListed: Bool,
        currentElementResolves: Bool,
        replacementLookup: ReplacementLookup,
        confirmedAXAbsenceIsAuthoritative: Bool
    ) -> Resolution {
        guard windowStillListed else {
            return .prune
        }
        if currentElementResolves {
            return .keepCurrentElement
        }
        if replacementLookup == .available {
            return .rebindToReplacement
        }
        if replacementLookup == .absent, confirmedAXAbsenceIsAuthoritative {
            return .prune
        }
        return .preserve
    }
}
