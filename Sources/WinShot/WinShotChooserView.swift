/// Horizontal strip view containing WinShot snapshot thumbnails
import AppKit

protocol WinShotChooserViewDelegate: AnyObject {
    func chooserView(_ view: WinShotChooserView, didRequestDelete snapshotId: UUID)
    func chooserView(_ view: WinShotChooserView, didSelect snapshotId: UUID)
}

final class WinShotChooserView: NSView, WinShotThumbnailViewDelegate {
    weak var delegate: WinShotChooserViewDelegate?

    private var thumbnailViews: [WinShotThumbnailView] = []
    private var selectedIndex: Int = 0
    private var hoveredSnapshotId: UUID?
    private var timelineView: WinShotTimelineView?
    private let scrollView: NSScrollView
    private let containerView: NSView

    private static let padding: CGFloat = 20
    private static let spacing: CGFloat = 16
    private static let minVisibleTileCount = 1
    private static let fallbackVisibleTileCount = 5
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

    /// Configure the view with snapshots, selecting the first one by default
    func configure(with snapshots: [WinShotSnapshot]) {
        // Remove existing content views.
        containerView.subviews.forEach { $0.removeFromSuperview() }
        thumbnailViews.removeAll()
        hoveredSnapshotId = nil
        timelineView = nil

        containerView.wantsLayer = true

        // Calculate total content width for centering
        let thumbnailSize = WinShotThumbnailView.preferredSize
        let totalContentWidth = CGFloat(snapshots.count) * thumbnailSize.width +
                                CGFloat(max(0, snapshots.count - 1)) * Self.spacing

        // Create new thumbnail views centered in container
        var timelineEntries: [WinShotTimelineView.Entry] = []
        var xOffset: CGFloat = 0

        for snapshot in snapshots {
            let thumbnailView = WinShotThumbnailView(snapshot: snapshot)
            thumbnailView.delegate = self
            thumbnailView.frame.origin = NSPoint(x: xOffset, y: 0)
            thumbnailViews.append(thumbnailView)

            timelineEntries.append(
                WinShotTimelineView.Entry(
                    createdAt: snapshot.createdAt,
                    tileCenterX: xOffset + (thumbnailSize.width / 2)
                )
            )
            xOffset += thumbnailSize.width + Self.spacing
        }

        let contentHeight = thumbnailSize.height + WinShotTimelineView.verticalSpaceAboveThumbnails
        let timelineView = WinShotTimelineView(frame: NSRect(x: 0, y: 0, width: totalContentWidth, height: contentHeight))
        timelineView.configure(entries: timelineEntries)
        containerView.addSubview(timelineView)
        self.timelineView = timelineView

        for thumbnailView in thumbnailViews {
            containerView.addSubview(thumbnailView)
        }

        // Container matches content size exactly; scroll view will center it
        containerView.frame = NSRect(x: 0, y: 0, width: totalContentWidth, height: contentHeight)

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

    /// Returns the number of snapshots
    var snapshotCount: Int {
        thumbnailViews.count
    }

    private func updateSelection() {
        for (index, view) in thumbnailViews.enumerated() {
            view.isSelected = (index == selectedIndex)
        }
        timelineView?.setSelectedIndex(selectedIndex)

        guard selectedIndex < thumbnailViews.count else { return }

        // Scroll to make selected view visible when content is wider than
        // the viewport. When content is smaller, the centering clip view
        // keeps it visually centered.
        let selectedView = thumbnailViews[selectedIndex]
        scrollView.contentView.scrollToVisible(selectedView.frame)
    }

    // MARK: - WinShotThumbnailViewDelegate

    func thumbnailView(_ view: WinShotThumbnailView, didRequestDelete snapshotId: UUID) {
        delegate?.chooserView(self, didRequestDelete: snapshotId)
    }

    func thumbnailView(_ view: WinShotThumbnailView, didClickToSelect snapshotId: UUID) {
        delegate?.chooserView(self, didSelect: snapshotId)
    }

    func thumbnailView(_ view: WinShotThumbnailView, didBeginHover snapshotId: UUID) {
        hoveredSnapshotId = snapshotId
        timelineView?.setHoveredIndex(indexForSnapshotId(snapshotId))
    }

    func thumbnailView(_ view: WinShotThumbnailView, didEndHover snapshotId: UUID) {
        guard hoveredSnapshotId == snapshotId else {
            return
        }

        hoveredSnapshotId = nil
        timelineView?.setHoveredIndex(nil)
    }

    private func indexForSnapshotId(_ snapshotId: UUID) -> Int? {
        thumbnailViews.firstIndex(where: { $0.snapshotId == snapshotId })
    }

    /// Calculate the preferred window size for displaying snapshots on the given screen.
    static func preferredWindowSize(
        for snapshotCount: Int,
        screenVisibleWidth: CGFloat,
        maxSnapshotsStored: Int
    ) -> NSSize {
        let thumbnailSize = WinShotThumbnailView.preferredSize
        let visibleCount = visibleTileCount(
            for: snapshotCount,
            screenVisibleWidth: screenVisibleWidth,
            maxSnapshotsStored: maxSnapshotsStored
        )
        let contentWidth = CGFloat(visibleCount) * thumbnailSize.width +
                           CGFloat(max(0, visibleCount - 1)) * spacing +
                           padding * 2
        let contentHeight = thumbnailSize.height + WinShotTimelineView.verticalSpaceAboveThumbnails + padding * 2

        return NSSize(width: max(contentWidth, minimumWindowWidth), height: contentHeight)
    }

    static func visibleTileCount(
        for snapshotCount: Int,
        screenVisibleWidth: CGFloat,
        maxSnapshotsStored: Int
    ) -> Int {
        let cappedSnapshotCount = max(0, min(snapshotCount, maxSnapshotsStored))
        guard cappedSnapshotCount > 0 else {
            return 0
        }

        if screenVisibleWidth <= 0 {
            return min(cappedSnapshotCount, fallbackVisibleTileCount)
        }

        let widthBudget = max(screenVisibleWidth * maxScreenWidthFraction, minimumWindowWidth)
        let thumbnailSize = WinShotThumbnailView.preferredSize
        let perTileWidth = thumbnailSize.width + spacing
        let fitFloat = (widthBudget - (padding * 2) + spacing) / perTileWidth
        let fitCount = Int(floor(fitFloat))
        let widthLimitedCount = max(minVisibleTileCount, fitCount)

        return min(cappedSnapshotCount, widthLimitedCount)
    }
}
