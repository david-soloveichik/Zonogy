import AppKit
import CoreGraphics

/// unrulywin — spawns windows that violate Zonogy's window-management criteria, for testing
/// how Zonogy behaves around unmanaged windows (e.g. placeholder click-through).
///
/// The binary has no app bundle, so Zonogy always rejects it at the application level
/// (no bundle identifier). Each mode additionally violates a specific window-level rule so
/// the tool stays useful if it is ever wrapped in a bundle.
///
/// Output is line-buffered and machine-parseable:
///   WINDOW <cgWindowId> FRAME <x> <y> <w> <h> MODE <mode> PID <pid>
///   CLICK <globalX> <globalY>
///   FOCUS <1|0>
/// All coordinates use global screen coordinates with y:0 at the primary screen's top-left
/// (same convention as Zonogy zone frames and CGWindow bounds).
///
/// Usage:
///   unrulywin spawn [--mode short|no-zoom|dialog|accessory] [--x N] [--y N]
///                   [--width N] [--height N] [--title T]
///   unrulywin click <x> <y>     # post a synthetic left click at global top-left coords
///   unrulywin list              # print on-screen windows front-to-back (z-order snapshot)

setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)

enum ViolationMode: String {
    /// Standard window in every way, but shorter than 250px (fails the height criterion).
    case short
    /// Non-resizable window with the zoom button removed (fails the zoom-button criterion).
    case noZoom = "no-zoom"
    /// Titled NSPanel (reports a non-standard subrole, fails the AXStandardWindow criterion).
    case dialog
    /// Standard window from an app with accessory activation policy (fails the app-level check).
    case accessory
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("unrulywin: " + message + "\n").utf8))
    exit(1)
}

/// y-flip between Cocoa global coordinates and top-left global coordinates,
/// anchored at the primary screen (NSScreen.screens[0], whose Cocoa origin is (0,0)).
func primaryScreenHeight() -> CGFloat {
    guard let primary = NSScreen.screens.first else {
        fail("no screens available")
    }
    return primary.frame.height
}

func topLeftToCocoa(_ rect: CGRect) -> CGRect {
    CGRect(x: rect.origin.x,
           y: primaryScreenHeight() - rect.origin.y - rect.height,
           width: rect.width,
           height: rect.height)
}

func cocoaToTopLeft(_ rect: CGRect) -> CGRect {
    CGRect(x: rect.origin.x,
           y: primaryScreenHeight() - rect.origin.y - rect.height,
           width: rect.width,
           height: rect.height)
}

func formatRect(_ rect: CGRect) -> String {
    "\(Int(rect.origin.x.rounded())) \(Int(rect.origin.y.rounded())) " +
    "\(Int(rect.width.rounded())) \(Int(rect.height.rounded()))"
}

// MARK: - click subcommand

func runClick(arguments: [String]) -> Never {
    var pressMicroseconds: useconds_t = 60_000
    var positional: [String] = []
    var index = 0
    while index < arguments.count {
        if arguments[index] == "--press" {
            index += 1
            guard index < arguments.count, let ms = Double(arguments[index]) else {
                fail("missing value for --press (milliseconds)")
            }
            pressMicroseconds = useconds_t(ms * 1000)
        } else {
            positional.append(arguments[index])
        }
        index += 1
    }
    guard positional.count == 2,
          let x = Double(positional[0]),
          let y = Double(positional[1]) else {
        fail("usage: unrulywin click <x> <y> [--press <ms>]")
    }
    // CGEvent coordinates already use the top-left global convention.
    let point = CGPoint(x: x, y: y)
    // Move the cursor first, like a physical click: the window server resolves click routing
    // (including pass-through over transparent window regions) against cursor tracking state.
    guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                             mouseCursorPosition: point, mouseButton: .left),
          let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                             mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                           mouseCursorPosition: point, mouseButton: .left) else {
        fail("could not create mouse events (accessibility permission missing?)")
    }
    move.post(tap: .cghidEventTap)
    usleep(120_000)
    down.post(tap: .cghidEventTap)
    usleep(pressMicroseconds)
    up.post(tap: .cghidEventTap)
    usleep(60_000)
    print("CLICKED \(Int(x)) \(Int(y))")
    exit(0)
}

// MARK: - list subcommand

/// Prints the same on-screen, desktop-excluded, front-to-back snapshot that Zonogy's
/// placeholder pass-through detection consumes. One line per window:
///   <index> id=<cgWindowId> pid=<pid> layer=<layer> alpha=<alpha> frame=<x,y,w,h> app=<owner>
func runList() -> Never {
    guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        fail("could not read window list")
    }
    for (index, info) in windowList.enumerated() {
        let windowNumber = (info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1
        let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? -1
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        let owner = (info[kCGWindowOwnerName as String] as? String) ?? "?"
        var frameText = "?"
        if let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
           let frame = CGRect(dictionaryRepresentation: boundsDict) {
            frameText = formatRect(frame).replacingOccurrences(of: " ", with: ",")
        }
        print("\(index) id=\(windowNumber) pid=\(pid) layer=\(layer) alpha=\(String(format: "%.2f", alpha)) frame=\(frameText) app=\(owner)")
    }
    exit(0)
}

// MARK: - spawn subcommand

/// Content view that reports clicks in global top-left coordinates.
final class ClickReportingView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window = window else { return }
        let windowPoint = event.locationInWindow
        let cocoaScreenRect = window.convertToScreen(CGRect(origin: windowPoint, size: .zero))
        let globalX = cocoaScreenRect.origin.x
        let globalY = primaryScreenHeight() - cocoaScreenRect.origin.y
        print("CLICK \(Int(globalX.rounded())) \(Int(globalY.rounded()))")
        super.mouseDown(with: event)
    }
}

final class SpawnDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let mode: ViolationMode
    let topLeftFrame: CGRect
    let title: String
    var window: NSWindow?

    init(mode: ViolationMode, topLeftFrame: CGRect, title: String) {
        self.mode = mode
        self.topLeftFrame = topLeftFrame
        self.title = title
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let cocoaFrame = topLeftToCocoa(topLeftFrame)

        let window: NSWindow
        switch mode {
        case .short, .accessory:
            window = NSWindow(
                contentRect: cocoaFrame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
        case .noZoom:
            window = NSWindow(
                contentRect: cocoaFrame,
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.standardWindowButton(.zoomButton)?.isHidden = true
        case .dialog:
            window = NSPanel(
                contentRect: cocoaFrame,
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
        }

        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self

        let contentView = ClickReportingView(frame: NSRect(origin: .zero, size: cocoaFrame.size))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor

        let label = NSTextField(labelWithString: "\(title)\nmode: \(mode.rawValue)  pid: \(getpid())")
        label.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
        label.textColor = .black
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.frame = NSRect(x: 0, y: cocoaFrame.height / 2 - 20, width: cocoaFrame.width, height: 40)
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        contentView.addSubview(label)

        window.contentView = contentView
        // setFrame after content assignment: contentRect describes the content area, but the
        // requested top-left frame should be the full window frame including the title bar.
        window.setFrame(cocoaFrame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
        printWindowLine()
    }

    func printWindowLine() {
        guard let window = window else { return }
        let topLeft = cocoaToTopLeft(window.frame)
        print("WINDOW \(window.windowNumber) FRAME \(formatRect(topLeft)) MODE \(mode.rawValue) PID \(getpid())")
    }

    func windowDidMove(_ notification: Notification) { printWindowLine() }
    func windowDidResize(_ notification: Notification) { printWindowLine() }
    func windowDidBecomeKey(_ notification: Notification) { print("FOCUS 1") }
    func windowDidResignKey(_ notification: Notification) { print("FOCUS 0") }
    func windowWillClose(_ notification: Notification) {
        print("CLOSED")
        exit(0)
    }
}

func runSpawn(arguments: [String]) -> Never {
    var mode = ViolationMode.short
    var x: CGFloat = 200
    var y: CGFloat = 200
    var width: CGFloat = 400
    var height: CGFloat?
    var title = "unrulywin"

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        func value() -> String {
            index += 1
            guard index < arguments.count else {
                fail("missing value for \(argument)")
            }
            return arguments[index]
        }
        switch argument {
        case "--mode":
            guard let parsed = ViolationMode(rawValue: value()) else {
                fail("unknown mode (expected short|no-zoom|dialog|accessory)")
            }
            mode = parsed
        case "--x": x = CGFloat(Double(value()) ?? 200)
        case "--y": y = CGFloat(Double(value()) ?? 200)
        case "--width": width = CGFloat(Double(value()) ?? 400)
        case "--height": height = CGFloat(Double(value()) ?? 0)
        case "--title": title = value()
        default:
            fail("unknown argument: \(argument)")
        }
        index += 1
    }

    // The short mode's whole point is a sub-250px window; everything else defaults tall
    // enough to pass the height criterion so only its own violation applies.
    let resolvedHeight = height ?? (mode == .short ? 200 : 400)
    if mode == .short && resolvedHeight >= 250 {
        FileHandle.standardError.write(Data("unrulywin: warning: mode short with height >= 250 will not violate the height rule\n".utf8))
    }

    let app = NSApplication.shared
    app.setActivationPolicy(mode == .accessory ? .accessory : .regular)

    let delegate = SpawnDelegate(
        mode: mode,
        topLeftFrame: CGRect(x: x, y: y, width: width, height: resolvedHeight),
        title: title
    )
    app.delegate = delegate
    app.run()
    exit(0)
}

// MARK: - entry

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "click":
    runClick(arguments: Array(arguments.dropFirst()))
case "list":
    runList()
case "spawn":
    runSpawn(arguments: Array(arguments.dropFirst()))
case .none, "--help", "-h", "help":
    print("""
    unrulywin — spawn windows that violate Zonogy's management rules, or post test clicks.

    Usage:
      unrulywin spawn [--mode short|no-zoom|dialog|accessory] [--x N] [--y N]
                      [--width N] [--height N] [--title T]
      unrulywin click <x> <y>
      unrulywin list

    Coordinates are global screen coordinates with y:0 at the primary screen's top-left.
    Emits machine-parseable lines: WINDOW/CLICK/FOCUS/CLOSED.
    """)
    exit(arguments.first == nil ? 1 : 0)
default:
    fail("unknown subcommand '\(arguments[0])' (expected spawn|click)")
}
