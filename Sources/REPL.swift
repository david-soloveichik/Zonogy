import Foundation
import AppKit
import Dispatch

/// Command-line REPL for debugging
class REPL {
    private let appController: AppController
    private var stdinSource: DispatchSourceRead?

    init(appController: AppController) {
        self.appController = appController
    }

    func start() {
        printWelcome()
        setupStdinReader()
    }

    private func printWelcome() {
        print("=== LatticeTopology REPL ===")
        print("Type 'help' for available commands")
        print("")
    }

    private func setupStdinReader() {
        let stdinHandle = FileHandle.standardInput
        let stdinFd = stdinHandle.fileDescriptor

        stdinSource = DispatchSource.makeReadSource(fileDescriptor: stdinFd, queue: .main)

        stdinSource?.setEventHandler { [weak self] in
            guard let self = self else { return }

            let data = stdinHandle.availableData

            // EOF detected - stdin closed
            if data.isEmpty {
                print("EOF detected, exiting...")
                NSApplication.shared.terminate(nil)
                return
            }

            if let input = String(data: data, encoding: .utf8) {
                // Split by newlines and process each command
                let lines = input.components(separatedBy: .newlines)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        self.processCommand(trimmed)
                    }
                }
            }
        }

        stdinSource?.setCancelHandler {
            // Cleanup if needed
        }

        stdinSource?.resume()
    }

    private func processCommand(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let command = parts.first else { return }

        switch command {
        case "add-zone":
            appController.addZone()

        case "remove-zone":
            if parts.count < 2 {
                print("Usage: remove-zone <index>")
                return
            }
            guard let index = Int(parts[1]) else {
                print("Invalid index: \(parts[1])")
                return
            }
            appController.removeZone(at: index)

        case "resize-zone":
            guard parts.count == 2 else {
                print("Usage: resize-zone <index> <x> <y> <width> <height>")
                return
            }
            let args = parts[1].split(separator: " ").map(String.init)
            guard args.count == 5 else {
                print("Usage: resize-zone <index> <x> <y> <width> <height>")
                return
            }
            guard let index = Int(args[0]) else {
                print("Invalid index: \(args[0])")
                return
            }
            guard let x = Double(args[1]),
                  let y = Double(args[2]),
                  let width = Double(args[3]),
                  let height = Double(args[4]) else {
                print("Invalid frame values. Expected numeric x y width height.")
                return
            }
            let frame = CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
            appController.resizeZone(at: index, frame: frame)

        case "close-window":
            if parts.count < 2 {
                print("Usage: close-window <window_id>")
                return
            }
            guard let windowId = Int(parts[1]) else {
                print("Invalid window_id: \(parts[1])")
                return
            }
            appController.closeWindow(withId: windowId)

        case "minimize":
            if parts.count < 2 {
                print("Usage: minimize <window_id>")
                return
            }
            guard let windowId = Int(parts[1]) else {
                print("Invalid window_id: \(parts[1])")
                return
            }
            appController.minimizeWindow(withId: windowId)

        case "unminimize":
            if parts.count < 2 {
                print("Usage: unminimize <window_id>")
                return
            }
            guard let windowId = Int(parts[1]) else {
                print("Invalid window_id: \(parts[1])")
                return
            }
            appController.unminimizeWindow(withId: windowId)

        case "capture-frontmost":
            appController.captureFrontmostWindow()

        case "list":
            appController.listZones()

        case "layout":
            appController.relayout()

        case "window-info":
            if parts.count < 2 {
                print("Usage: window-info <window_id>")
                return
            }
            guard let windowId = Int(parts[1]) else {
                print("Invalid window_id: \(parts[1])")
                return
            }
            appController.windowInfo(windowId: windowId)

        case "frames":
            appController.printFrames()

        case "managed-windows":
            appController.printManagedWindows()

        case "validate-app":
            if parts.count < 2 {
                print("Usage: validate-app <pid>")
                return
            }
            guard let pidValue = Int32(parts[1]) else {
                print("Invalid pid: \(parts[1])")
                return
            }
            appController.validateApplication(pid: pidValue)

        case "test-layout":
            _ = ZoneLayoutTests.run()

        case "help":
            printHelp()

        case "quit", "exit":
            print("Exiting...")
            NSApplication.shared.terminate(nil)

        default:
            print("Unknown command: \(command). Type 'help' for available commands.")
        }
    }

    private func printHelp() {
        print("""

        Available commands:

        Zone management (current active screen):
          add-zone                     - Add a new zone (up to 3) on the active screen
          remove-zone <index>          - Remove the specified zone on the active screen
          resize-zone <index> <x> <y> <width> <height>
                                       - Resize an empty zone using screen-local coordinates
          list                         - Print current zones grouped by screen
          layout                       - Force a layout recalculation for all screens

        Window management:
          close-window <window_id>     - Close the specified window
          minimize <window_id>         - Minimize the specified window
          unminimize <window_id>       - Unminimize the specified window
          capture-frontmost            - Capture the currently focused window from the active app
          window-info <window_id>      - Show detailed info for a window
          frames                       - Show all window frames
          managed-windows              - List every tracked window with pid, assignment, and type
          validate-app <pid>           - Force-detect destroyed accessibility windows for the given pid
          test-layout                  - Run ZoneLayout frame assertions

        Other:
          help                         - Show this help message
          quit / exit                  - Exit the application

        """)
    }
}
