import Foundation

/// Guardrail tests for the shared managed-window recency ordering.
enum ManagedWindowRecencyOrderTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ManagedWindowRecencyOrderTests: \(message)")
                allPassed = false
            }
        }

        do {
            let old = Date(timeIntervalSince1970: 10)
            let new = Date(timeIntervalSince1970: 20)

            assert(
                ManagedWindowRecencyOrder.isMoreRecent(
                    windowId: 2,
                    lastActiveTime: new,
                    than: 1,
                    otherLastActiveTime: old
                ),
                "newer activity timestamp should sort first"
            )
        }

        do {
            let timestamp = Date(timeIntervalSince1970: 10)

            assert(
                ManagedWindowRecencyOrder.isMoreRecent(
                    windowId: 2,
                    lastActiveTime: timestamp,
                    than: 1,
                    otherLastActiveTime: nil
                ),
                "windows with activity history should sort ahead of windows without history"
            )
        }

        do {
            assert(
                ManagedWindowRecencyOrder.isMoreRecent(
                    windowId: 3,
                    lastActiveTime: nil,
                    than: 7,
                    otherLastActiveTime: nil
                ),
                "when recency is unknown for both windows, lower Zonogy ID should sort first"
            )
        }

        do {
            let timestamp = Date(timeIntervalSince1970: 10)

            assert(
                ManagedWindowRecencyOrder.isMoreRecent(
                    windowId: 3,
                    lastActiveTime: timestamp,
                    than: 7,
                    otherLastActiveTime: timestamp
                ),
                "equal activity timestamps should break ties by lower Zonogy ID"
            )
        }

        if allPassed {
            print("ManagedWindowRecencyOrderTests: all tests passed")
        }
        return allPassed
    }
}
