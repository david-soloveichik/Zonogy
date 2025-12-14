/// Implements Launchbar-style in-order (non-consecutive) character matching.

import Foundation

enum SubsequenceMatcher {
    static func matches(query: String, candidate: String) -> Bool {
        let normalizedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let normalizedCandidate = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        var candidateIndex = normalizedCandidate.startIndex
        for queryCharacter in normalizedQuery {
            guard let matchIndex = normalizedCandidate[candidateIndex...].firstIndex(of: queryCharacter) else {
                return false
            }
            candidateIndex = normalizedCandidate.index(after: matchIndex)
        }
        return true
    }
}
