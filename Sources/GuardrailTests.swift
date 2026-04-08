import Foundation

/// Aggregates lightweight runtime tests that can be triggered via the `--self-test` flag.
///
/// Guardrail tests are intentionally limited to *pure, deterministic* logic (geometry/policy/selection).
/// They should not depend on Accessibility permissions, timing, the window server, or any other OS state.
enum GuardrailTests {
    @discardableResult
    static func runAll() -> Bool {
        var allPassed = true

        if !DisplacedWindowPlannerTests.run() {
            allPassed = false
        }
        if !SingleOccupantReplacementTests.run() {
            allPassed = false
        }
        if !WindowPlacementManagerNoOpPlacementTests.run() {
            allPassed = false
        }
        if !MainWindowSecondaryFloatingPlacementPolicyTests.run() {
            allPassed = false
        }
        if !CoordinateConversionTests.run() {
            allPassed = false
        }
        if !ZoneLayoutTests.run() {
            allPassed = false
        }
        if !ZoneResizeHandleGeometryTests.run() {
            allPassed = false
        }
        if !ZoneResizeHandleVisibilityPolicyTests.run() {
            allPassed = false
        }
        if !EdgeIndicatorHoverExitPolicyTests.run() {
            allPassed = false
        }
        if !WindowOcclusionPolicyTests.run() {
            allPassed = false
        }
        if !FloatingZoneOverlapPolicyTests.run() {
            allPassed = false
        }
        if !PlaceholderExternalDragPolicyTests.run() {
            allPassed = false
        }
        if !ZoneControllerTests.run() {
            allPassed = false
        }
        if !ZoneOccupancyReconcilerTests.run() {
            allPassed = false
        }
        if !PendingPrunedWindowStoreTests.run() {
            allPassed = false
        }
        if !ManagedWindowRecencyOrderTests.run() {
            allPassed = false
        }
        if !TargetedZoneManagerTests.run() {
            allPassed = false
        }
        if !DragSwapFollowsFocusPolicyTests.run() {
            allPassed = false
        }
        if !FollowsFocusZoneRemovalPolicyTests.run() {
            allPassed = false
        }
        if !FocusFollowActivationSettlementPolicyTests.run() {
            allPassed = false
        }
        if !ActiveFitPolicyTests.run() {
            allPassed = false
        }
        if !ActiveFitRevealStatePolicyTests.run() {
            allPassed = false
        }
        if !StickyResizeFramePolicyTests.run() {
            allPassed = false
        }
        if !WindowSelfResizePolicyTests.run() {
            allPassed = false
        }
        if !ApplicationExceptionPolicyTests.run() {
            allPassed = false
        }
        if !StickyResizePreferencesStoreTests.run() {
            allPassed = false
        }
        if !PreferredWindowSelectionTests.run() {
            allPassed = false
        }
        if !WinShotSnapshotOccupancySignatureTests.run() {
            allPassed = false
        }
        if !WinShotStickyResizeSnapshotMappingTests.run() {
            allPassed = false
        }
        if !WinShotChooserViewTests.run() {
            allPassed = false
        }
        if !WinShotChooserInitialSelectionPolicyTests.run() {
            allPassed = false
        }
        if !WinShotPreferencesStoreTests.run() {
            allPassed = false
        }
        if !WinShotTimelineLayoutTests.run() {
            allPassed = false
        }
        if !WinShotTimelineConnectorRoutingTests.run() {
            allPassed = false
        }
        if !EmptyZoneRetargetProtectionPolicyTests.run() {
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
