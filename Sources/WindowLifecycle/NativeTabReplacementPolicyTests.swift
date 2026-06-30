import Foundation

/// Guardrail tests for native-tab frame matching and candidate selection.
enum NativeTabReplacementPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("NativeTabReplacementPolicyTests: \(message)")
                allPassed = false
            }
        }

        let incoming = CGRect(x: 100, y: 80, width: 900, height: 700)

        assert(
            NativeTabReplacementPolicy.shouldEvaluateIncomingWindow(
                isPlacedInZone: false,
                isMinimized: false,
                nativeTabHandlingDisabled: false
            ),
            "eligible unplaced windows should be evaluated for native-tab replacement even if already tracked"
        )
        assert(
            !NativeTabReplacementPolicy.shouldEvaluateIncomingWindow(
                isPlacedInZone: true,
                isMinimized: false,
                nativeTabHandlingDisabled: false
            ),
            "placed incoming windows should not be treated as new native-tab candidates"
        )
        assert(
            !NativeTabReplacementPolicy.shouldEvaluateIncomingWindow(
                isPlacedInZone: false,
                isMinimized: true,
                nativeTabHandlingDisabled: false
            ),
            "minimized incoming windows should not be evaluated for native-tab replacement"
        )
        assert(
            !NativeTabReplacementPolicy.shouldEvaluateIncomingWindow(
                isPlacedInZone: false,
                isMinimized: false,
                nativeTabHandlingDisabled: true
            ),
            "debug-disabled native tab handling should skip native-tab replacement"
        )

        func candidate(
            windowId: Int,
            pid: pid_t = 42,
            cgWindowId: Int = 200,
            frame: CGRect = incoming,
            isPlacedInZone: Bool = true
        ) -> NativeTabReplacementPolicy.Candidate {
            NativeTabReplacementPolicy.Candidate(
                windowId: windowId,
                pid: pid,
                cgWindowId: cgWindowId,
                frame: frame,
                isPlacedInZone: isPlacedInZone
            )
        }

        // Position + width match (used by both the switch and close paths); height is ignored.
        assert(
            NativeTabReplacementPolicy.positionAndWidthCoincide(
                incoming,
                CGRect(x: 101, y: 79, width: 899, height: 5000)
            ),
            "position+width within tolerance should coincide regardless of height"
        )
        assert(
            !NativeTabReplacementPolicy.positionAndWidthCoincide(
                incoming,
                CGRect(x: 103, y: 80, width: 900, height: 700)
            ),
            "x beyond frame tolerance should not coincide"
        )
        assert(
            !NativeTabReplacementPolicy.positionAndWidthCoincide(
                incoming,
                CGRect(x: 100, y: 80, width: 903, height: 700)
            ),
            "width beyond frame tolerance should not coincide"
        )

        let exact = NativeTabReplacementPolicy.replacementCandidate(
            incomingPid: 42,
            incomingCgWindowId: 100,
            incomingFrame: incoming,
            candidates: [candidate(windowId: 7)]
        )
        assert(exact?.windowId == 7, "same-pid placed candidate with coincident frame should match")

        let rejected = NativeTabReplacementPolicy.replacementCandidate(
            incomingPid: 42,
            incomingCgWindowId: 100,
            incomingFrame: incoming,
            candidates: [
                candidate(windowId: 1, pid: 43),
                candidate(windowId: 2, cgWindowId: 100),
                candidate(windowId: 3, isPlacedInZone: false),
                candidate(windowId: 4, frame: CGRect(x: 103, y: 80, width: 900, height: 700))
            ]
        )
        assert(rejected == nil, "different pid, same CGWindowID, unplaced, and position/width-noncoincident candidates should be rejected")

        let heightStaleMatch = NativeTabReplacementPolicy.replacementCandidate(
            incomingPid: 42,
            incomingCgWindowId: 100,
            incomingFrame: incoming,
            candidates: [candidate(windowId: 5, frame: CGRect(x: 100, y: 80, width: 900, height: 1200))]
        )
        assert(heightStaleMatch?.windowId == 5, "adoption ignores height: a large/stale height difference must still match when position and width coincide")

        let closest = NativeTabReplacementPolicy.replacementCandidate(
            incomingPid: 42,
            incomingCgWindowId: 100,
            incomingFrame: incoming,
            candidates: [
                candidate(windowId: 9, frame: CGRect(x: 101, y: 80, width: 900, height: 700)),
                candidate(windowId: 8, frame: CGRect(x: 100, y: 80, width: 900, height: 700))
            ]
        )
        assert(closest?.windowId == 8, "closest position/width candidate should win")

        let tied = NativeTabReplacementPolicy.replacementCandidate(
            incomingPid: 42,
            incomingCgWindowId: 100,
            incomingFrame: incoming,
            candidates: [
                candidate(windowId: 12),
                candidate(windowId: 11)
            ]
        )
        assert(tied?.windowId == 11, "windowId should break exact coincidence ties deterministically")

        let mergeDestination = NativeTabReplacementPolicy.mergeDestinationCandidate(
            sourcePid: 42,
            sourceCgWindowId: 100,
            sourceFrame: incoming,
            candidates: [
                candidate(windowId: 21, frame: CGRect(x: 100, y: 80, width: 900, height: 1200)),
                candidate(windowId: 22, pid: 43),
                candidate(windowId: 23, cgWindowId: 100),
                candidate(windowId: 24, isPlacedInZone: false)
            ]
        )
        assert(
            mergeDestination?.windowId == 21,
            "last-tab merge destination should be a placed same-pid window with coincident position and width"
        )

        func sibling(_ cgWindowId: Int, _ frame: CGRect = incoming) -> NativeTabReplacementPolicy.SiblingCandidate {
            NativeTabReplacementPolicy.SiblingCandidate(cgWindowId: cgWindowId, frame: frame)
        }

        assert(
            NativeTabReplacementPolicy.bestSibling(matching: incoming, among: [sibling(300)])?.cgWindowId == 300,
            "a sibling coincident with the cached frame should be adopted on tab close"
        )
        assert(
            NativeTabReplacementPolicy.bestSibling(
                matching: incoming,
                among: [
                    sibling(300, CGRect(x: 101, y: 80, width: 900, height: 700)),
                    sibling(301, CGRect(x: 100, y: 80, width: 900, height: 700))
                ]
            )?.cgWindowId == 301,
            "closest position/width sibling should win"
        )
        assert(
            NativeTabReplacementPolicy.bestSibling(matching: incoming, among: [sibling(305), sibling(304)])?.cgWindowId == 304,
            "CGWindowID should break exact sibling coincidence ties deterministically"
        )
        assert(
            NativeTabReplacementPolicy.bestSibling(
                matching: incoming,
                among: [sibling(306, CGRect(x: 100, y: 80, width: 900, height: 1200))]
            )?.cgWindowId == 306,
            "close match ignores height too: a large height difference must still match the cached frame"
        )
        assert(
            NativeTabReplacementPolicy.bestSibling(
                matching: incoming,
                among: [
                    sibling(307, CGRect(x: 103, y: 80, width: 900, height: 700)),
                    sibling(308, CGRect(x: 100, y: 80, width: 904, height: 700))
                ]
            ) == nil,
            "siblings beyond position/width tolerance should not match the cached frame"
        )

        if allPassed {
            print("NativeTabReplacementPolicyTests: all tests passed")
        }
        return allPassed
    }
}
