/// Pure policy for deciding whether CmdTab should restore its original target after dismissal.
enum CmdTabTemporaryTargetPolicy {
    enum Outcome {
        case cancelled
        case activatedExistingWindow
        case placedOrOpenedWindow
        case interrupted
    }

    static func shouldRestoreOriginalTarget(after outcome: Outcome) -> Bool {
        switch outcome {
        case .cancelled, .activatedExistingWindow:
            return true
        case .placedOrOpenedWindow, .interrupted:
            return false
        }
    }
}
