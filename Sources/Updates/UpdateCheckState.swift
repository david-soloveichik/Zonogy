/// Coordinates overlapping update checks and decides which results should show an alert.

struct UpdateCheckState {
    private enum CheckKind { case automatic, manual }

    private var pendingCheck: CheckKind?
    private var alertedVersions: Set<String> = []

    /// Returns whether to start a request. A manual check takes priority over an automatic
    /// check already in progress; repeated manual checks share the same result.
    mutating func begin(manually: Bool) -> Bool {
        let shouldStart = pendingCheck == nil
        if manually {
            pendingCheck = .manual
        } else if shouldStart {
            pendingCheck = .automatic
        }
        return shouldStart
    }

    /// Returns whether to show the result, recording any update version as alerted.
    mutating func beginAlert(for outcome: UpdateCheckOutcome, skippedVersion: String?) -> Bool {
        switch pendingCheck {
        case .manual:
            break
        case .automatic:
            guard case .updateAvailable(let update) = outcome,
                  update.version != skippedVersion, !alertedVersions.contains(update.version) else { return false }
        case nil:
            return false
        }
        if case .updateAvailable(let update) = outcome {
            alertedVersions.insert(update.version)
        }
        return true
    }

    /// Call after the alert closes, so requests arriving during presentation also share it.
    mutating func finish() {
        pendingCheck = nil
    }
}
