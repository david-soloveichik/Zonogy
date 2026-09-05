/// Shared Instruments signpost handles for correlating Zonogy work with CPU and wakeup traces.

import OSLog

enum ZonogySignposts {
    /// Use the system Points of Interest category so standard Instruments templates capture these signposts.
    static let pointsOfInterest = OSSignposter(
        subsystem: Logger.subsystem,
        category: .pointsOfInterest
    )
}
