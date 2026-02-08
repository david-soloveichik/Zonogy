/// Force-click suppression helpers for drag interactions and drag-capable UI surfaces.
import AppKit

enum ForceClickSuppression {
    private static let primaryClickConfiguration = NSPressureConfiguration(pressureBehavior: .primaryClick)

    /// Configure a view to treat deep presses as regular primary clicks.
    static func apply(to view: NSView) {
        view.pressureConfiguration = primaryClickConfiguration
    }
}
