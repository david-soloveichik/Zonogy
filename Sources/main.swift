import Foundation
import AppKit
import Darwin

// Enable line-buffered output so piped output (e.g., `swift run | grep`) streams in real-time
// This avoid having to use stdbuf -oL -eL swift run ...
setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)

// Maintain strong references so background callbacks remain valid.
private var activeSocketServer: SocketServer?
private var activeREPL: REPL?

// Parse command-line arguments
let arguments = CommandLine.arguments
let useSocket = arguments.contains("--socket")
let socketPath = arguments.first(where: { $0.hasPrefix("--socket-path=") })
    .map { String($0.dropFirst("--socket-path=".count)) }
    ?? "/tmp/zonogy.sock"

if arguments.contains("--self-test") {
    let allPassed = GuardrailTests.runAll()
    exit(allPassed ? 0 : 1)
}

// Always enable file logging for debugging
Logger.clearLogFile()   // Empty out the log file for a new session
Logger.logToFile = true
Logger.debug("Zonogy starting - logging to \(Logger.logPath)")

// Create the NSApplication
let app = NSApplication.shared

// Prevent the app from activating automatically
app.setActivationPolicy(.accessory)

// Initialize the AppController singleton
let appController = AppController.shared

if useSocket {
    Logger.debug("Starting socket server mode")

    // Start socket server mode
    let socketServer = SocketServer(socketPath: socketPath, appController: appController)
    socketServer.start()
    activeSocketServer = socketServer
    Logger.debug("Zonogy started in socket mode on \(socketPath)")

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
    Logger.debug("Zonogy started in REPL mode")
}

// Run the AppKit run loop
app.run()
