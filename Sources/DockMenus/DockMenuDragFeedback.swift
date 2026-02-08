/// Visual feedback during DockMenu drag operations - shows a floating preview following the cursor.

import AppKit

final class DockMenuDragFeedback {
    private var feedbackWindow: NSWindow?
    private var titleLabel: NSTextField?

    func show(title: String, at mouseLocation: CGPoint) {
        // Create feedback window if needed
        if feedbackWindow == nil {
            createFeedbackWindow()
        }

        guard let feedbackWindow, let titleLabel else { return }

        // Update title
        titleLabel.stringValue = title

        // Size to fit content
        titleLabel.sizeToFit()
        let padding: CGFloat = 16
        let windowSize = NSSize(
            width: min(titleLabel.frame.width + padding * 2, 250),
            height: titleLabel.frame.height + padding
        )
        feedbackWindow.setContentSize(windowSize)

        // Position at cursor
        updatePosition(at: mouseLocation)

        // Show with fade in
        feedbackWindow.alphaValue = 0
        feedbackWindow.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            feedbackWindow.animator().alphaValue = 1
        }
    }

    func show(title: String) {
        show(title: title, at: NSEvent.mouseLocation)
    }

    func updatePosition(at mouseLocation: CGPoint) {
        guard let feedbackWindow else { return }

        // Offset slightly below and to the right of cursor
        let offset = NSPoint(x: 12, y: -20)
        feedbackWindow.setFrameOrigin(NSPoint(
            x: mouseLocation.x + offset.x,
            y: mouseLocation.y + offset.y - feedbackWindow.frame.height
        ))
    }

    func updatePosition() {
        updatePosition(at: NSEvent.mouseLocation)
    }

    func hide() {
        guard let feedbackWindow else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            feedbackWindow.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.feedbackWindow?.orderOut(nil)
        })
    }

    private func createFeedbackWindow() {
        // Create borderless floating window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hasShadow = true

        // Create visual effect view for background
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 8
        visualEffect.layer?.masksToBounds = true
        ForceClickSuppression.apply(to: visualEffect)

        // Create label
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        // Add window icon
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // Layout
        visualEffect.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = visualEffect

        let stackView = NSStackView(views: [iconView, label])
        stackView.orientation = .horizontal
        stackView.spacing = 6
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false

        visualEffect.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 10),
            stackView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -10),
            stackView.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
        ])

        self.feedbackWindow = window
        self.titleLabel = label
    }
}
