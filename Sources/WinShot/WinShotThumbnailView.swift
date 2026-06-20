/// Individual thumbnail view for a WinShot snapshot
import AppKit

protocol WinShotThumbnailViewDelegate: AnyObject {
    func thumbnailView(_ view: WinShotThumbnailView, didRequestDelete snapshotId: UUID)
    func thumbnailView(_ view: WinShotThumbnailView, didClickToSelect snapshotId: UUID)
}

final class WinShotThumbnailView: NSView {
    weak var delegate: WinShotThumbnailViewDelegate?

    let snapshotId: UUID
    private let imageLayer: CALayer  // Use CALayer for proper aspect-fill
    private let imageContainerView: NSView  // Container for clipping
    private let deleteButton: NSButton
    private let selectionBorder: CALayer
    private let tilingIconRow: NSStackView    // Top row: one icon per occupied tiling zone
    private let floatingIconRow: NSStackView  // Bottom row: the floating-zone window's icon, if any
    private static let selectionColor = NSColor(calibratedRed: 0.15, green: 0.35, blue: 0.85, alpha: 1.0)

    var isSelected: Bool = false {
        didSet {
            updateSelectionAppearance()
        }
    }

    private static let imageSize = NSSize(width: 160, height: 100)
    private static let borderGap: CGFloat = 6  // Gap between image and selection border
    private static let iconSize: CGFloat = 19
    private static let iconSpacing: CGFloat = 4       // Between icons within a row
    private static let iconRowTopGap: CGFloat = 4     // Between the image tile and the first icon row
    private static let iconRowSpacing: CGFloat = 4    // Between the tiling row and the floating row
    private static let iconRowBottomPad: CGFloat = 4  // Between the floating row and the view bottom
    private static let thumbnailSize = NSSize(
        width: imageSize.width + borderGap * 2,
        // Image tile (image + selection-border gap) above two centered app-icon rows: tiling zones,
        // then the floating-zone window.
        height: imageSize.height + borderGap * 2 + iconRowTopGap + iconSize + iconRowSpacing + iconSize + iconRowBottomPad
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

        // Build the two app-icon rows: tiling-zone windows (ascending zone index) on top, the
        // floating-zone window (if any) below. Both rows reserve their height so all thumbnails stay
        // the same size whether or not a floating window is present.
        tilingIconRow = Self.makeIconRow(for: snapshot.tilingOccupantsByZoneOrder)
        floatingIconRow = Self.makeIconRow(for: [snapshot.floatingZoneOccupant].compactMap { $0 })

        super.init(frame: NSRect(origin: .zero, size: Self.thumbnailSize))

        wantsLayer = true
        layer?.masksToBounds = false  // Allow glow to extend beyond bounds

        // Add image layer to container
        imageContainerView.layer?.addSublayer(imageLayer)

        // Add subviews
        addSubview(imageContainerView)
        addSubview(deleteButton)
        addSubview(tilingIconRow)
        addSubview(floatingIconRow)

        // Add selection border on top
        layer?.addSublayer(selectionBorder)
        selectionBorder.zPosition = 100

        // Setup constraints - image container is inset by borderGap (left/right/top); the two app-icon
        // rows sit centered below it, the floating row pinned to the view's bottom and the tiling row
        // just above it. Both rows keep a fixed height so the layout is identical with or without a
        // floating window.
        imageContainerView.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        tilingIconRow.translatesAutoresizingMaskIntoConstraints = false
        floatingIconRow.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            imageContainerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.borderGap),
            imageContainerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.borderGap),
            imageContainerView.topAnchor.constraint(equalTo: topAnchor, constant: Self.borderGap),
            imageContainerView.heightAnchor.constraint(equalToConstant: Self.imageSize.height),

            deleteButton.topAnchor.constraint(equalTo: imageContainerView.topAnchor, constant: 4),
            deleteButton.leadingAnchor.constraint(equalTo: imageContainerView.leadingAnchor, constant: 4),
            deleteButton.widthAnchor.constraint(equalToConstant: Self.deleteButtonSize),
            deleteButton.heightAnchor.constraint(equalToConstant: Self.deleteButtonSize),

            tilingIconRow.centerXAnchor.constraint(equalTo: centerXAnchor),
            tilingIconRow.bottomAnchor.constraint(equalTo: floatingIconRow.topAnchor, constant: -Self.iconRowSpacing),
            tilingIconRow.heightAnchor.constraint(equalToConstant: Self.iconSize),

            floatingIconRow.centerXAnchor.constraint(equalTo: centerXAnchor),
            floatingIconRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.iconRowBottomPad),
            floatingIconRow.heightAnchor.constraint(equalToConstant: Self.iconSize),
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
        // Wrap the selection border around the image tile only (not the app-icon row below it).
        selectionBorder.frame = imageContainerView.frame.insetBy(dx: -Self.borderGap, dy: -Self.borderGap)
        // Update image layer to fill the container
        imageLayer.frame = imageContainerView.bounds
    }

    /// Builds a centered horizontal row of app icons for the given occupants (may be empty; the row
    /// still reserves its height via constraints so thumbnail sizes stay uniform).
    private static func makeIconRow(for identities: [WindowIdentity]) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = iconSpacing
        row.alignment = .centerY
        for identity in identities {
            row.addArrangedSubview(makeIconView(for: identity))
        }
        return row
    }

    /// Builds a small app-icon view for a snapshot occupant. Prefers the running application's icon
    /// (snapshots normally reference running apps, since a snapshot is removed when any of its windows
    /// closes), and falls back to a generic placeholder when the bundle id is missing or the app
    /// isn't currently found.
    private static func makeIconView(for identity: WindowIdentity) -> NSImageView {
        let runningApp = identity.bundleIdentifier.flatMap(ApplicationIdentity.runningApplication(bundleIdentifier:))
        let icon = runningApp?.icon
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: "Application")
            ?? NSImage()
        let imageView = NSImageView(image: icon)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.toolTip = runningApp?.localizedName ?? identity.bundleIdentifier ?? identity.windowTitle
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            imageView.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])
        return imageView
    }

    override func mouseEntered(with event: NSEvent) {
        deleteButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        deleteButton.isHidden = true
    }

    /// Route clicks anywhere on the cell (the image or the app-icon row below it) to the thumbnail
    /// itself so a click selects/restores the snapshot; only the delete button stays independently
    /// interactive. Without this, a click on an icon could be swallowed by the NSImageView (an
    /// NSControl subclass) instead of reaching `mouseUp`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else {
            return nil  // Outside the view's bounds — don't claim the click.
        }
        return hit === deleteButton ? deleteButton : self
    }

    override func mouseUp(with event: NSEvent) {
        // hitTest routes delete-button clicks to the button, so any mouseUp reaching the thumbnail is
        // a click on the cell: request selection/restore.
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
