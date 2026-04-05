import Foundation
import CoreGraphics

/// Guardrail tests for follows-focus retargeting after zone removal.
enum FollowsFocusZoneRemovalPolicyTests {
    typealias Candidate = FollowsFocusZoneRemovalPolicy.Candidate

    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("FollowsFocusZoneRemovalPolicyTests: \(message)")
                allPassed = false
            }
        }

        let screen1: CGDirectDisplayID = 1
        let screen2: CGDirectDisplayID = 2

        // (1) Active window in a tiling zone takes priority
        do {
            let active = Candidate(windowId: 1, zoneIndex: 2, screenId: screen1, isInFloatingZone: false)
            let recency = [
                Candidate(windowId: 2, zoneIndex: 1, screenId: screen1, isInFloatingZone: false),
            ]
            let result = FollowsFocusZoneRemovalPolicy.selectDestination(
                activeCandidate: active, recencyCandidates: recency, removedIndex: 3, removedScreenId: screen1
            )
            assert(result == .tiled(ZoneKey(screenId: screen1, index: 2)),
                   "active tiling window should take priority over recency")
        }

        // (2) Active window in floating zone takes priority
        do {
            let active = Candidate(windowId: 1, zoneIndex: nil, screenId: screen1, isInFloatingZone: true)
            let recency = [
                Candidate(windowId: 2, zoneIndex: 1, screenId: screen1, isInFloatingZone: false),
            ]
            let result = FollowsFocusZoneRemovalPolicy.selectDestination(
                activeCandidate: active, recencyCandidates: recency, removedIndex: 2, removedScreenId: screen1
            )
            assert(result == .floating(screenId: screen1),
                   "active floating window should take priority")
        }

        // (3) No active window → recency fallback picks first in-zone window
        do {
            let recency = [
                Candidate(windowId: 1, zoneIndex: 2, screenId: screen1, isInFloatingZone: false),
                Candidate(windowId: 2, zoneIndex: 1, screenId: screen2, isInFloatingZone: false),
            ]
            let result = FollowsFocusZoneRemovalPolicy.selectDestination(
                activeCandidate: nil, recencyCandidates: recency, removedIndex: 3, removedScreenId: screen1
            )
            assert(result == .tiled(ZoneKey(screenId: screen1, index: 2)),
                   "recency fallback should pick most-recent in-zone window")
        }

        // (4) Recency fallback skips window in the removed zone (stale zoneIndex)
        do {
            let recency = [
                Candidate(windowId: 1, zoneIndex: 2, screenId: screen1, isInFloatingZone: false),  // in removed zone
                Candidate(windowId: 2, zoneIndex: 1, screenId: screen1, isInFloatingZone: false),
            ]
            let result = FollowsFocusZoneRemovalPolicy.selectDestination(
                activeCandidate: nil, recencyCandidates: recency, removedIndex: 2, removedScreenId: screen1
            )
            assert(result == .tiled(ZoneKey(screenId: screen1, index: 1)),
                   "recency fallback must skip window in the removed zone")
        }

        // (5) Recency fallback adjusts index when higher-index zone on same screen
        do {
            let recency = [
                Candidate(windowId: 1, zoneIndex: 3, screenId: screen1, isInFloatingZone: false),
            ]
            let result = FollowsFocusZoneRemovalPolicy.selectDestination(
                activeCandidate: nil, recencyCandidates: recency, removedIndex: 1, removedScreenId: screen1
            )
            assert(result == .tiled(ZoneKey(screenId: screen1, index: 2)),
                   "recency fallback should adjust index when lower zone is removed on same screen")
        }

        // (6) Recency fallback does NOT adjust index on different screen
        do {
            let recency = [
                Candidate(windowId: 1, zoneIndex: 3, screenId: screen2, isInFloatingZone: false),
            ]
            let result = FollowsFocusZoneRemovalPolicy.selectDestination(
                activeCandidate: nil, recencyCandidates: recency, removedIndex: 1, removedScreenId: screen1
            )
            assert(result == .tiled(ZoneKey(screenId: screen2, index: 3)),
                   "recency fallback should not adjust index for different screen")
        }

        // (7) Most-recent window is floating
        do {
            let recency = [
                Candidate(windowId: 1, zoneIndex: nil, screenId: screen2, isInFloatingZone: true),
                Candidate(windowId: 2, zoneIndex: 1, screenId: screen1, isInFloatingZone: false),
            ]
            let result = FollowsFocusZoneRemovalPolicy.selectDestination(
                activeCandidate: nil, recencyCandidates: recency, removedIndex: 2, removedScreenId: screen1
            )
            assert(result == .floating(screenId: screen2),
                   "recency fallback should return floating zone when most-recent window is floating")
        }

        // (8) No active window and no windows in any zone → fallback to zone 1
        do {
            let recency: [Candidate] = [
                Candidate(windowId: 1, zoneIndex: nil, screenId: screen1, isInFloatingZone: false),  // minimized
            ]
            let result = FollowsFocusZoneRemovalPolicy.selectDestination(
                activeCandidate: nil, recencyCandidates: recency, removedIndex: 2, removedScreenId: screen1
            )
            assert(result == .tiled(ZoneKey(screenId: screen1, index: 1)),
                   "should fallback to zone 1 on removed screen when no window is in any zone")
        }

        // (9) Empty recency list → fallback to zone 1
        do {
            let result = FollowsFocusZoneRemovalPolicy.selectDestination(
                activeCandidate: nil, recencyCandidates: [], removedIndex: 1, removedScreenId: screen1
            )
            assert(result == .tiled(ZoneKey(screenId: screen1, index: 1)),
                   "should fallback to zone 1 when no windows exist at all")
        }

        // (10) Active window not in any zone → falls through to recency
        do {
            let active = Candidate(windowId: 1, zoneIndex: nil, screenId: screen1, isInFloatingZone: false)
            let recency = [
                Candidate(windowId: 2, zoneIndex: 1, screenId: screen2, isInFloatingZone: false),
            ]
            let result = FollowsFocusZoneRemovalPolicy.selectDestination(
                activeCandidate: active, recencyCandidates: recency, removedIndex: 2, removedScreenId: screen1
            )
            assert(result == .tiled(ZoneKey(screenId: screen2, index: 1)),
                   "active window not in any zone should fall through to recency")
        }

        // (11) Active window is in the removed zone → skip it, fall through to recency
        do {
            let active = Candidate(windowId: 1, zoneIndex: 2, screenId: screen1, isInFloatingZone: false)
            let recency = [
                Candidate(windowId: 1, zoneIndex: 2, screenId: screen1, isInFloatingZone: false),  // in removed zone
                Candidate(windowId: 2, zoneIndex: 1, screenId: screen1, isInFloatingZone: false),
            ]
            let result = FollowsFocusZoneRemovalPolicy.selectDestination(
                activeCandidate: active, recencyCandidates: recency, removedIndex: 2, removedScreenId: screen1
            )
            assert(result == .tiled(ZoneKey(screenId: screen1, index: 1)),
                   "active window in the removed zone must be skipped")
        }

        // (12) Active window is in the removed zone, no other windows → fallback to zone 1
        do {
            let active = Candidate(windowId: 1, zoneIndex: 2, screenId: screen1, isInFloatingZone: false)
            let recency = [
                Candidate(windowId: 1, zoneIndex: 2, screenId: screen1, isInFloatingZone: false),
            ]
            let result = FollowsFocusZoneRemovalPolicy.selectDestination(
                activeCandidate: active, recencyCandidates: recency, removedIndex: 2, removedScreenId: screen1
            )
            assert(result == .tiled(ZoneKey(screenId: screen1, index: 1)),
                   "active window in removed zone with no other windows should fallback to zone 1")
        }

        if allPassed {
            print("FollowsFocusZoneRemovalPolicyTests: all tests passed")
        }
        return allPassed
    }
}
