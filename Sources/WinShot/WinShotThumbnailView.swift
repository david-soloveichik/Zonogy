/// Individual thumbnail view for a WinShot snapshot
import AppKit

protocol WinShotThumbnailViewDelegate: AnyObject {
    func thumbnailView(_ view: WinShotThumbnailView, didRequestDelete snapshotId: UUID)
    func thumbnailView(_ view: WinShotThumbnailView, didClickToSelect snapshotId: UUID)
    func thumbnailView(_ view: WinShotThumbnailView, didBeginHover snapshotId: UUID)
    func thumbnailView(_ view: WinShotThumbnailView, didEndHover snapshotId: UUID)
}

final class WinShotThumbnailView: NSView {
    weak var delegate: WinShotThumbnailViewDelegate?

    let snapshotId: UUID
    private let imageLayer: CALayer  // Use CALayer for proper aspect-fill
    private let imageContainerView: NSView  // Container for clipping
    private let deleteButton: NSButton
    private let selectionBorder: CALayer
    private static let selectionColor = NSColor(calibratedRed: 0.15, green: 0.35, blue: 0.85, alpha: 1.0)

    var isSelected: Bool = false {
        didSet {
            updateSelectionAppearance()
        }
    }

    private static let imageSize = NSSize(width: 160, height: 100)
    private static let borderGap: CGFloat = 6  // Gap between image and selection border
    private static let thumbnailSize = NSSize(
        width: imageSize.width + borderGap * 2,
        height: imageSize.height + borderGap * 2
    )
    private static let imageCornerRadius: CGFloat = 8
    private static let borderCornerRadius: CGFloat = 12  // Slightly larger for the outer border
    private static let selectionBorderWidth: CGFloat = 3
    private static let deleteButtonSize: CGFloat = 20

    init(snapshot: WinShotSnapshot) {
        self.snapshotId = snapshot.id

        // Create container view for the image with rounded corners and clipping
        imageContainerView = NSView()
        imageContainerView.wantsLayer = true
        imageContainerView.layer?.cornerRadius = Self.imageCornerRadius
        imageContainerView.layer?.masksToBounds = true  // Clip image to rounded corners

        // Create image layer with aspect-fill behavior
        imageLayer = CALayer()
        imageLayer.contentsGravity = .resizeAspectFill  // Aspect-fill: scale to fill, clip overflow
        if let thumbnail = snapshot.thumbnail {
            imageLayer.contents = thumbnail.layerContents(forContentsScale: 2.0)
        }

        // Create delete button
        deleteButton = NSButton()
        deleteButton.bezelStyle = .circular
        deleteButton.isBordered = false
        deleteButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Delete snapshot")
        deleteButton.contentTintColor = .systemRed
        deleteButton.isHidden = true  // Show on hover

        // Create selection border layer using the WinShot accent blue
        selectionBorder = CALayer()
        selectionBorder.borderColor = Self.selectionColor.withAlphaComponent(0.9).cgColor
        selectionBorder.borderWidth = Self.selectionBorderWidth
        selectionBorder.cornerRadius = Self.borderCornerRadius
        selectionBorder.isHidden = true

        super.init(frame: NSRect(origin: .zero, size: Self.thumbnailSize))

        wantsLayer = true
        layer?.masksToBounds = false  // Allow glow to extend beyond bounds

        // Add image layer to container
        imageContainerView.layer?.addSublayer(imageLayer)

        // Add subviews
        addSubview(imageContainerView)
        addSubview(deleteButton)

        // Add selection border on top
        layer?.addSublayer(selectionBorder)
        selectionBorder.zPosition = 100

        // Setup constraints - image container is inset by borderGap on all sides
        imageContainerView.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            imageContainerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.borderGap),
            imageContainerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.borderGap),
            imageContainerView.topAnchor.constraint(equalTo: topAnchor, constant: Self.borderGap),
            imageContainerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.borderGap),

            deleteButton.topAnchor.constraint(equalTo: imageContainerView.topAnchor, constant: 4),
            deleteButton.leadingAnchor.constraint(equalTo: imageContainerView.leadingAnchor, constant: 4),
            deleteButton.widthAnchor.constraint(equalToConstant: Self.deleteButtonSize),
            deleteButton.heightAnchor.constraint(equalToConstant: Self.deleteButtonSize),
        ])

        deleteButton.target = self
        deleteButton.action = #selector(deleteButtonClicked)

        // Setup tracking area for hover
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // Position selection border at the full bounds (outside the image)
        selectionBorder.frame = bounds
        // Update image layer to fill the container
        imageLayer.frame = imageContainerView.bounds
    }

    override func mouseEntered(with event: NSEvent) {
        deleteButton.isHidden = false
        delegate?.thumbnailView(self, didBeginHover: snapshotId)
    }

    override func mouseExited(with event: NSEvent) {
        deleteButton.isHidden = true
        delegate?.thumbnailView(self, didEndHover: snapshotId)
    }

    override func mouseUp(with event: NSEvent) {
        // Check if click was on the delete button area - if so, ignore (button handles it)
        let locationInView = convert(event.locationInWindow, from: nil)
        if deleteButton.frame.contains(locationInView) {
            return
        }
        // Click on thumbnail - request selection/restore
        delegate?.thumbnailView(self, didClickToSelect: snapshotId)
    }

    @objc private func deleteButtonClicked() {
        delegate?.thumbnailView(self, didRequestDelete: snapshotId)
    }

    private func updateSelectionAppearance() {
        selectionBorder.isHidden = !isSelected
    }

    static var preferredSize: NSSize {
        thumbnailSize
    }
}
