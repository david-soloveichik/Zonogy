/// One page of the Welcome tour, laid out top to bottom: its scene, its title, then its text.
import AppKit

final class TourPageView: NSView {
    static let contentWidth: CGFloat = 580
    private static let bodyFont = NSFont.systemFont(ofSize: 13)
    private static let pointIndent: CGFloat = 14

    /// The page's permission banners, if it has them, for the tour to wire up and to start and stop polling.
    private(set) var permissionBanners: PermissionBannersView?
    private var links: [URL] = []

    init(page: TourPage) {
        super.init(frame: .zero)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])

        if let scene = page.scene {
            let sceneView = TourSceneView(scene: scene)
            stack.addArrangedSubview(sceneView)
            sceneView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            stack.setCustomSpacing(16, after: sceneView)
        }

        let title = NSTextField(labelWithString: page.title)
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(title)

        for block in page.blocks {
            let view = makeView(for: block)
            stack.addArrangedSubview(view)
            if case .link = block { continue }  // A button keeps its own width.
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Blocks

    private func makeView(for block: TourPage.Block) -> NSView {
        switch block {
        case .paragraph(let text):
            return Self.makeLabel(NSAttributedString(string: text, attributes: [.font: Self.bodyFont]), width: Self.contentWidth)
        case .points(let points):
            let list = NSStackView(views: points.map(Self.makeLabel(for:)))
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 6
            return list
        case .tryIt(let text):
            return TryItView(text: text)
        case .permissions:
            let banners = PermissionBannersView()
            permissionBanners = banners
            return banners
        case .link(let title, let url):
            let button = NSButton(title: title, target: self, action: #selector(openLink(_:)))
            button.bezelStyle = .rounded
            button.tag = links.count
            links.append(url)
            return button
        }
    }

    /// A bulleted line: the lead in bold, then the text, wrapping in line with the lead.
    private static func makeLabel(for point: TourPage.Point) -> NSTextField {
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = pointIndent
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: pointIndent)]
        let line = NSMutableAttributedString(string: "•\t", attributes: [.font: bodyFont])
        line.append(leadIn(point.lead, to: point.text))
        line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
        return makeLabel(line, width: contentWidth)
    }

    /// `lead` in bold, then `text`.
    fileprivate static func leadIn(_ lead: String, to text: String, color: NSColor = .labelColor) -> NSAttributedString {
        let line = NSMutableAttributedString(
            string: lead, attributes: [.font: NSFont.systemFont(ofSize: bodyFont.pointSize, weight: .semibold), .foregroundColor: color])
        line.append(NSAttributedString(string: " " + text, attributes: [.font: bodyFont]))
        return line
    }

    fileprivate static func makeLabel(_ text: NSAttributedString, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = text
        label.isSelectable = false
        label.preferredMaxLayoutWidth = width
        return label
    }

    @objc private func openLink(_ sender: NSButton) {
        AppLinks.open(links[sender.tag])
    }
}

/// A "Try it" line, set off on a tint of the accent color.
private final class TryItView: NSView {
    private static let inset = NSSize(width: 10, height: 7)

    init(text: String) {
        super.init(frame: .zero)
        let label = TourPageView.makeLabel(
            TourPageView.leadIn("Try it:", to: text, color: .controlAccentColor),
            width: TourPageView.contentWidth - Self.inset.width * 2)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset.height),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset.height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset.width),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset.width),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}
