/// Implements LaunchBar-style fuzzy matching with quality scoring based on position and density.

import Foundation

struct MatchResult {
    let isMatch: Bool
    let score: Double  // 0.0 to 1.0, normalized match quality
    let matchedRanges: [Range<String.Index>]

    static let noMatch = MatchResult(isMatch: false, score: 0, matchedRanges: [])
}

enum SubsequenceMatcher {
    // Scoring constants (inspired by fzf)
    private static let scoreMatch: Double = 16
    private static let bonusBoundaryWhite: Double = 10
    private static let bonusBoundary: Double = 8
    private static let bonusCamel: Double = 7
    private static let bonusConsecutive: Double = 4
    private static let gapPenaltyStart: Double = -3
    private static let gapPenaltyExtension: Double = -1
    private static let firstCharMultiplier: Double = 2

    /// Returns true if query subsequence-matches candidate (backward compatibility)
    static func matches(query: String, candidate: String) -> Bool {
        scoreMatch(query: query, candidate: candidate).isMatch
    }

    /// Returns detailed match result with quality score
    static func scoreMatch(query: String, candidate: String) -> MatchResult {
        guard !query.isEmpty else {
            return MatchResult(isMatch: true, score: 1.0, matchedRanges: [])
        }
        guard !candidate.isEmpty else {
            return .noMatch
        }

        let normalizedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let normalizedCandidate = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        var matchedIndices: [String.Index] = []
        var candidateSearchStart = normalizedCandidate.startIndex
        var prevMatchIndex: String.Index?
        var isFirstChar = true
        var rawScore: Double = 0
        var inGap = false

        for queryChar in normalizedQuery {
            // Find best match for this query character
            guard let matchIndex = findBestMatch(
                for: queryChar,
                in: normalizedCandidate,
                original: candidate,
                startingFrom: candidateSearchStart,
                isConsecutivePreferred: prevMatchIndex != nil && candidateSearchStart == normalizedCandidate.index(after: prevMatchIndex!)
            ) else {
                return .noMatch
            }

            // Calculate gap penalty
            if let prev = prevMatchIndex {
                let gapStart = normalizedCandidate.index(after: prev)
                let gapLength = normalizedCandidate.distance(from: gapStart, to: matchIndex)
                if gapLength > 0 {
                    if !inGap {
                        rawScore += gapPenaltyStart
                        inGap = true
                    }
                    rawScore += Double(gapLength) * gapPenaltyExtension
                } else {
                    // Consecutive match bonus
                    rawScore += bonusConsecutive
                    inGap = false
                }
            }

            // Calculate match bonus based on position
            let bonus = bonusFor(candidate: candidate, normalizedCandidate: normalizedCandidate, at: matchIndex)
            let charScore = scoreMatch + (isFirstChar ? bonus * firstCharMultiplier : bonus)

            rawScore += charScore
            matchedIndices.append(matchIndex)
            prevMatchIndex = matchIndex
            candidateSearchStart = normalizedCandidate.index(after: matchIndex)
            isFirstChar = false
        }

        // Normalize score to 0.0-1.0
        let queryLength = Double(normalizedQuery.count)
        let maxScore = queryLength * (scoreMatch + bonusBoundaryWhite * firstCharMultiplier)
            + max(0, queryLength - 1) * bonusConsecutive
        let normalizedScore = max(0, min(1, rawScore / maxScore))

        // Convert indices to ranges
        let ranges = matchedIndices.map { idx in idx..<normalizedCandidate.index(after: idx) }

        return MatchResult(isMatch: true, score: normalizedScore, matchedRanges: ranges)
    }

    private static func findBestMatch(
        for char: Character,
        in candidate: String,
        original: String,
        startingFrom start: String.Index,
        isConsecutivePreferred: Bool
    ) -> String.Index? {
        var bestMatch: String.Index?
        var bestBonus: Double = -.infinity

        var index = start
        while index < candidate.endIndex {
            if candidate[index] == char {
                let bonus = bonusFor(candidate: original, normalizedCandidate: candidate, at: index)

                // Strong preference for consecutive matches when continuing a run
                let effectiveBonus = isConsecutivePreferred && index == start ? bonus + 100 : bonus

                if effectiveBonus > bestBonus {
                    bestBonus = effectiveBonus
                    bestMatch = index
                }

                // If we found a boundary match, stop searching (good enough)
                if bonus >= bonusBoundary { break }
            }
            index = candidate.index(after: index)
        }

        return bestMatch
    }

    private static func bonusFor(
        candidate: String,
        normalizedCandidate: String,
        at index: String.Index
    ) -> Double {
        // Start of string
        if index == normalizedCandidate.startIndex {
            return bonusBoundaryWhite
        }

        let prevIndex = normalizedCandidate.index(before: index)
        let prevChar = normalizedCandidate[prevIndex]

        // After whitespace
        if prevChar.isWhitespace {
            return bonusBoundaryWhite
        }

        // After common delimiters
        if "-_./".contains(prevChar) {
            return bonusBoundary
        }

        // camelCase: check original string for case transitions
        let originalPrevIndex = candidate.index(before: index)
        let originalPrevChar = candidate[originalPrevIndex]
        let currChar = candidate[index]

        if originalPrevChar.isLowercase && currChar.isUppercase {
            return bonusCamel
        }

        // Number boundary
        if !originalPrevChar.isNumber && currChar.isNumber {
            return bonusCamel
        }

        return 0
    }
}
