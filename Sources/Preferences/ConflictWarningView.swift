/// The yellow warning triangle marking a shortcut conflict, wherever one is shown: beside a
/// contested shortcut in the table, on the Zone Navigation card, and in the Zone Navigation
/// editor's live check. One view so the three sites match, and so the explanation travels the same
/// way everywhere — as the tooltip, and as what VoiceOver reads.
import AppKit

final class ConflictWarningView: NSImageView {
    /// The explanation, e.g. "Also used by Add Zone", shown as the tooltip and read by VoiceOver.
    /// A mark with none is decoration — whatever it stands beside carries the meaning — and reads
    /// simply as a warning.
    var text: String? {
        didSet { apply() }
    }

    init(text: String? = nil) {
        self.text = text
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        contentTintColor = .systemYellow
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        apply()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The spoken text rides on the image itself: an image view's accessibility element is its
    /// cell, which reads the image's description, so a label set on the view would only add a
    /// second, roleless element.
    private func apply() {
        toolTip = text
        image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: text ?? "Warning")
    }
}
