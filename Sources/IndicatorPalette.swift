import AppKit

/// Shared visual constants for targeted pill indicators so normal and temporary pills stay consistent.
enum IndicatorPalette {
    static let targetedFillColor = NSColor.systemBlue.withAlphaComponent(0.55)
    static let targetedBorderColor = NSColor.systemBlue.withAlphaComponent(0.75)
    static let targetedShadowColor = NSColor.systemBlue.withAlphaComponent(0.6)
    static let targetedShadowOpacity: Float = 0.6
    static let targetedShadowRadius: CGFloat = 6
    static let defaultBorderWidth: CGFloat = 1.2
}
