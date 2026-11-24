/// The Accessibility and Screen Recording permission banners, shown in Preferences (General tab) and in the
/// tour. Each says whether its permission is granted and opens its System Settings pane. macOS posts no
/// notification when a permission changes, so the banners poll while their owner has them on screen.
import AppKit
import ApplicationServices

final class PermissionBannersView: NSView {
    struct Permissions: OptionSet {
        let rawValue: Int
        static let accessibility = Permissions(rawValue: 1 << 0)
        static let screenRecording = Permissions(rawValue: 1 << 1)
        static let all: Permissions = [.accessibility, .screenRecording]
    }

    /// The permissions these banners show.
    let permissions: Permissions

    /// Called when polling finds that Accessibility went from missing to granted. Zonogy restarts then, so
    /// that everything that needs the permission starts with it.
    var onAccessibilityGranted: (() -> Void)?

    /// Whether Accessibility was granted when last looked at, first when the first banners are made. Shared
    /// by every set of banners, so a grant is noticed whichever of them polls next, even one made after it.
    private static var lastKnownAccessibilityState = AXIsProcessTrusted()

    private let accessibilityBanner = Banner(settingsPane: "Privacy_Accessibility")
    private let screenRecordingBanner = Banner(settingsPane: "Privacy_ScreenCapture")
    private var pollingTimer: Timer?

    init(showing permissions: Permissions = .all) {
        self.permissions = permissions
        super.init(frame: .zero)
        let banners = [(Permissions.accessibility, accessibilityBanner), (.screenRecording, screenRecordingBanner)]
            .filter { permissions.contains($0.0) }
            .map(\.1)
        let stack = NSStackView(views: banners)
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ] + banners.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        _ = Self.lastKnownAccessibilityState  // Looked at now, so a grant from here on is noticed.
        sync()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        pollingTimer?.invalidate()
    }

    func startPolling() {
        stopPolling()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer.tolerance = 0.5
        pollingTimer = timer
    }

    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func poll() {
        let hasAccessibility = AXIsProcessTrusted()
        let wasGranted = hasAccessibility && !Self.lastKnownAccessibilityState
        Self.lastKnownAccessibilityState = hasAccessibility
        if wasGranted {
            onAccessibilityGranted?()
            return  // App is restarting, skip UI update
        }
        sync()
    }

    private func sync() {
        let hasAccessibility = AXIsProcessTrusted()
        accessibilityBanner.show(
            isGranted: hasAccessibility,
            text: hasAccessibility
                ? "Accessibility permission granted"
                : "Accessibility permission required")
        let hasScreenRecording = CGPreflightScreenCaptureAccess()
        screenRecordingBanner.show(
            isGranted: hasScreenRecording,
            text: "Screen Recording permission \(hasScreenRecording ? "granted" : "not granted") (for WinShot Snapshots)")
    }
}

/// One permission's status, tinted green once granted, with a button to its System Settings pane.
private final class Banner: NSView {
    private let settingsPane: String
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")

    init(settingsPane: String) {
        self.settingsPane = settingsPane
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .labelColor
        let button = NSButton(title: "Open Settings…", target: self, action: #selector(openSettings))
        button.bezelStyle = .recessed
        button.controlSize = .small
        for view in [icon, label, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),

            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(isGranted: Bool, text: String) {
        let tint: NSColor = isGranted ? .systemGreen : .systemOrange
        layer?.backgroundColor = tint.withAlphaComponent(0.15).cgColor
        icon.image = NSImage(
            systemSymbolName: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: isGranted ? "Granted" : "Required")
        icon.contentTintColor = tint
        label.stringValue = text
    }

    @objc private func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsPane)")!
        NSWorkspace.shared.open(url)
    }
}
