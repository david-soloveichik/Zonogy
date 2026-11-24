/// The row along the top of the tour window: every chapter's name, with the current chapter's pages as dots
/// after it. A name opens its chapter at the first page, and a dot turns to its page, whose title it shows
/// when hovered. Chapters and pages that cannot be opened yet are dimmed.
import AppKit

final class TourChapterStrip: NSView {
    var onChooseChapter: ((TourChapter) -> Void)?
    var onChoosePage: ((Int) -> Void)?

    private let row = NSStackView()

    init() {
        super.init(frame: .zero)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows `chapter` open at `page`, one of the pages titled `pageTitles`.
    func show(
        _ chapter: TourChapter, pageTitles: [String], page: Int,
        canOpenChapter: (TourChapter) -> Bool, canOpenPage: (Int) -> Bool
    ) {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, each) in TourChapter.allCases.enumerated() {
            let isCurrent = each == chapter
            let name = NSButton(title: each.title, target: self, action: #selector(nameClicked(_:)))
            name.isBordered = false
            name.font = NSFont.systemFont(ofSize: 13, weight: isCurrent ? .semibold : .regular)
            name.contentTintColor = isCurrent ? .labelColor : .secondaryLabelColor
            name.tag = index
            name.isEnabled = canOpenChapter(each)
            guard isCurrent else {
                row.addArrangedSubview(name)
                continue
            }
            let dots = pageTitles.indices.map { makeDot(page: $0, title: pageTitles[$0], current: page, isEnabled: canOpenPage($0)) }
            let group = NSStackView(views: [name] + dots)
            group.alignment = .centerY
            group.spacing = 0
            group.setCustomSpacing(6, after: name)
            row.addArrangedSubview(group)
        }
    }

    /// A page's dot: filled up to the page showing, which takes the accent color.
    private func makeDot(page index: Int, title: String, current: Int, isEnabled: Bool) -> NSButton {
        let image = NSImage(systemSymbolName: index <= current ? "circle.fill" : "circle", accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .regular))!
        let dot = NSButton(image: image, target: self, action: #selector(dotClicked(_:)))
        dot.isBordered = false
        dot.contentTintColor = index == current ? .controlAccentColor : .secondaryLabelColor
        dot.toolTip = title
        dot.setAccessibilityLabel(title)  // in place of the "Button" title an image button gets
        dot.tag = index
        dot.isEnabled = isEnabled
        // Larger than the dot it draws, so it is easy to hit.
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 13),
            dot.heightAnchor.constraint(equalToConstant: 18),
        ])
        return dot
    }

    @objc private func nameClicked(_ sender: NSButton) {
        onChooseChapter?(TourChapter.allCases[sender.tag])
    }

    @objc private func dotClicked(_ sender: NSButton) {
        onChoosePage?(sender.tag)
    }
}
