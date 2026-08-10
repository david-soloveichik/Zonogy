/// Chooses CmdTab's initially selected row in the most-recent-first window list.

enum CmdTabInitialSelectionPolicy {
    /// By default, selection lands on the second entry when the frontmost window is the first
    /// entry (the top row is "where you are"; the default answer to "where do you want to go"
    /// is the previous window), otherwise on the first entry.
    ///
    /// `skipWindowIds` carries windows the user just minimized: selection then lands on the
    /// first entry that is neither the frontmost window nor one of those, so a minimize
    /// followed immediately by CmdTab does not re-offer the window that was just dismissed.
    /// The frontmost window is skipped wherever it appears, not only at the first entry —
    /// right after a minimize, focus can sit on a sibling window anywhere in the list. If
    /// skipping would eliminate every entry, the default rule applies.
    static func initialSelectedIndex(
        orderedWindowIds: [Int?],
        frontmostWindowId: Int?,
        skipWindowIds: Set<Int>
    ) -> Int {
        guard !orderedWindowIds.isEmpty else { return 0 }

        let firstIsFrontmost = frontmostWindowId != nil && orderedWindowIds[0] == frontmostWindowId
        let defaultIndex = firstIsFrontmost ? min(1, orderedWindowIds.count - 1) : 0

        guard !skipWindowIds.isEmpty else { return defaultIndex }

        for (index, windowId) in orderedWindowIds.enumerated() {
            if let windowId, windowId == frontmostWindowId { continue }
            if let windowId, skipWindowIds.contains(windowId) { continue }
            return index
        }
        return defaultIndex
    }
}
