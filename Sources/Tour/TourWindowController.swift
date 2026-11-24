/// The window that shows the tour: a strip of its chapters along the top, and the chosen chapter's pages, read
/// front to back with Back and Continue, which goes on into the next chapter. The Welcome chapter opens by
/// itself on the first launch, and again after the restart that follows granting Accessibility from its
/// Permissions page; after that, the menu bar's Help menu reopens the tour where it was left. The window floats,
/// above Zonogy's own panels too, so the user can try things on the windows beside it.
import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class TourWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TourWindowController()

    /// Stable tag so other subsystems can recognize the tour's window (see `OwnContentWindows`) without
    /// forcing this singleton to instantiate.
    static let windowIdentifier = NSUserInterfaceItemIdentifier("ZonogyTour")

    /// Just above Zonogy's panels (the Launcher, CmdTab, Dock menus, the WinShot chooser), which the user
    /// opens while following the tour.
    private static let floatingLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)

    private var chapter = TourChapter.welcome
    private var pages: [TourPage] = []
    private var pageIndex = 0
    /// Whether Accessibility was granted when the tour was last shown.
    private var isTrusted = false
    private var pageView: TourPageView?
    private let chapterStrip = TourChapterStrip()
    private let pageContainer = NSView()
    private var pageContainerHeight: NSLayoutConstraint!
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

        super.init(window: window)
        window.delegate = self
        setupContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupContent() {
        guard let contentView = window?.contentView else { return }

        chapterStrip.onChooseChapter = { [weak self] in self?.show($0) }
        chapterStrip.onChoosePage = { [weak self] in self?.showPage($0) }
        // Sets the strip apart from the page below it.
        let stripSeparator = NSBox()
        stripSeparator.boxType = .separator
        backButton = NSButton(title: "Back", target: self, action: #selector(goBack))
        backButton.bezelStyle = .rounded
        continueButton = NSButton(title: "Continue", target: self, action: #selector(goForward))
        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"

        for view in [chapterStrip, stripSeparator, pageContainer, backButton!, continueButton!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        pageContainerHeight = pageContainer.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            chapterStrip.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            chapterStrip.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            chapterStrip.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),

            stripSeparator.topAnchor.constraint(equalTo: chapterStrip.bottomAnchor, constant: 12),
            stripSeparator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stripSeparator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            pageContainer.topAnchor.constraint(equalTo: stripSeparator.bottomAnchor, constant: 20),
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
        // Until Accessibility is granted the tour does not float: it would cover System Settings, where it is
        // granted.
        isTrusted = AXIsProcessTrusted()
        window.level = isTrusted ? Self.floatingLevel : .normal

        if !window.isVisible {
            // While open, the window keeps one size, that of the tour's tallest page, so its buttons stay
            // put from page to page and from chapter to chapter.
            let allPages = TourChapter.allCases.flatMap { $0.pages() }
            pageContainerHeight.constant = allPages.map { TourPageView(page: $0).fittingSize.height }.max() ?? 0
            window.layoutIfNeeded()
            window.center()
        }

        self.chapter = chapter
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

        chapterStrip.show(
            chapter, pageTitles: pages.map(\.title), page: index,
            canOpenChapter: canOpenChapter, canOpenPage: canOpenPage)
        backButton.isEnabled = index > 0
        // A chapter's last page continues into the next chapter; only the tour's last page is Done.
        continueButton.title = isAtTourEnd ? "Done" : "Continue"
        continueButton.isEnabled = index < pages.count - 1
            ? canOpenPage(index + 1) : chapter.next.map(canOpenChapter) ?? true
    }

    private var isAtTourEnd: Bool {
        pageIndex == pages.count - 1 && chapter.next == nil
    }

    /// Until Accessibility is granted there is nothing of Zonogy's to try, so only the Welcome chapter opens.
    private func canOpenChapter(_ chapter: TourChapter) -> Bool {
        isTrusted || chapter == .welcome
    }

    /// The pages after one asking for Accessibility describe Zonogy at work, so they wait for it. Granting it
    /// restarts Zonogy, so what opens never changes while the tour shows.
    private func canOpenPage(_ index: Int) -> Bool {
        isTrusted || !pages[..<index].contains(where: \.asksForAccessibility)
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
        if pageIndex < pages.count - 1 {
            showPage(pageIndex + 1)
        } else if let next = chapter.next {
            show(next)
        } else {
            window?.close()
        }
    }

    /// The arrow keys turn the pages, and Command-W closes the tour. (Zonogy has no menu bar of its own
    /// to give its windows a Close command.)
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (Int(event.keyCode), modifiers) {
        case (kVK_LeftArrow, []) where backButton.isEnabled:
            goBack()
        case (kVK_RightArrow, []) where continueButton.isEnabled && !isAtTourEnd:
            goForward()
        case (kVK_ANSI_W, .command):
            window?.performClose(nil)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - NSWindowDelegate

    /// A closed tour keeps nothing running: no permission polling, no scene.
    func windowWillClose(_ notification: Notification) {
        removePage()
    }
}
