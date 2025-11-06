import Foundation
import AppKit

// Maintain strong references so background callbacks remain valid.
private var activeSocketServer: SocketServer?
private var activeREPL: REPL?

// Parse command-line arguments
let arguments = CommandLine.arguments
let useSocket = arguments.contains("--socket")
let socketPath = arguments.first(where: { $0.hasPrefix("--socket-path=") })
    .map { String($0.dropFirst("--socket-path=".count)) }
    ?? "/tmp/lattice-topology.sock"

if arguments.contains("--self-test") {
    let allPassed = GuardrailTests.runAll()
    exit(allPassed ? 0 : 1)
}

// Create the NSApplication
let app = NSApplication.shared

// Prevent the app from activating automatically
app.setActivationPolicy(.accessory)

// Initialize the AppController singleton
let appController = AppController.shared

// Always enable file logging for debugging sleep/wake issues
Logger.logToFile = true
Logger.debug("LatticeTopology starting - logging to \(Logger.logPath)")

if useSocket {
    Logger.debug("Starting socket server mode")

    // Start socket server mode
    let socketServer = SocketServer(socketPath: socketPath, appController: appController)
    socketServer.start()
    activeSocketServer = socketServer
    Logger.debug("LatticeTopology started in socket mode on \(socketPath)")

    // Clean up socket on exit
    atexit {
        activeSocketServer?.stop()
        activeSocketServer = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }
} else {
    // Start REPL mode (default)
    let repl = REPL(appController: appController)
    repl.start()
    activeREPL = repl
    Logger.debug("LatticeTopology started in REPL mode")
}

// Run the AppKit run loop
app.run()
