import Foundation
import AppKit
import ApplicationServices

/// REPL inspection helpers for printing state and window information.
extension AppController {
    func listZones() {
        print("\nCurrent zones:")
        for screenId in screenOrder {
            guard let context = screenContexts[screenId] else { continue }
            // Convert internal display ID to user-friendly index for display
            let screenIdentifier = String(screenContextStore.loggingIndex(for: screenId))
            print("  Screen \(context.descriptor.localizedName) [\(screenIdentifier)]:")
            for zone in context.zoneController.allZones {
                let windowInfo = zone.windowId.map { "window \($0)" } ?? "empty"
                print("    Zone \(zone.index): \(windowInfo), frame: \(zone.frame)")
            }
        }
        print("")
    }

    func printManagedWindows() {
        let windows = windowController.allWindows.sorted { $0.windowId < $1.windowId }
        print("\nManaged windows:")
        guard !windows.isEmpty else {
            print("  (none)")
            print("")
            return
        }

        for window in windows {
            let info = windowInfoJSON(windowId: window.windowId)
            let type = info["type"] as? String ?? "unknown"
            let zoneIndex = info["zone_index"] as? Int

            let screenId: CGDirectDisplayID? = {
                if let value = info["screen_display_id"] {
                    if let intValue = value as? Int {
                        return CGDirectDisplayID(intValue)
                    } else if let uintValue = value as? UInt32 {
                        return uintValue
                    }
                }
                return window.screenDisplayId
            }()

            let screenName = screenId.flatMap { descriptor(for: $0)?.localizedName } ?? "unknown screen"
            let pid = info["pid"] as? Int
            let appName = info["application_name"] as? String ?? "<unknown>"
            let bundleId = info["bundle_identifier"] as? String ?? "<unknown>"

            let zoneDescription: String
            if let zoneIndex, let screenId {
                zoneDescription = "zone \(zoneIndex) on \(screenName) [screen \(screenContextStore.loggingIndex(for: screenId))]"
            } else if let zoneIndex {
                zoneDescription = "zone \(zoneIndex)"
            } else {
                zoneDescription = "unassigned"
            }

            let pidDescription: String
            if let pid {
                pidDescription = "pid \(pid) (\(appName), \(bundleId))"
            } else {
                pidDescription = "(no pid)"
            }

            print("  Window \(window.windowId): \(type), \(pidDescription), \(zoneDescription)")
        }
        print("")
    }

    func relayout() {
        for context in screenContexts.values {
            context.zoneController.relayout()
        }
        syncWindowsToZones()
        print("Layouts recalculated")
    }

    func windowInfo(windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        let type: String
        if managed.isPlaceholder {
            type = "placeholder"
        } else {
            switch managed.backing {
            case .appKit:
                type = "test"
            case .accessibility:
                type = "external"
            }
        }

        let screenId = managed.screenDisplayId ?? detectScreenId(for: managed)
        let screenDescriptor = screenId.flatMap { (id: CGDirectDisplayID) -> ScreenDescriptor? in
            descriptor(for: id)
        }
        let actualFrame: CGRect
        if let screenDescriptor {
            actualFrame = windowController.actualFrameInScreenCoordinates(for: managed, on: screenDescriptor)
        } else if let fallback = windowController.actualFrameInScreenCoordinates(for: managed) {
            actualFrame = fallback
        } else {
            actualFrame = .zero
        }

        print("\nWindow \(windowId):")
        print("  Type: \(type)")

        var owningPid: pid_t?
        switch managed.backing {
        case .appKit:
            owningPid = getpid()
        case .accessibility(_, let pid, _):
            owningPid = pid
        }

        if let pid = owningPid {
            if let application = NSRunningApplication(processIdentifier: pid) ?? (pid == getpid() ? NSRunningApplication.current : nil) {
                let name = application.localizedName ?? "<unknown>"
                let bundle = application.bundleIdentifier ?? "<unknown>"
                print("  PID: \(pid) (\(name), \(bundle))")
            } else {
                print("  PID: \(pid)")
            }
        } else {
            print("  PID: unknown")
        }
        if let screenId, let screenDescriptor {
            let screenIdentifier = String(screenContextStore.loggingIndex(for: screenId))
            print("  Screen: \(screenDescriptor.localizedName) [\(screenIdentifier)]")
        } else {
            print("  Screen: unknown")
        }
        print("  Zone: \(managed.zoneIndex?.description ?? "none (minimized)")")
        print("  Actual frame: \(actualFrame)")

        if let key = zoneKey(forManagedWindow: managed),
           let context = screenContexts[key.screenId],
           let zone = context.zoneController.zone(at: key.index) {
            print("  Zone frame: \(zone.frame)")
        }
        print("")
    }

    func printFrames() {
        print("\nAll window frames:")
        for window in windowController.allWindows {
            let type: String
            if window.isPlaceholder {
                type = "placeholder"
            } else {
                switch window.backing {
                case .appKit:
                    type = "test"
                case .accessibility:
                    type = "external"
                }
            }
            let screenId = window.screenDisplayId ?? detectScreenId(for: window)
            let screenDescriptor = screenId.flatMap { (id: CGDirectDisplayID) -> ScreenDescriptor? in
                descriptor(for: id)
            }
            let actualFrame: CGRect
            if let screenDescriptor {
                actualFrame = windowController.actualFrameInScreenCoordinates(for: window, on: screenDescriptor)
            } else if let fallback = windowController.actualFrameInScreenCoordinates(for: window) {
                actualFrame = fallback
            } else {
                actualFrame = .zero
            }
            if let screenId, let screenDescriptor {
                let screenIdentifier = String(screenContextStore.loggingIndex(for: screenId))
                print("  Window \(window.windowId) (\(type)) on \(screenDescriptor.localizedName) [\(screenIdentifier)]: \(actualFrame)")
            } else {
                print("  Window \(window.windowId) (\(type)) on unknown screen: \(actualFrame)")
            }
        }
        print("")
    }

}
