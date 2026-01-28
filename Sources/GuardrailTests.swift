import Foundation

/// Aggregates lightweight runtime tests that can be triggered via the `--self-test` flag.
///
/// Guardrail tests are intentionally limited to *pure, deterministic* logic (geometry/policy/selection).
/// They should not depend on Accessibility permissions, timing, the window server, or any other OS state.
enum GuardrailTests {
    @discardableResult
    static func runAll() -> Bool {
        var allPassed = true

        if !CoordinateConversionTests.run() {
            allPassed = false
        }
        if !ZoneLayoutTests.run() {
            allPassed = false
        }
        if !ZoneResizeHandleGeometryTests.run() {
            allPassed = false
        }
        if !ZoneControllerTests.run() {
            allPassed = false
        }
        if !TargetedZoneManagerTests.run() {
            allPassed = false
        }
        if !ActiveFitPolicyTests.run() {
            allPassed = false
        }
        if !ApplicationExceptionPolicyTests.run() {
            allPassed = false
        }
        if !PreferredWindowSelectionTests.run() {
            allPassed = false
        }

        if allPassed {
            print("GuardrailTests: all tests passed")
        } else {
            print("GuardrailTests: failures detected")
        }
        return allPassed
    }
}
