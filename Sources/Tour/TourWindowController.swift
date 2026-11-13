/// The window that shows the tour: its chapters in the toolbar, and the chosen chapter's pages, read front to
/// back with Back and Continue. The Welcome chapter opens by itself on the first launch, and again after the
/// restart that follows granting Accessibility from its Permissions page; after that, the menu bar's Help
/// menu reopens the tour where it was left. Like Preferences the window floats, so the user can try things
/// on the windows beside it.
import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class TourWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation {
    static let shared = TourWindowController()

    /// Stable tag so other subsystems can recognize the tour's window (see `OwnContentWindows`) without
    /// forcing this singleton to instantiate.
    static let windowIdentifier = NSUserInterfaceItemIdentifier("ZonogyTour")

    /// The toolbar's items, one per chapter, each named by its chapter's raw value.
    private static let chapterItemIdentifiers = TourChapter.allCases.map { NSToolbarItem.Identifier($0.rawValue) }

    private var chapter = TourChapter.welcome
    private var pages: [TourPage] = []
    private var pageIndex = 0
    /// Whether Accessibility was granted when the tour was last shown.
    private var isTrusted = false
    private var pageView: TourPageView?
    private let pageContainer = NSView()
    private var pageContainerHeight: NSLayoutConstraint!
    private let positionLabel = NSTextField(labelWithString: "")
    private var backButton: NSButton!
    private var continueButton: NSButton!

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Zonogy Tour"
        window.identifier = Self.windowIdentifier
        window.isReleasedWhenClosed = false
        // The tour is often in the way of what it describes, so any part of it drags it aside.
        window.isMovableByWindowBackground = true
        window.toolbarStyle = .preference

        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "ZonogyTour")
        toolbar.delegate = self
        window.toolbar = toolbar
        setupContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupContent() {
        guard let contentView = window?.contentView else { return }

        positionLabel.font = NSFont.systemFont(ofSize: 12)
        positionLabel.textColor = .secondaryLabelColor
        backButton = NSButton(title: "Back", target: self, action: #selector(goBack))
        backButton.bezelStyle = .rounded
        continueButton = NSButton(title: "Continue", target: self, action: #selector(goForward))
        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"

        for view in [pageContainer, positionLabel, backButton!, continueButton!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        pageContainerHeight = pageContainer.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            pageContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            pageContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            pageContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            pageContainer.widthAnchor.constraint(equalToConstant: TourPageView.contentWidth),
            pageContainerHeight,

            continueButton.topAnchor.constraint(equalTo: pageContainer.bottomAnchor, constant: 16),
            continueButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            continueButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            continueButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),

            backButton.trailingAnchor.constraint(equalTo: continueButton.leadingAnchor, constant: -8),
            backButton.centerYAnchor.constraint(equalTo: continueButton.centerYAnchor),
            backButton.widthAnchor.constraint(equalTo: continueButton.widthAnchor),

            positionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            positionLabel.centerYAnchor.constraint(equalTo: continueButton.centerYAnchor),
        ])
    }

    // MARK: - Showing

    /// Opens the Welcome chapter if this launch calls for it: the first launch, or the restart that
    /// follows granting Accessibility from the tour. Returns whether it opened.
    static func showAtLaunchIfNeeded() -> Bool {
        if let page = TourProgressStore.takeResumePage() {
            shared.show(.welcome, at: page)
            return true
        }
        guard !TourProgressStore.hasBeenShown else {
            return false
        }
        shared.show(.welcome)
        return true
    }

    /// Opens the tour where it was left: at the page last shown, or at the start of the Welcome chapter.
    func show() {
        show(chapter, at: pageIndex)
    }

    func show(_ chapter: TourChapter, at page: Int = 0) {
        TourProgressStore.hasBeenShown = true
        guard let window else { return }
        // Until Accessibility is granted there is nothing of Zonogy's to try, so the toolbar offers only the
        // Welcome chapter, and the tour does not float: it would cover System Settings, where it is granted.
        isTrusted = AXIsProcessTrusted()
        window.level = isTrusted ? .floating : .normal

        if !window.isVisible {
            // While open, the window keeps one size, that of the tour's tallest page, so its buttons stay
            // put from page to page and from chapter to chapter.
            let allPages = TourChapter.allCases.flatMap { $0.pages() }
            pageContainerHeight.constant = allPages.map { TourPageView(page: $0).fittingSize.height }.max() ?? 0
            window.layoutIfNeeded()
            window.center()
        }

        self.chapter = chapter
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(chapter.rawValue)
        pages = chapter.pages()
        showPage(max(0, min(page, pages.count - 1)))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func showPage(_ index: Int) {
        removePage()
        pageIndex = index

        let view = TourPageView(page: pages[index])
        view.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
        ])
        pageView = view
        // Keys go to the window, and so to `keyDown` below, not to a control on the page.
        window?.makeFirstResponder(nil)

        // Granting Accessibility restarts Zonogy. The Welcome chapter then reopens on the page after this one.
        view.permissionBanners?.onAccessibilityGranted = { [chapter] in
            if chapter == .welcome {
                TourProgressStore.saveResumePage(index + 1)
            }
            AppController.shared.restartAfterAccessibilityGranted()
        }
        view.permissionBanners?.startPolling()

        let isLast = index == pages.count - 1
        positionLabel.stringValue = "\(index + 1) of \(pages.count)"
        backButton.isEnabled = index > 0
        continueButton.title = isLast ? "Done" : "Continue"
        // The pages after the one asking for Accessibility describe Zonogy at work, so they wait for it.
        // Granting it restarts Zonogy on the next page, so the button never needs enabling while this
        // page shows.
        let asksForAccessibility = view.permissionBanners?.permissions.contains(.accessibility) ?? false
        continueButton.isEnabled = !asksForAccessibility || isTrusted
    }

    private func removePage() {
        pageView?.permissionBanners?.stopPolling()
        pageView?.removeFromSuperview()
        pageView = nil
    }

    @objc private func goBack() {
        showPage(pageIndex - 1)
    }

    @objc private func goForward() {
        if pageIndex == pages.count - 1 {
            window?.close()
        } else {
            showPage(pageIndex + 1)
        }
    }

    /// The arrow keys turn the pages, and Command-W closes the tour. (Zonogy has no menu bar of its own
    /// to give its windows a Close command.)
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (Int(event.keyCode), modifiers) {
        case (kVK_LeftArrow, []) where backButton.isEnabled:
            goBack()
        case (kVK_RightArrow, []) where continueButton.isEnabled && pageIndex < pages.count - 1:
            goForward()
        case (kVK_ANSI_W, .command):
            window?.performClose(nil)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.chapterItemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.chapterItemIdentifiers
    }

    /// The chapter showing is the selected item.
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.chapterItemIdentifiers
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let chapter = TourChapter(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = chapter.title
        item.image = NSImage(systemSymbolName: chapter.symbolName, accessibilityDescription: nil)
        item.target = self
        item.action = #selector(chooseChapter(_:))
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        isTrusted || item.itemIdentifier.rawValue == TourChapter.welcome.rawValue
    }

    /// A chapter opens at its first page.
    @objc private func chooseChapter(_ item: NSToolbarItem) {
        TourChapter(rawValue: item.itemIdentifier.rawValue).map { show($0) }
    }

    // MARK: - NSWindowDelegate

    /// A closed tour keeps nothing running: no permission polling, no scene.
    func windowWillClose(_ notification: Notification) {
        removePage()
    }
}
