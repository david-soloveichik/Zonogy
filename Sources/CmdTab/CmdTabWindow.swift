/// Floating panel window for the CmdTab overlay

import AppKit

final class CmdTabWindow: FrostedPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 350), cornerRadius: 16)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }
}
