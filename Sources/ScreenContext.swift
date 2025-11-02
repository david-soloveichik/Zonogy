import AppKit

/// Bundles screen metadata with its associated zone controller
struct ScreenContext {
    var descriptor: ScreenDescriptor
    let zoneController: ZoneController
}
