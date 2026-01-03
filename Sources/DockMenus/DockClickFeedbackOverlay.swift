import AppKit

/// Shows a brief ripple animation centered on a clicked Dock item to provide visual feedback.
final class DockClickFeedbackOverlay {
    private final class OverlayWindow: NSPanel {
        init() {
            super.init(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            isReleasedWhenClosed = false
            isFloatingPanel = true
            becomesKeyOnlyIfNeeded = false
            ignoresMouseEvents = true
            isOpaque = false
            hasShadow = false
            backgroundColor = .clear
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)
            collectionBehavior = [
                .canJoinAllSpaces,
                .ignoresCycle,
                .transient
            ]
        }

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class RippleView: NSView {
        private let rippleLayer = CAShapeLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor

            rippleLayer.fillColor = NSColor.white.withAlphaComponent(0.4).cgColor
            rippleLayer.strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
            rippleLayer.lineWidth = 2.0
            rippleLayer.opacity = 0
            layer?.addSublayer(rippleLayer)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            updateRipplePath()
        }

        private func updateRipplePath() {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let radius = min(bounds.width, bounds.height) / 2
            rippleLayer.path = CGPath(ellipseIn: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ), transform: nil)
            rippleLayer.frame = bounds
        }

        func animate(completion: @escaping () -> Void) {
            CATransaction.begin()
            CATransaction.setCompletionBlock(completion)

            // Scale animation: expand from center
            let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
            scaleAnimation.fromValue = 0.3
            scaleAnimation.toValue = 1.2
            scaleAnimation.duration = 0.25
            scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)

            // Opacity animation: fade out
            let opacityAnimation = CABasicAnimation(keyPath: "opacity")
            opacityAnimation.fromValue = 1.0
            opacityAnimation.toValue = 0.0
            opacityAnimation.duration = 0.25
            opacityAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let group = CAAnimationGroup()
            group.animations = [scaleAnimation, opacityAnimation]
            group.duration = 0.25
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false

            rippleLayer.add(group, forKey: "ripple")

            CATransaction.commit()
        }

        func reset() {
            rippleLayer.removeAllAnimations()
            rippleLayer.opacity = 0
            rippleLayer.transform = CATransform3DIdentity
        }
    }

    private let primaryScreenBounds: CGRect
    private let window = OverlayWindow()
    private let rippleView = RippleView(frame: .zero)

    init(primaryScreenBounds: CGRect) {
        self.primaryScreenBounds = primaryScreenBounds
        window.contentView = rippleView
    }

    /// Shows a ripple animation centered on the given accessibility frame.
    /// - Parameter accessibilityFrame: The frame of the Dock item in accessibility coordinates.
    func showRipple(at accessibilityFrame: CGRect) {
        // Convert to Cocoa coordinates
        let cocoaFrame = CoordinateConversion.accessibilityToCocoa(
            accessibilityFrame: accessibilityFrame,
            primaryScreenBounds: primaryScreenBounds
        )

        // Make the ripple window proportionally smaller than the dock item
        let size = max(cocoaFrame.width, cocoaFrame.height) * 0.75
        let rippleFrame = CGRect(
            x: cocoaFrame.midX - size / 2,
            y: cocoaFrame.midY - size / 2,
            width: size,
            height: size
        ).integral

        rippleView.reset()
        window.setFrame(rippleFrame, display: true)
        window.orderFrontRegardless()

        rippleView.animate { [weak self] in
            self?.window.orderOut(nil)
        }
    }
}
