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

    /// What the shared Launcher selection path actually did with a chooser row.
    enum SelectionAction {
        case activatedInPlace
        case placed
        /// Nothing happened: a window parked behind a full-screen Space had no visible destination.
        case ignored
        case selectionUntracked
    }

    /// Classifies a completed row selection from what it actually did, so target restoration can
    /// never disagree with the action. (The action itself decides place-versus-activate: a window
    /// parked behind a full-screen Space is placed anew like a minimized one when a visible
    /// destination exists, and its selection is ignored otherwise.)
    static func outcomeForSelection(action: SelectionAction) -> Outcome {
        switch action {
        case .activatedInPlace: return .activatedExistingWindow
        case .placed: return .placedOrOpenedWindow
        case .ignored, .selectionUntracked: return .selectedVanishedWindow
        }
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
