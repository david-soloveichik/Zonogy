/// Tracks windows the user just explicitly minimized so CmdTab's initial selection can skip them.

import AppKit

/// Pure mark bookkeeping (guardrail-tested). A window stays marked for the settle delay after
/// its minimize, and additionally for as long as the modifier keys held during its own minimize
/// remain held (its "dismissal gesture", e.g. Cmd staying down from Cmd-M through Cmd-Tab).
/// Gesture lifetimes are independent per window.
struct RecentUserMinimizeMarks {
    private var markTimesByWindowId: [Int: Date] = [:]
    private var gestureModifiersByWindowId: [Int: NSEvent.ModifierFlags] = [:]

    var hasActiveGesture: Bool { !gestureModifiersByWindowId.isEmpty }
    var gestureWindowIds: Set<Int> { Set(gestureModifiersByWindowId.keys) }

    /// The gesture mask is captured once, at the first record of a dismissal. A re-record of a
    /// still-marked window (Zonogy-shortcut minimizes record at issue time and again from the
    /// delayed miniaturize notification) refreshes only the timestamp, so a gesture that ended
    /// in between — or narrowed to the modifiers still held — is not resurrected or redefined.
    mutating func recordMinimize(windowId: Int, heldModifiers: NSEvent.ModifierFlags, now: Date) {
        let isNewMark = markTimesByWindowId[windowId] == nil
        markTimesByWindowId[windowId] = now
        if isNewMark, !heldModifiers.isEmpty {
            gestureModifiersByWindowId[windowId] = heldModifiers
        }
    }

    /// Drops every gesture whose own required modifiers are no longer all held.
    mutating func modifiersChanged(to heldModifiers: NSEvent.ModifierFlags) {
        gestureModifiersByWindowId = gestureModifiersByWindowId.filter { _, required in
            heldModifiers.contains(required)
        }
    }

    mutating func clearMark(windowId: Int) {
        markTimesByWindowId.removeValue(forKey: windowId)
        gestureModifiersByWindowId.removeValue(forKey: windowId)
    }

    mutating func removeAll() {
        markTimesByWindowId = [:]
        gestureModifiersByWindowId = [:]
    }

    /// Windows CmdTab's initial selection should skip right now: every window minimized within
    /// the settle delay, plus every window whose dismissal gesture is still held. Expired
    /// non-gesture marks are pruned as a side effect.
    mutating func activeSkipWindowIds(now: Date, settleDelay: TimeInterval) -> Set<Int> {
        markTimesByWindowId = markTimesByWindowId.filter { _, time in
            now.timeIntervalSince(time) <= settleDelay
        }
        return Set(markTimesByWindowId.keys).union(gestureWindowIds)
    }
}

/// Feeds `RecentUserMinimizeMarks` from live input state: captures the modifiers held at each
/// user minimize and watches for their release with global+local flagsChanged monitors
/// (mirroring `WinShotModifierMonitor`). Main-thread only.
final class RecentUserMinimizeTracker {
    private static let relevantModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    private var marks = RecentUserMinimizeMarks()
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func recordUserMinimize(windowId: Int) {
        let held = NSEvent.modifierFlags.intersection(Self.relevantModifiers)
        marks.recordMinimize(windowId: windowId, heldModifiers: held, now: Date())
        if marks.hasActiveGesture {
            startMonitorIfNeeded()
        }
    }

    /// The window is no longer minimized (restored, adopted, or destroyed); stop skipping it.
    func clearMark(windowId: Int) {
        marks.clearMark(windowId: windowId)
        stopMonitorIfGestureOver()
    }

    /// Stop skipping everything: the user completed an explicit window selection (CmdTab,
    /// Launcher, zone navigation) and has moved on, or the state is stale (sleep, screen lock).
    func clearAllMarks() {
        marks.removeAll()
        stopMonitorIfGestureOver()
    }

    func activeSkipWindowIds(settleDelay: TimeInterval) -> Set<Int> {
        // Self-heal releases the monitors can miss (sleep, screen lock, secure input): prune
        // gestures against the modifiers actually held right now.
        marks.modifiersChanged(to: NSEvent.modifierFlags.intersection(Self.relevantModifiers))
        stopMonitorIfGestureOver()
        return marks.activeSkipWindowIds(now: Date(), settleDelay: settleDelay)
    }

    private func startMonitorIfNeeded() {
        guard globalMonitor == nil && localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        marks.modifiersChanged(to: event.modifierFlags.intersection(Self.relevantModifiers))
        stopMonitorIfGestureOver()
    }

    private func stopMonitorIfGestureOver() {
        guard !marks.hasActiveGesture else { return }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    deinit {
        marks.removeAll()
        stopMonitorIfGestureOver()
    }
}
