/// Plays one of the tour's scenes: an animated SVG from Resources/Tour, drawn by scripts/tour-*.py, with its
/// keycaps showing the current shortcuts (see TourKeycaps). A scene animates with CSS keyframes, which takes
/// a web view to play. It is only a picture: scripting is off, and the view takes no clicks or scrolling.
import AppKit
import WebKit

final class TourSceneView: NSView, WKNavigationDelegate {
    /// The scenes' stage color, shown until a scene has drawn.
    private static let stageColor = NSColor(srgbRed: 0x0e / 255.0, green: 0x12 / 255.0, blue: 0x21 / 255.0, alpha: 1)

    /// The scene's file, or nil if it is missing.
    private let path: String?
    private var webView: WKWebView?

    /// `scene` names a file in Resources/Tour, without its extension.
    init(scene: String) {
        path = BundledResource.path("Tour/\(scene).svg")
        super.init(frame: .zero)
        if path == nil {
            Logger.error("Tour scene \(scene) is missing")
        }
        wantsLayer = true
        layer?.backgroundColor = Self.stageColor.cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        heightAnchor.constraint(equalTo: widthAnchor, multiplier: 1 / Self.aspectRatio(ofSceneAt: path)).isActive = true
    }

    /// Width over height of a scene, from the `viewBox` its file opens with.
    private static func aspectRatio(ofSceneAt path: String?) -> CGFloat {
        guard let path, let file = FileHandle(forReadingAtPath: path),
              let opening = String(data: file.readData(ofLength: 300), encoding: .utf8),
              let box = opening.components(separatedBy: "viewBox=\"").dropFirst().first else {
            return 1.5
        }
        let numbers = box.prefix { $0 != "\"" }.split(separator: " ").compactMap { Double($0) }
        guard numbers.count == 4, numbers[3] > 0 else {
            return 1.5
        }
        return numbers[2] / numbers[3]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The web view is made once the scene is on screen, so a page that is only being measured costs none.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, webView == nil, let path,
              let scene = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = PictureWebView(frame: bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.underPageBackgroundColor = Self.stageColor
        webView.alphaValue = 0  // A web view is white until its page has drawn.
        webView.navigationDelegate = self
        addSubview(webView)
        self.webView = webView

        webView.load(
            Data(TourKeycaps.fill(scene).utf8), mimeType: "image/svg+xml", characterEncodingName: "UTF-8",
            baseURL: URL(fileURLWithPath: path))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            webView.animator().alphaValue = 1
        }
    }
}

/// A web view that only shows its page: the mouse passes through it, and it takes no keys (as first
/// responder it would keep the arrow keys from turning the tour's pages).
private final class PictureWebView: WKWebView {
    override var acceptsFirstResponder: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
