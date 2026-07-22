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
            SpuriousDestroyPolicy.resolve(
                windowStillListed: false,
                currentElementResolves: false,
                replacementLookup: .unavailable,
                confirmedAXAbsenceIsAuthoritative: false
            ) == .prune,
            "a window absent from the WindowServer should prune"
        )
        assert(
            SpuriousDestroyPolicy.resolve(
                windowStillListed: false,
                currentElementResolves: true,
                replacementLookup: .available,
                confirmedAXAbsenceIsAuthoritative: false
            ) == .prune,
            "WindowServer absence wins even if a stale element still resolves"
        )

        // Window present and the element we hold still resolves -> keep it. This covers a
        // purely spurious destroy where the *same* element remains valid (no replacement).
        assert(
            SpuriousDestroyPolicy.resolve(
                windowStillListed: true,
                currentElementResolves: true,
                replacementLookup: .unavailable,
                confirmedAXAbsenceIsAuthoritative: false
            ) == .keepCurrentElement,
            "a still-valid current element should be kept (same-element spurious destroy)"
        )
        assert(
            SpuriousDestroyPolicy.resolve(
                windowStillListed: true,
                currentElementResolves: true,
                replacementLookup: .available,
                confirmedAXAbsenceIsAuthoritative: true
            ) == .keepCurrentElement,
            "prefer keeping the valid current element over rebinding even if a replacement exists"
        )

        // Window present, our element dead, a fresh element exists -> rebind (element recycle).
        assert(
            SpuriousDestroyPolicy.resolve(
                windowStillListed: true,
                currentElementResolves: false,
                replacementLookup: .available,
                confirmedAXAbsenceIsAuthoritative: true
            ) == .rebindToReplacement,
            "a dead current element with a live replacement should rebind"
        )

        // Window present but AX is temporarily unable to provide a complete result -> defer.
        assert(
            SpuriousDestroyPolicy.resolve(
                windowStillListed: true,
                currentElementResolves: false,
                replacementLookup: .unavailable,
                confirmedAXAbsenceIsAuthoritative: true
            ) == .preserve,
            "a listed window with unavailable AX state should remain managed until AX recovers"
        )

        // A complete AX enumeration can override a stale WindowServer record only when the
        // lookup follows an explicit destroy notification. Generic liveness reads stay conservative.
        assert(
            SpuriousDestroyPolicy.resolve(
                windowStillListed: true,
                currentElementResolves: false,
                replacementLookup: .absent,
                confirmedAXAbsenceIsAuthoritative: true
            ) == .prune,
            "explicit AX destruction plus confirmed AX absence should prune a retained WindowServer entry"
        )
        assert(
            SpuriousDestroyPolicy.resolve(
                windowStillListed: true,
                currentElementResolves: false,
                replacementLookup: .absent,
                confirmedAXAbsenceIsAuthoritative: false
            ) == .preserve,
            "generic AX absence should remain non-destructive while WindowServer lists the window"
        )

        if allPassed {
            print("SpuriousDestroyPolicyTests: all tests passed")
        }
        return allPassed
    }
}
