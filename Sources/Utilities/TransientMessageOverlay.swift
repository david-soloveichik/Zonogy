/// Briefly shows a message above other windows without taking focus or intercepting clicks.
import AppKit

final class TransientMessageOverlay {
    static let shared = TransientMessageOverlay()

    private let panel = MessagePanel()
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private var dismissalTimer: Timer?

    private init() {
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: panel.frame.size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        bodyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        bodyLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, bodyLabel] {
            label.lineBreakMode = .byTruncatingMiddle
            label.usesSingleLineMode = true
            label.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(label)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            titleLabel.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
        ])
        panel.contentView = background
    }

    /// Shows on the pointer's display. Each message restarts the four-second display period.
    func show(title: String, body: String) {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else {
            return
        }

        dismissalTimer?.invalidate()
        titleLabel.stringValue = title
        bodyLabel.stringValue = body
        panel.setFrameOrigin(NSPoint(
            x: (screen.visibleFrame.midX - panel.frame.width / 2).rounded(),
            y: (screen.visibleFrame.maxY - panel.frame.height - 24).rounded()
        ))
        panel.orderFrontRegardless()

        let timer = Timer(timeInterval: 4, repeats: false) { [weak self] _ in
            self?.panel.orderOut(nil)
            self?.dismissalTimer = nil
        }
        dismissalTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

private final class MessagePanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 370, height: 76),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
