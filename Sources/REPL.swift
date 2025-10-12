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

        case "create-window":
            appController.createWindow()

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

        Zone management:
          add-zone                     - Add a new zone (up to 3)
          remove-zone <index>          - Remove the specified zone
          list                         - Print current zones and their windows
          layout                       - Force a layout recalculation

        Window management:
          create-window                - Create a new test window
          close-window <window_id>     - Close the specified window
          minimize <window_id>         - Minimize the specified window
          unminimize <window_id>       - Unminimize the specified window
          window-info <window_id>      - Show detailed info for a window
          frames                       - Show all window frames
          test-layout                  - Run ZoneLayout frame assertions

        Other:
          help                         - Show this help message
          quit / exit                  - Exit the application

        """)
    }
}
