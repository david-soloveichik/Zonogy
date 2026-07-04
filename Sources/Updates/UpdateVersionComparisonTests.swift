import Foundation

/// Guardrail tests for release-version ordering used by the update check.
enum UpdateVersionComparisonTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("UpdateVersionComparisonTests: \(message)")
                allPassed = false
            }
        }

        assert(UpdateVersionComparison.isNewer(releaseTag: "1.1", than: "1.0"), "1.1 should be newer than 1.0")
        assert(UpdateVersionComparison.isNewer(releaseTag: "v1.1", than: "1.0"), "leading v should be ignored")
        assert(!UpdateVersionComparison.isNewer(releaseTag: "1.0", than: "1.0"), "equal versions are not newer")
        assert(!UpdateVersionComparison.isNewer(releaseTag: "0.9", than: "1.0"), "older release is not newer")
        assert(UpdateVersionComparison.isNewer(releaseTag: "1.10", than: "1.9"), "components compare numerically, not lexicographically")
        assert(UpdateVersionComparison.isNewer(releaseTag: "1.0.1", than: "1.0"), "extra patch component makes it newer")
        assert(!UpdateVersionComparison.isNewer(releaseTag: "1.0", than: "1.0.0"), "missing components count as zero")
        assert(!UpdateVersionComparison.isNewer(releaseTag: "1.0.0", than: "1.0"), "trailing zero components do not make it newer")
        assert(UpdateVersionComparison.isNewer(releaseTag: "2.0", than: "1.9.9"), "major bump outranks minor and patch")
        assert(!UpdateVersionComparison.isNewer(releaseTag: "1.2-beta", than: "1.1"), "suffixed tags are unparseable and never offered")
        assert(!UpdateVersionComparison.isNewer(releaseTag: "beta", than: "1.0"), "unparseable release tag is never newer")
        assert(!UpdateVersionComparison.isNewer(releaseTag: "", than: "1.0"), "empty release tag is never newer")
        assert(UpdateVersionComparison.normalized("v1.2") == "1.2", "normalized should strip the leading v")
        assert(UpdateVersionComparison.normalized(" 1.2 ") == "1.2", "normalized should trim whitespace")

        if allPassed {
            print("UpdateVersionComparisonTests: all tests passed")
        }
        return allPassed
    }
}
