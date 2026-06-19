/// Watches standard application install directories and triggers debounced launcher cache reloads.

import AppKit
import CoreServices
import Foundation
import OSLog

final class LauncherInstallWatchService {
    private let streamQueue = DispatchQueue(label: "com.zonogy.launcher.install-watch")
    private var stream: FSEventStreamRef?
    private var watchedRootPaths: [String] = []
    private var pendingReloadWorkItem: DispatchWorkItem?
    // Coalesced FS-event stats for the in-flight debounce window, logged once when the reload fires
    // so large directory copies don't flood the debug log with per-batch chatter.
    private var pendingBatchCount = 0
    private var pendingEventCount = 0
    private var pendingFlagLabels: Set<String> = []
    private var pendingSamplePath: String?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isStarted = false
    var reloadHandler: (() -> Void)?

    private let streamLatencySeconds: CFTimeInterval = 3.0
    private let reloadDebounceSeconds: TimeInterval = 2.0

    func start() {
        guard !isStarted else { return }
        isStarted = true

        installWorkspaceObservers()
        refreshWatchedRoots(reason: "startup")

        Logger.debug("LauncherInstallWatchService: Started")
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        pendingReloadWorkItem?.cancel()
        pendingReloadWorkItem = nil
        resetPendingBatchStats()
        removeWorkspaceObservers()
        tearDownStream()

        Logger.debug("LauncherInstallWatchService: Stopped")
    }

    private func installWorkspaceObservers() {
        guard workspaceObservers.isEmpty else { return }

        let center = NSWorkspace.shared.notificationCenter
        let didMount = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            self.handleVolumeTopologyChange(kind: "mounted", notification: notification)
        }
        let didUnmount = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            self.handleVolumeTopologyChange(kind: "unmounted", notification: notification)
        }

        workspaceObservers = [didMount, didUnmount]
    }

    private func removeWorkspaceObservers() {
        guard !workspaceObservers.isEmpty else { return }

        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    private func handleVolumeTopologyChange(kind: String, notification: Notification) {
        guard isStarted else { return }

        let volumePath = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path ?? "<unknown>"
        Logger.debug("LauncherInstallWatchService: Volume \(kind) at \(volumePath)")

        refreshWatchedRoots(reason: "volume-\(kind)")
        scheduleDebouncedReload(reason: "volume-\(kind)")
    }

    private func refreshWatchedRoots(reason: String) {
        let rootPaths = resolvedExistingWatchRoots()
        guard rootPaths != watchedRootPaths || stream == nil else { return }
        configureStream(for: rootPaths, reason: reason)
    }

    private func resolvedExistingWatchRoots() -> [String] {
        let fileManager = FileManager.default
        var paths: Set<String> = []

        for root in DefaultAppProvider.standardApplicationRoots(fileManager: fileManager) {
            let resolvedPath = root.standardizedFileURL.resolvingSymlinksInPath().path
            guard fileManager.fileExists(atPath: resolvedPath) else { continue }
            paths.insert(resolvedPath)
        }

        return paths.sorted()
    }

    private func configureStream(for rootPaths: [String], reason: String) {
        tearDownStream()

        guard !rootPaths.isEmpty else {
            Logger.debug("LauncherInstallWatchService: No app roots available to watch (\(reason))")
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let streamFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.streamCallback,
            &context,
            rootPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            streamLatencySeconds,
            streamFlags
        ) else {
            Logger.debug("LauncherInstallWatchService: Failed to create FSEvents stream")
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, streamQueue)

        guard FSEventStreamStart(stream) else {
            Logger.debug("LauncherInstallWatchService: Failed to start FSEvents stream")
            tearDownStream()
            return
        }

        watchedRootPaths = rootPaths
        Logger.debug("LauncherInstallWatchService: Watching \(rootPaths.count) app root(s) (\(reason)): \(rootPaths.joined(separator: ", "))")
    }

    private func tearDownStream() {
        guard let stream else {
            watchedRootPaths = []
            return
        }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        watchedRootPaths = []
    }

    private func handleFSEventBatch(
        eventCount: Int,
        samplePath: String,
        rootChanged: Bool,
        mustScanSubdirs: Bool,
        droppedEvents: Bool
    ) {
        guard isStarted else { return }

        var flagLabels: [String] = []
        if rootChanged { flagLabels.append("root-changed") }
        if mustScanSubdirs { flagLabels.append("must-scan-subdirs") }
        if droppedEvents { flagLabels.append("events-dropped") }
        let flagSummary = flagLabels.isEmpty ? "none" : flagLabels.joined(separator: ",")

        // Coalesce per-batch details; they are logged once when the debounced reload fires.
        pendingBatchCount += 1
        pendingEventCount += eventCount
        pendingFlagLabels.formUnion(flagLabels)
        pendingSamplePath = samplePath

        ZonogySignposts.pointsOfInterest.emitEvent(
            "LauncherInstallWatchFSEvents",
            "count=\(eventCount) flags=\(flagSummary, privacy: .public)"
        )

        if rootChanged || droppedEvents {
            refreshWatchedRoots(reason: "fsevents-\(flagSummary)")
        }
        scheduleDebouncedReload(reason: "fsevents")
    }

    private func scheduleDebouncedReload(reason: String) {
        pendingReloadWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isStarted else { return }
            let signpostState = ZonogySignposts.pointsOfInterest.beginInterval(
                "LauncherInstallWatchReload",
                "reason=\(reason, privacy: .public)"
            )
            defer {
                ZonogySignposts.pointsOfInterest.endInterval("LauncherInstallWatchReload", signpostState)
            }
            self.logCoalescedReload(reason: reason)
            self.resetPendingBatchStats()
            if let reloadHandler = self.reloadHandler {
                reloadHandler()
            } else {
                Task {
                    await LauncherAppCache.shared.reload()
                }
            }
        }
        pendingReloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + reloadDebounceSeconds, execute: workItem)
    }

    private func logCoalescedReload(reason: String) {
        guard pendingBatchCount > 0 else {
            Logger.debug("LauncherInstallWatchService: Debounced reload triggered (\(reason))")
            return
        }

        let flagSummary = pendingFlagLabels.isEmpty ? "none" : pendingFlagLabels.sorted().joined(separator: ",")
        let sample = pendingSamplePath ?? "<unknown>"
        Logger.debug(
            "LauncherInstallWatchService: Debounced reload (\(reason)) after \(pendingBatchCount) fs batch(es), "
                + "\(pendingEventCount) event(s), flags=\(flagSummary), sample=\(sample)"
        )
    }

    private func resetPendingBatchStats() {
        pendingBatchCount = 0
        pendingEventCount = 0
        pendingFlagLabels.removeAll()
        pendingSamplePath = nil
    }

    private static let streamCallback: FSEventStreamCallback = { _, info, numEvents, eventPathsPointer, eventFlagsPointer, _ in
        guard let info else { return }
        let service = Unmanaged<LauncherInstallWatchService>.fromOpaque(info).takeUnretainedValue()

        let eventPaths = unsafeBitCast(eventPathsPointer, to: NSArray.self)
        let samplePath = eventPaths.firstObject as? String ?? "<unknown>"

        var rootChanged = false
        var mustScanSubdirs = false
        var droppedEvents = false
        for index in 0..<numEvents {
            let flags = eventFlagsPointer[index]
            if (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)) != 0 {
                rootChanged = true
            }
            if (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)) != 0 {
                mustScanSubdirs = true
            }
            if (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)) != 0 ||
                (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)) != 0 {
                droppedEvents = true
            }
        }

        DispatchQueue.main.async {
            service.handleFSEventBatch(
                eventCount: numEvents,
                samplePath: samplePath,
                rootChanged: rootChanged,
                mustScanSubdirs: mustScanSubdirs,
                droppedEvents: droppedEvents
            )
        }
    }
}
