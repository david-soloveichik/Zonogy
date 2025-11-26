/// Individual thumbnail view for a WinShot snapshot
import AppKit

protocol WinShotThumbnailViewDelegate: AnyObject {
    func thumbnailView(_ view: WinShotThumbnailView, didRequestDelete snapshotId: UUID)
}

final class WinShotThumbnailView: NSView {
    weak var delegate: WinShotThumbnailViewDelegate?

    let snapshotId: UUID
    private let imageView: NSImageView
    private let deleteButton: NSButton
    private let selectionBorder: CALayer

    var isSelected: Bool = false {
        didSet {
            updateSelectionAppearance()
        }
    }

    private static let thumbnailSize = NSSize(width: 160, height: 100)
    private static let cornerRadius: CGFloat = 8
    private static let selectionBorderWidth: CGFloat = 3
    private static let deleteButtonSize: CGFloat = 20

    init(snapshot: WinShotSnapshot) {
        self.snapshotId = snapshot.id

        // Create image view for thumbnail
        imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Self.cornerRadius
        imageView.layer?.masksToBounds = true
        imageView.image = snapshot.thumbnail

        // Create delete button
        deleteButton = NSButton()
        deleteButton.bezelStyle = .circular
        deleteButton.isBordered = false
        deleteButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Delete snapshot")
        deleteButton.contentTintColor = .systemRed
        deleteButton.isHidden = true  // Show on hover

        // Create selection border layer
        selectionBorder = CALayer()
        selectionBorder.borderColor = NSColor.systemBlue.cgColor
        selectionBorder.borderWidth = Self.selectionBorderWidth
        selectionBorder.cornerRadius = Self.cornerRadius + 2
        selectionBorder.isHidden = true

        super.init(frame: NSRect(origin: .zero, size: Self.thumbnailSize))

        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius

        // Add subviews
        addSubview(imageView)
        addSubview(deleteButton)
        layer?.addSublayer(selectionBorder)

        // Setup constraints
        imageView.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            deleteButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
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
        selectionBorder.frame = bounds.insetBy(dx: -Self.selectionBorderWidth, dy: -Self.selectionBorderWidth)
    }

    override func mouseEntered(with event: NSEvent) {
        deleteButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        deleteButton.isHidden = true
    }

    @objc private func deleteButtonClicked() {
        delegate?.thumbnailView(self, didRequestDelete: snapshotId)
    }

    private func updateSelectionAppearance() {
        selectionBorder.isHidden = !isSelected

        if isSelected {
            layer?.shadowColor = NSColor.systemBlue.cgColor
            layer?.shadowOpacity = 0.5
            layer?.shadowRadius = 8
            layer?.shadowOffset = .zero
        } else {
            layer?.shadowOpacity = 0
        }
    }

    static var preferredSize: NSSize {
        thumbnailSize
    }
}
