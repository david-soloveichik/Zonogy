import AppKit
import CoreServices
import Foundation

/// Watches for desktop icon changes so placeholder pass-through holes can be refreshed
/// promptly. A file-level FSEvents stream on the Desktop folder catches icons being added,
/// removed, or renamed, and — because Finder persists desktop icon positions to `.DS_Store`
/// at drag-drop time — icons being moved. Volume mounts (disk icons) arrive via workspace
/// notifications. Without these signals, an icon change with no accompanying click or focus
/// event would get its hole only at the next trigger, so the first click on it would hit
/// the placeholder instead of the icon.
///
/// If Desktop-folder access is denied, macOS withholds the file events; icon holes then
/// update on the other pass-through triggers instead.
final class DesktopChangeWatchService {
    private var isStarted = false
    private var stream: FSEventStreamRef?
    /// The watched Desktop path (standardized, no trailing slash) for event filtering.
    private var watchedDesktopPath: String?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pendingNotifyWorkItem: DispatchWorkItem?
    /// FSEvents delivery latency: desktop event volume is tiny, so favor promptness.
    private let streamLatencySeconds: CFTimeInterval = 0.25
    /// Waits out event bursts and gives Finder a moment to place the icon before holes are
    /// recomputed from the accessibility hierarchy.
    private let notifyDebounceSeconds: TimeInterval = 0.5
    /// One extra notification after the debounced one, in case Finder had not yet placed
    /// the new icon in its accessibility hierarchy when the first recompute ran.
    private let followUpNotifySeconds: TimeInterval = 1.0
    var changeHandler: (() -> Void)?

    func start() {
        guard !isStarted else { return }
        isStarted = true

        startStream()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleNotify()
            })
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        pendingNotifyWorkItem?.cancel()
        pendingNotifyWorkItem = nil
        tearDownStream()
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    /// External signal that the desktop icons likely changed (e.g. Finder relaunching and
    /// rebuilding its desktop hierarchy): runs the same debounced + follow-up notification
    /// path as a Desktop file event.
    func notifyDesktopChanged() {
        guard isStarted else { return }
        scheduleNotify()
    }

    private func startStream() {
        guard let desktopPath = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?
            .standardizedFileURL.resolvingSymlinksInPath().path else {
            return
        }
        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.streamCallback,
            &context,
            [desktopPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            streamLatencySeconds,
            flags
        ) else {
            Logger.debug("DesktopChangeWatchService: Failed to create FSEvents stream; icon holes will rely on the other pass-through triggers")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            Logger.debug("DesktopChangeWatchService: Failed to start FSEvents stream; icon holes will rely on the other pass-through triggers")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
        self.watchedDesktopPath = desktopPath
        Logger.debug("DesktopChangeWatchService: Watching \(desktopPath)")
    }

    private func tearDownStream() {
        watchedDesktopPath = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handleFSEvents(paths: [String], flagsList: [FSEventStreamEventFlags]) {
        guard isStarted else { return }

        // The watched root being renamed or replaced (e.g. a Desktop folder reconfiguration)
        // silently detaches the stream from the live directory; recreate it on the new path.
        if flagsList.contains(where: { $0 & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 }) {
            tearDownStream()
            startStream()
            scheduleNotify()
            return
        }

        guard let desktopPath = watchedDesktopPath else { return }
        for (path, flags) in zip(paths, flagsList)
        where Self.isIconRelevantEvent(path: path, flags: flags, desktopPath: desktopPath) {
            scheduleNotify()
            return
        }
    }

    /// Pure filter deciding whether one FSEvents (path, flags) pair can affect desktop icons.
    /// FSEvents watches the Desktop subtree recursively, but only three things matter here:
    /// the Desktop root's own `.DS_Store` (where Finder persists icon positions), entry
    /// changes among the Desktop's direct children (icons added/removed/renamed), and rescan
    /// requests (dropped events). Everything deeper — activity inside a project folder that
    /// lives on the Desktop, nested `.DS_Store` writes from browsing a folder in Finder,
    /// content saves of Desktop documents — cannot move an icon and is ignored.
    /// `desktopPath` must be standardized with no trailing slash.
    static func isIconRelevantEvent(path: String, flags: FSEventStreamEventFlags, desktopPath: String) -> Bool {
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
            return true
        }
        var normalizedPath = path
        while normalizedPath.count > 1 && normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        if normalizedPath == desktopPath + "/.DS_Store" {
            return true
        }
        let entryChangeFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated |
            kFSEventStreamEventFlagItemRemoved |
            kFSEventStreamEventFlagItemRenamed
        )
        guard (flags & entryChangeFlags) != 0 else {
            return false
        }
        return (normalizedPath as NSString).deletingLastPathComponent == desktopPath
    }

    private func scheduleNotify() {
        scheduleHandlerCall(after: notifyDebounceSeconds, thenFollowUp: true)
    }

    /// Runs the change handler after a delay through a single cancellable slot: new desktop
    /// events restart the debounce, cancelling whichever call (initial or follow-up) is pending.
    private func scheduleHandlerCall(after delay: TimeInterval, thenFollowUp: Bool) {
        pendingNotifyWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isStarted else { return }
            self.pendingNotifyWorkItem = nil
            self.changeHandler?()
            if thenFollowUp {
                self.scheduleHandlerCall(after: self.followUpNotifySeconds, thenFollowUp: false)
            }
        }
        pendingNotifyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private static let streamCallback: FSEventStreamCallback = { _, info, numEvents, eventPathsPointer, eventFlagsPointer, _ in
        guard let info else { return }
        let service = Unmanaged<DesktopChangeWatchService>.fromOpaque(info).takeUnretainedValue()
        let paths = (unsafeBitCast(eventPathsPointer, to: NSArray.self) as? [String]) ?? []
        let flagsList = (0..<numEvents).map { eventFlagsPointer[$0] }
        service.handleFSEvents(paths: paths, flagsList: flagsList)
    }
}
