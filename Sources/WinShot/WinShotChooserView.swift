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
    private let scrollView: NSScrollView
    private let containerView: NSView

    private static let padding: CGFloat = 20
    private static let spacing: CGFloat = 16
    private static let titleHeight: CGFloat = 30

    override init(frame frameRect: NSRect) {
        scrollView = NSScrollView()
        containerView = NSView()

        super.init(frame: frameRect)

        wantsLayer = true

        // Setup scroll view
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = containerView

        addSubview(scrollView)

        // Add title label
        let titleLabel = NSTextField(labelWithString: "WinShot Snapshots")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        addSubview(titleLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
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
        // Remove existing thumbnail views
        for view in thumbnailViews {
            view.removeFromSuperview()
        }
        thumbnailViews.removeAll()

        // Create new thumbnail views
        let thumbnailSize = WinShotThumbnailView.preferredSize
        var xOffset: CGFloat = 0

        for snapshot in snapshots {
            let thumbnailView = WinShotThumbnailView(snapshot: snapshot)
            thumbnailView.delegate = self
            thumbnailView.frame.origin = NSPoint(x: xOffset, y: 0)
            containerView.addSubview(thumbnailView)
            thumbnailViews.append(thumbnailView)

            xOffset += thumbnailSize.width + Self.spacing
        }

        // Update container size
        let totalWidth = max(0, xOffset - Self.spacing)
        containerView.frame = NSRect(x: 0, y: 0, width: totalWidth, height: thumbnailSize.height)

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

        // Scroll to make selected view visible
        if selectedIndex < thumbnailViews.count {
            let selectedView = thumbnailViews[selectedIndex]
            scrollView.contentView.scrollToVisible(selectedView.frame)
        }
    }

    // MARK: - WinShotThumbnailViewDelegate

    func thumbnailView(_ view: WinShotThumbnailView, didRequestDelete snapshotId: UUID) {
        delegate?.chooserView(self, didRequestDelete: snapshotId)
    }

    /// Calculate the preferred window size for displaying the given number of snapshots
    static func preferredWindowSize(for snapshotCount: Int) -> NSSize {
        let thumbnailSize = WinShotThumbnailView.preferredSize
        let maxVisible = min(snapshotCount, 5)  // Show at most 5 thumbnails without scrolling

        let contentWidth = CGFloat(maxVisible) * thumbnailSize.width +
                           CGFloat(max(0, maxVisible - 1)) * spacing +
                           padding * 2
        let contentHeight = thumbnailSize.height + titleHeight + padding * 2

        return NSSize(width: max(contentWidth, 300), height: contentHeight)
    }
}
