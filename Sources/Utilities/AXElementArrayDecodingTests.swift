import Foundation
import ApplicationServices

/// Lightweight runtime assertions for `AXCall.elementArray(from:)` decoding.
///
/// Uses locally created AX element tokens (no IPC, no Accessibility permissions) to verify
/// the decoder's contract: arrays decode, non-element entries are skipped, and a non-array
/// value reads as nil so callers can tell a malformed value from an empty list.
enum AXElementArrayDecodingTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("AXElementArrayDecodingTests: \(message)")
                allPassed = false
            }
        }

        let element = AXUIElementCreateApplication(getpid())
        let otherElement = AXUIElementCreateSystemWide()

        let bridged = [element, otherElement] as CFArray
        let decoded = AXCall.elementArray(from: bridged)
        assert(decoded?.count == 2, "array of elements should decode both entries (got \(String(describing: decoded?.count)))")

        let mixed = [element as CFTypeRef, "not an element" as CFString] as CFArray
        let mixedDecoded = AXCall.elementArray(from: mixed)
        assert(mixedDecoded?.count == 1, "non-element entries should be skipped, not fail decoding (got \(String(describing: mixedDecoded?.count)))")

        let empty = [] as CFArray
        assert(AXCall.elementArray(from: empty)?.isEmpty == true, "empty array should decode to an empty list, not nil")

        let nonArray = "not an array" as CFString
        assert(AXCall.elementArray(from: nonArray) == nil, "a non-array value should decode to nil (distinguishable from empty)")

        if allPassed {
            print("AXElementArrayDecodingTests: all tests passed")
        }
        return allPassed
    }
}
