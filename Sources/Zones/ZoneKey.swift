import CoreGraphics

/// Identifies a zone uniquely by display and index.
struct ZoneKey: Hashable {
    let screenId: CGDirectDisplayID
    let index: Int
}

