/// A small "More Info…" button that toggles a popover holding detail that would crowd its Preferences pane.
import AppKit

final class MoreInfoButton: NSButton {
    private let makeContent: () -> NSView?
    private var popover: NSPopover?

    /// `makeContent` builds the popover's view, at its fitting size, each time the popover opens.
    init(makeContent: @escaping () -> NSView?) {
        self.makeContent = makeContent
        super.init(frame: .zero)
        title = "More Info…"
        controlSize = .small
        font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        setContentHuggingPriority(.required, for: .horizontal)
        target = self
        action = #selector(togglePopover)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func togglePopover() {
        if let popover, popover.isShown {
            popover.close()
            return
        }
        guard let content = makeContent() else {
            return
        }
        content.layoutSubtreeIfNeeded()
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = content.fittingSize
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        self.popover = popover
    }
}
