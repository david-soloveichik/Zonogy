/// Guardrail tests for overlapping update checks, shared alert history, and skipped versions.
import Foundation

enum UpdateCheckStateTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true
        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("UpdateCheckStateTests: \(message)")
                allPassed = false
            }
        }

        let pageURL = URL(string: "https://example.com/releases/latest")!
        let update = UpdateCheckOutcome.updateAvailable(UpdateInfo(version: "1.1", pageURL: pageURL))
        let newerUpdate = UpdateCheckOutcome.updateAvailable(UpdateInfo(version: "1.2", pageURL: pageURL))

        // Either order and repeated clicks share one request, with manual results taking priority.
        for requests in [[false, true, true], [true, false, true], [true, true], [false, false]] {
            var state = UpdateCheckState()
            for (index, manually) in requests.enumerated() {
                assert(state.begin(manually: manually) == (index == 0), "only the first request should start a fetch")
            }
            let showsResult = state.beginAlert(for: .upToDate, skippedVersion: nil)
            assert(showsResult == requests.contains(true), "a manual request must report the shared result")
            assert(!state.begin(manually: false), "the check must stay busy through alert presentation")
            state.finish()
            assert(state.begin(manually: true), "dismissing the result must allow a new check")
        }

        // Both kinds of alert suppress automatic repeats, while a different version still alerts.
        for manually in [false, true] {
            var state = UpdateCheckState()
            _ = state.begin(manually: manually)
            assert(state.beginAlert(for: update, skippedVersion: nil), "show the first update")
            state.finish()
            _ = state.begin(manually: false)
            assert(!state.beginAlert(for: update, skippedVersion: nil), "suppress the repeat")
            state.finish()
            _ = state.begin(manually: false)
            assert(state.beginAlert(for: newerUpdate, skippedVersion: nil), "show a newer version")
            state.finish()
            _ = state.begin(manually: false)
            assert(!state.beginAlert(for: update, skippedVersion: nil), "remember earlier alerts")
            state.finish()
            _ = state.begin(manually: true)
            assert(state.beginAlert(for: update, skippedVersion: "1.1"),
                   "manual checks must still report skipped or previously shown versions")
        }

        // Skipping a version suppresses its alert without recording it as shown.
        do {
            var state = UpdateCheckState()
            _ = state.begin(manually: false)
            assert(!state.beginAlert(for: update, skippedVersion: "1.1"), "skipped versions must stay silent")
            state.finish()
            _ = state.begin(manually: false)
            assert(state.beginAlert(for: update, skippedVersion: nil), "clearing the skip must allow an alert")
        }

        for outcome in [UpdateCheckOutcome.upToDate, .failed("Offline")] {
            var state = UpdateCheckState()
            _ = state.begin(manually: false)
            assert(!state.beginAlert(for: outcome, skippedVersion: nil),
                   "automatic checks should report only updates")
            state.finish()
            _ = state.begin(manually: true)
            assert(state.beginAlert(for: outcome, skippedVersion: nil),
                   "manual checks must report errors and up-to-date results")
        }

        if allPassed {
            print("UpdateCheckStateTests: all tests passed")
        }
        return allPassed
    }
}
