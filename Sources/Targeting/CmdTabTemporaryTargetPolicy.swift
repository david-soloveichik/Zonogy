/// Pure policy for deciding whether CmdTab should restore its original target after dismissal.
enum CmdTabTemporaryTargetPolicy {
    enum Outcome {
        case cancelled
        case activatedExistingWindow
        case placedOrOpenedWindow
        /// The selected row's window vanished mid-session (closed, or tracking dropped),
        /// so the selection could not place or activate anything.
        case selectedVanishedWindow
        case interrupted
    }

    /// Classifies a row selection: a vanished window places nothing, a placed window is
    /// merely activated, and a still-managed unplaced window unminimizes into the target.
    static func outcomeForSelection(isPlacedInZone: Bool, windowStillManaged: Bool) -> Outcome {
        guard windowStillManaged else { return .selectedVanishedWindow }
        return isPlacedInZone ? .activatedExistingWindow : .placedOrOpenedWindow
    }

    static func shouldRestoreOriginalTarget(after outcome: Outcome) -> Bool {
        switch outcome {
        case .cancelled, .activatedExistingWindow, .selectedVanishedWindow:
            return true
        case .placedOrOpenedWindow, .interrupted:
            return false
        }
    }
}
