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

        // Pre-release (beta) ordering per Semantic Versioning.
        assert(UpdateVersionComparison.isNewer(releaseTag: "1.2-beta", than: "1.1"), "a beta of 1.2 is newer than final 1.1")
        assert(!UpdateVersionComparison.isNewer(releaseTag: "1.2-beta", than: "1.2"), "a beta is older than its own final release")
        assert(UpdateVersionComparison.isNewer(releaseTag: "1.2", than: "1.2-beta"), "the final release supersedes its beta")
        assert(UpdateVersionComparison.isNewer(releaseTag: "1.0-beta.2", than: "1.0-beta.1"), "a later beta is newer than an earlier one")
        assert(!UpdateVersionComparison.isNewer(releaseTag: "1.0-beta.1", than: "1.0-beta.2"), "an earlier beta is not newer than a later one")
        assert(UpdateVersionComparison.isNewer(releaseTag: "1.0-beta.10", than: "1.0-beta.2"), "beta numbers compare numerically, not lexicographically")
        assert(UpdateVersionComparison.isNewer(releaseTag: "1.0-beta.1", than: "1.0-beta"), "more pre-release identifiers outrank fewer when the prefix matches")
        assert(UpdateVersionComparison.isNewer(releaseTag: "1.0-rc.1", than: "1.0-beta.9"), "rc outranks beta lexically among alphanumeric identifiers")
        assert(UpdateVersionComparison.isNewer(releaseTag: "1.0--1", than: "1.0-2"), "the identifier \"-1\" (leading hyphen intended) is alphanumeric, not parsed as the number -1, so it outranks numeric \"2\"")
        assert(UpdateVersionComparison.isNewer(releaseTag: "1.1-beta.1", than: "1.0"), "a beta of the next version is newer than the current final")
        assert(!UpdateVersionComparison.isNewer(releaseTag: "1.0-beta.1", than: "1.0-beta.1"), "identical betas are not newer")
        assert(!UpdateVersionComparison.isNewer(releaseTag: "1.0-", than: "1.0"), "an empty pre-release suffix is unparseable and never offered")
        assert(!UpdateVersionComparison.isNewer(releaseTag: "1.0-beta.", than: "1.0-beta"), "a trailing empty pre-release identifier is unparseable and never offered")

        assert(!UpdateVersionComparison.isNewer(releaseTag: "beta", than: "1.0"), "unparseable release tag is never newer")
        assert(!UpdateVersionComparison.isNewer(releaseTag: "", than: "1.0"), "empty release tag is never newer")
        assert(!UpdateVersionComparison.isNewer(releaseTag: "1.1", than: "1.0-"), "an unparseable installed version means nothing is newer")
        assert(UpdateVersionComparison.normalized("v1.2") == "1.2", "normalized should strip the leading v")
        assert(UpdateVersionComparison.normalized(" 1.2 ") == "1.2", "normalized should trim whitespace")
        assert(UpdateVersionComparison.normalized("v1.2-beta.1") == "1.2-beta.1", "normalized keeps the pre-release suffix")

        if allPassed {
            print("UpdateVersionComparisonTests: all tests passed")
        }
        return allPassed
    }
}
