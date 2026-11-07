import AppKit

/// Shared visual constants for targeted pill indicators so normal and floating pills stay consistent.
enum IndicatorPalette {
    static var targetedFillColor: NSColor { OverlayAppearance.highlight(0.55) }
    static var targetedBorderColor: NSColor { OverlayAppearance.highlight(0.75) }
    static var targetedShadowColor: NSColor { OverlayAppearance.highlight(0.6) }
    static let targetedShadowOpacity: Float = 0.6
    static let targetedShadowRadius: CGFloat = 6
    static let defaultBorderWidth: CGFloat = 1.2
}
