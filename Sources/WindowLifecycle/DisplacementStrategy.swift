/// Whether a placement should minimize a displaced occupant immediately
/// (`.synchronous`) or queue it through `DeferredMinimizationCoordinator`
/// (`.deferred`).
///
/// `.synchronous` runs the AX minimize before the incoming window is positioned
/// or raised, so any brief visual flash that the AX minimize produces on the
/// displaced window happens while the incoming window is still hidden — keeping
/// the flash invisible. (See `SingleOccupantReplacement` for what we know and
/// don't know about the flash's mechanism; "brief flash to key" is a useful
/// mental model for the observed glitch.) This is the visually smooth choice
/// for placements that we know will not coincide with another app rapidly
/// unminimizing windows.
///
/// `.deferred` queues the minimize through a 150 ms debounce. When an app is
/// processing a queue of windows to unminimize (for example, a document-based
/// app restoring its previous-session windows on launch), a synchronous minimize
/// would land back at the end of that queue and be re-unminimized — creating an
/// infinite ping-pong as Zonogy keeps placing the new arrival into the same
/// zone. Deferring lets the app drain its queue first, so the displaced window's
/// minimize happens after the launching burst is over and is not re-applied.
///
/// Use `.deferred` for any placement flowing through
/// `WindowPlacementManager.placeNewWindow` — the entry point for "a window
/// arrived" events (external unminimizes, fresh window captures, manual capture,
/// recapture, startup, drag tear-out reassignment). External arrivals could be
/// part of a launching app's queue; the internal callers route through the same
/// path so a single loop-safe entry point covers everything.
///
/// Use `.synchronous` for Zonogy-initiated single-window swaps that do not flow
/// through `placeNewWindow` (drag-drop, Launcher selections, moves between
/// zones, etc.) where the source window already exists and no app launch is in
/// flight.
enum DisplacementStrategy {
    case synchronous
    case deferred
}
