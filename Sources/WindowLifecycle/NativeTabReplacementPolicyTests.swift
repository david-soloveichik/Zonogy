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

        assert(
            NativeTabReplacementPolicy.framesCoincide(
                incoming,
                CGRect(x: 101, y: 79, width: 899, height: 750)
            ),
            "height difference at the 50px limit should match when position and width coincide"
        )
        assert(
            !NativeTabReplacementPolicy.framesCoincide(
                incoming,
                CGRect(x: 100, y: 80, width: 900, height: 751)
            ),
            "height difference beyond 50px should not match"
        )
        assert(
            !NativeTabReplacementPolicy.framesCoincide(
                incoming,
                CGRect(x: 103, y: 80, width: 900, height: 700)
            ),
            "x differences beyond frame tolerance should not match"
        )
        assert(
            !NativeTabReplacementPolicy.framesCoincide(
                incoming,
                CGRect(x: 100, y: 80, width: 903, height: 700)
            ),
            "width differences beyond frame tolerance should not match"
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
                candidate(windowId: 4, frame: CGRect(x: 100, y: 80, width: 900, height: 751))
            ]
        )
        assert(rejected == nil, "different pid, same CGWindowID, unplaced, and noncoincident candidates should be rejected")

        let closest = NativeTabReplacementPolicy.replacementCandidate(
            incomingPid: 42,
            incomingCgWindowId: 100,
            incomingFrame: incoming,
            candidates: [
                candidate(windowId: 9, frame: CGRect(x: 100, y: 80, width: 900, height: 735)),
                candidate(windowId: 8, frame: CGRect(x: 100, y: 80, width: 900, height: 710))
            ]
        )
        assert(closest?.windowId == 8, "closest coincident frame should win")

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
                    sibling(300, CGRect(x: 100, y: 80, width: 900, height: 735)),
                    sibling(301, CGRect(x: 100, y: 80, width: 900, height: 710))
                ]
            )?.cgWindowId == 301,
            "closest coincident sibling frame should win"
        )
        assert(
            NativeTabReplacementPolicy.bestSibling(matching: incoming, among: [sibling(305), sibling(304)])?.cgWindowId == 304,
            "CGWindowID should break exact sibling coincidence ties deterministically"
        )
        assert(
            NativeTabReplacementPolicy.bestSibling(
                matching: incoming,
                among: [
                    sibling(306, CGRect(x: 100, y: 80, width: 900, height: 751)),
                    sibling(307, CGRect(x: 103, y: 80, width: 900, height: 700))
                ]
            ) == nil,
            "siblings beyond frame/height tolerance should not match the cached frame"
        )

        if allPassed {
            print("NativeTabReplacementPolicyTests: all tests passed")
        }
        return allPassed
    }
}
