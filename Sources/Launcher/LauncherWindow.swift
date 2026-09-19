/// Floating panel window for the Launcher overlay

import AppKit

final class LauncherWindow: FrostedPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 450, height: 400), cornerRadius: 16)
        collectionBehavior = [.transient, .ignoresCycle]
    }

    /// Runs each time the panel becomes key, including when AppKit hands key status back after
    /// another Zonogy panel that opened over the Launcher (the WinShot chooser) closes.
    var onDidBecomeKey: (() -> Void)?

    override func becomeKey() {
        super.becomeKey()
        onDidBecomeKey?()
    }
}
