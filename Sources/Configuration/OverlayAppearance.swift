/// The user's look for everything Zonogy draws on the desktop (placeholders, zone indicators and
/// bars, drag overlays, the zone-navigation circle, zone resize bars): a highlight color, blue by
/// default, and an opacity scale that multiplies every overlay opacity. Persists both, and posts
/// `didChangeNotification` on change so long-lived overlays restyle; transient overlays read the
/// current colors whenever they appear.
import AppKit

enum OverlayAppearance {
    static let defaultHighlightColor: NSColor = .systemBlue
    static let opacityScaleRange: ClosedRange<CGFloat> = 0.25...1.5
    static let didChangeNotification = Notification.Name("Zonogy.overlayAppearanceDidChange")

    /// The color the user picked, or nil for the default blue.
    private(set) static var customHighlightColor: NSColor? = loadCustomHighlightColor()
    private(set) static var opacityScale: CGFloat = loadOpacityScale()

    static var highlightColor: NSColor {
        customHighlightColor ?? defaultHighlightColor
    }

    /// The highlight color at `alpha`, scaled by the opacity setting.
    static func highlight(_ alpha: CGFloat) -> NSColor {
        highlightColor.withAlphaComponent(scaled(alpha))
    }

    /// White at `alpha`, scaled by the opacity setting.
    static func white(_ alpha: CGFloat) -> NSColor {
        NSColor.white.withAlphaComponent(scaled(alpha))
    }

    /// `alpha` scaled by the opacity setting, capped at fully opaque.
    static func scaled(_ alpha: CGFloat) -> CGFloat {
        min(1, alpha * opacityScale)
    }

    /// Pass nil to restore the default blue.
    static func setCustomHighlightColor(_ color: NSColor?) {
        customHighlightColor = color
        if let color, let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: UserDefaultsKeys.overlayHighlightColor)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.overlayHighlightColor)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func setOpacityScale(_ scale: CGFloat) {
        let clamped = clampedOpacityScale(scale)
        // The slider reports every pixel of a drag; restyle only when the stored step changes.
        guard clamped != opacityScale else { return }
        opacityScale = clamped
        UserDefaults.standard.set(Double(opacityScale), forKey: UserDefaultsKeys.overlayOpacityScale)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Calls `selector` on `observer` after every change. NotificationCenter drops the
    /// observer when it deallocates.
    static func addObserver(_ observer: Any, selector: Selector) {
        NotificationCenter.default.addObserver(observer, selector: selector, name: didChangeNotification, object: nil)
    }

    private static func loadCustomHighlightColor() -> NSColor? {
        guard let data = UserDefaults.standard.data(forKey: UserDefaultsKeys.overlayHighlightColor) else {
            return nil
        }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }

    private static func loadOpacityScale() -> CGFloat {
        guard let stored = UserDefaults.standard.object(forKey: UserDefaultsKeys.overlayOpacityScale) as? Double else {
            return 1
        }
        return clampedOpacityScale(CGFloat(stored))
    }

    private static func clampedOpacityScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, opacityScaleRange.lowerBound), opacityScaleRange.upperBound)
    }
}
