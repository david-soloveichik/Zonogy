/// Horizontal strip view containing WinShot snapshot thumbnails.
/// Thumbnails are newest-first (left), separated by log-scaled gaps that
/// convey the time elapsed between consecutive snapshots.
import AppKit

protocol WinShotChooserViewDelegate: AnyObject {
    func chooserView(_ view: WinShotChooserView, didRequestDelete snapshotId: UUID)
    func chooserView(_ view: WinShotChooserView, didSelect snapshotId: UUID)
}

final class WinShotChooserView: NSView, WinShotThumbnailViewDelegate {
    weak var delegate: WinShotChooserViewDelegate?

    private var thumbnailViews: [WinShotThumbnailView] = []
    private var selectedIndex: Int = 0
    private let scrollView: NSScrollView
    private let containerView: NSView

    private static let padding: CGFloat = 20
    private static let maxScreenWidthFraction: CGFloat = 0.9
    private static let minimumWindowWidth: CGFloat = 300

    override init(frame frameRect: NSRect) {
        scrollView = NSScrollView()
        containerView = NSView()

        super.init(frame: frameRect)

        wantsLayer = true

        // Use a centering clip view so that when the content is smaller
        // than the scroll view's visible area, it stays visually centered.
        let clipView = WinShotCenteringClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        // Setup scroll view
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = containerView

        addSubview(scrollView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Configure the view with snapshots (newest-first), selecting the first one by default.
    func configure(with snapshots: [WinShotSnapshot]) {
        // Remove existing content views.
        containerView.subviews.forEach { $0.removeFromSuperview() }
        thumbnailViews.removeAll()

        containerView.wantsLayer = true

        let thumbnailSize = WinShotThumbnailView.preferredSize
        let leadingGaps = WinShotGapLayout.leadingGaps(times: snapshots.map(\.lastActiveAt))

        // Lay thumbnails out left-to-right, inserting each snapshot's leading gap
        // (the log-scaled time delta to the previous, newer snapshot) before it.
        var xOffset: CGFloat = 0
        for (index, snapshot) in snapshots.enumerated() {
            xOffset += leadingGaps[index]

            let thumbnailView = WinShotThumbnailView(snapshot: snapshot)
            thumbnailView.delegate = self
            thumbnailView.frame.origin = NSPoint(x: xOffset, y: 0)
            thumbnailViews.append(thumbnailView)
            containerView.addSubview(thumbnailView)

            xOffset += thumbnailSize.width
        }

        // Container matches content size exactly; scroll view will center it.
        containerView.frame = NSRect(x: 0, y: 0, width: xOffset, height: thumbnailSize.height)

        // Select first item
        selectedIndex = 0
        updateSelection()
    }

    /// Select the next snapshot (wraps around)
    func selectNext() {
        guard !thumbnailViews.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % thumbnailViews.count
        updateSelection()
    }

    /// Select the previous snapshot (wraps around)
    func selectPrevious() {
        guard !thumbnailViews.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + thumbnailViews.count) % thumbnailViews.count
        updateSelection()
    }

    /// Select a specific index
    func selectIndex(_ index: Int) {
        guard index >= 0, index < thumbnailViews.count else { return }
        selectedIndex = index
        updateSelection()
    }

    /// Returns the currently selected snapshot ID
    var selectedSnapshotId: UUID? {
        guard selectedIndex < thumbnailViews.count else { return nil }
        return thumbnailViews[selectedIndex].snapshotId
    }

    /// Index of the currently selected thumbnail, or nil when there are none.
    var selectedThumbnailIndex: Int? {
        thumbnailViews.isEmpty ? nil : selectedIndex
    }

    /// Returns the number of snapshots
    var snapshotCount: Int {
        thumbnailViews.count
    }

    private func updateSelection() {
        for (index, view) in thumbnailViews.enumerated() {
            view.isSelected = (index == selectedIndex)
        }

        guard selectedIndex < thumbnailViews.count else { return }

        // Scroll the selected thumbnail into view when content is wider than
        // the viewport. Calling scrollToVisible on the thumbnail (a document-view
        // subview) scrolls its enclosing clip view in the correct coordinate space;
        // it is a no-op when the content already fits, so the centering clip view
        // keeps a small set visually centered.
        let selectedView = thumbnailViews[selectedIndex]
        selectedView.scrollToVisible(selectedView.bounds)
    }

    // MARK: - WinShotThumbnailViewDelegate

    func thumbnailView(_ view: WinShotThumbnailView, didRequestDelete snapshotId: UUID) {
        delegate?.chooserView(self, didRequestDelete: snapshotId)
    }

    func thumbnailView(_ view: WinShotThumbnailView, didClickToSelect snapshotId: UUID) {
        delegate?.chooserView(self, didSelect: snapshotId)
    }

    /// Calculate the preferred window size for displaying the given snapshots on a screen.
    /// Width fits the gap-spaced content, capped to a fraction of the screen (the strip
    /// scrolls beyond that); height holds a single row of thumbnails.
    static func preferredWindowSize(
        for snapshots: [WinShotSnapshot],
        screenVisibleWidth: CGFloat
    ) -> NSSize {
        let thumbnailSize = WinShotThumbnailView.preferredSize
        let leadingGaps = WinShotGapLayout.leadingGaps(times: snapshots.map(\.lastActiveAt))
        let contentWidth = WinShotGapLayout.contentWidth(
            tileWidth: thumbnailSize.width,
            leadingGaps: leadingGaps
        )

        let desiredWidth = contentWidth + padding * 2
        let cappedWidth: CGFloat
        if screenVisibleWidth > 0 {
            let maxWidth = max(screenVisibleWidth * maxScreenWidthFraction, minimumWindowWidth)
            cappedWidth = min(desiredWidth, maxWidth)
        } else {
            cappedWidth = desiredWidth
        }

        let width = max(cappedWidth, minimumWindowWidth)
        let height = thumbnailSize.height + padding * 2
        return NSSize(width: width, height: height)
    }
}
