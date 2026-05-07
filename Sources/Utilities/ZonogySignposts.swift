/// Shared Instruments signpost handles for correlating Zonogy work with CPU and wakeup traces.

import OSLog

enum ZonogySignposts {
    static let subsystem = "com.dsemeas.zonogy"

    /// Use the system Points of Interest category so standard Instruments templates capture these signposts.
    static let pointsOfInterest = OSSignposter(
        subsystem: subsystem,
        category: .pointsOfInterest
    )
}
