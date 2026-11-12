/// The window that shows a tour: its pages, read front to back with Back and Continue. The Welcome tour
/// opens by itself on the first launch, and again after the restart that follows granting Accessibility
/// from its Permissions page; after that, tours open from the menu bar's Help menu. Like Preferences the
/// window floats, so the user can try things on the windows beside it.
import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class TourWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TourWindowController()

    /// Stable tag so other subsystems can recognize the tour's window (see `OwnContentWindows`) without
    /// forcing this singleton to instantiate.
    static let windowIdentifier = NSUserInterfaceItemIdentifier("ZonogyTour")

    private var tour = Tour.welcome
    private var pages: [TourPage] = []
    private var pageIndex = 0
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

    /// Opens the Welcome tour if this launch calls for it: the first launch, or the restart that follows
    /// granting Accessibility from the tour. Returns whether it opened.
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

    func show(_ tour: Tour, at page: Int = 0) {
        if tour == .welcome {
            TourProgressStore.hasBeenShown = true
        }
        guard let window else { return }
        self.tour = tour
        window.title = tour.windowTitle
        // Until Accessibility is granted there is nothing of Zonogy's to try, and a floating tour would
        // cover System Settings, where it is granted.
        window.level = AXIsProcessTrusted() ? .floating : .normal

        // The window keeps one size, that of its tallest page, so its buttons stay put from page to page.
        pages = tour.pages()
        pageContainerHeight.constant = pages.map { TourPageView(page: $0).fittingSize.height }.max() ?? 0
        showPage(max(0, min(page, pages.count - 1)))

        if !window.isVisible {
            window.layoutIfNeeded()
            window.center()
        }
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

        // Granting Accessibility restarts Zonogy. The Welcome tour then reopens on the page after this one.
        view.permissionBanners?.onAccessibilityGranted = { [tour] in
            if tour == .welcome {
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
        continueButton.isEnabled = !asksForAccessibility || AXIsProcessTrusted()
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

    // MARK: - NSWindowDelegate

    /// A closed tour keeps nothing running: no permission polling, no scene.
    func windowWillClose(_ notification: Notification) {
        removePage()
    }
}
