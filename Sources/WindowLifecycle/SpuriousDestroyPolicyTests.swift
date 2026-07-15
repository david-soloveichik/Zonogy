import Foundation

/// Guardrail tests for `SpuriousDestroyPolicy`.
enum SpuriousDestroyPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("SpuriousDestroyPolicyTests: \(message)")
                allPassed = false
            }
        }

        // Window gone -> prune, regardless of any (stale) element state.
        assert(
            SpuriousDestroyPolicy.resolve(windowStillListed: false, currentElementResolves: false, replacementElementAvailable: false) == .prune,
            "a window absent from the WindowServer should prune"
        )
        assert(
            SpuriousDestroyPolicy.resolve(windowStillListed: false, currentElementResolves: true, replacementElementAvailable: true) == .prune,
            "WindowServer absence wins even if a stale element still resolves"
        )

        // Window present and the element we hold still resolves -> keep it. This covers a
        // purely spurious destroy where the *same* element remains valid (no replacement).
        assert(
            SpuriousDestroyPolicy.resolve(windowStillListed: true, currentElementResolves: true, replacementElementAvailable: false) == .keepCurrentElement,
            "a still-valid current element should be kept (same-element spurious destroy)"
        )
        assert(
            SpuriousDestroyPolicy.resolve(windowStillListed: true, currentElementResolves: true, replacementElementAvailable: true) == .keepCurrentElement,
            "prefer keeping the valid current element over rebinding even if a replacement exists"
        )

        // Window present, our element dead, a fresh element exists -> rebind (element recycle).
        assert(
            SpuriousDestroyPolicy.resolve(windowStillListed: true, currentElementResolves: false, replacementElementAvailable: true) == .rebindToReplacement,
            "a dead current element with a live replacement should rebind"
        )

        // Window present but AX is temporarily unable to provide any usable element -> defer.
        // WindowServer remains the destruction authority, so the zone must stay occupied.
        assert(
            SpuriousDestroyPolicy.resolve(windowStillListed: true, currentElementResolves: false, replacementElementAvailable: false) == .preserve,
            "a listed window with no bindable element should remain managed until AX recovers"
        )

        if allPassed {
            print("SpuriousDestroyPolicyTests: all tests passed")
        }
        return allPassed
    }
}
