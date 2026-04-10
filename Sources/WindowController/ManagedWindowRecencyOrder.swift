/// Shared managed-window recency ordering used by Launcher and CmdTab.
import Foundation

enum ManagedWindowRecencyOrder {
    static func isMoreRecent(
        windowId lhsId: Int,
        lastActiveTime lhsTime: Date?,
        than rhsId: Int,
        otherLastActiveTime rhsTime: Date?
    ) -> Bool {
        switch (lhsTime, rhsTime) {
        case (let lhsTime?, let rhsTime?):
            if lhsTime != rhsTime {
                return lhsTime > rhsTime
            }
            return lhsId < rhsId
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhsId < rhsId
        }
    }
}
