import Foundation
import AppKit
import ApplicationServices

// Enable line-buffered output so piped output streams in real-time
setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)

// Parse command-line arguments
let arguments = CommandLine.arguments
if arguments.contains("--self-test") {
    let allPassed = GuardrailTests.runAll()
    exit(allPassed ? 0 : 1)
}

// Always enable file logging for debugging
Logger.clearLogFile()
Logger.logToFile = true
Logger.debug("Zonogy starting - logging to \(Logger.logPath)")

// Create the NSApplication
let app = NSApplication.shared

// Prevent the app from activating automatically
app.setActivationPolicy(.accessory)

// Initialize the AppController singleton
let appController = AppController.shared

// If Accessibility permissions are not granted, show Preferences (General tab)
if !AXIsProcessTrusted() {
    Logger.debug("Accessibility permission not granted - showing Preferences")
    PreferencesWindowController.shared.showWindow()
}

// Run the AppKit run loop
app.run()
