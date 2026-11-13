/// Application entry point: runs guardrail tests or starts Zonogy's menu bar app.
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

Logger.debug("\(AppVersion.preferencesDisplayString) starting")

// Create the NSApplication
let app = NSApplication.shared

// Prevent the app from activating automatically
app.setActivationPolicy(.accessory)

// Initialize the AppController singleton
let appController = AppController.shared

// The first launch opens the tour's Welcome chapter, which covers granting permissions. On later launches,
// if Accessibility permissions are not granted, show Preferences (General tab)
if !TourWindowController.showAtLaunchIfNeeded(), !AXIsProcessTrusted() {
    Logger.debug("Accessibility permission not granted - showing Preferences")
    PreferencesWindowController.shared.showWindow()
}

// Run the AppKit run loop
app.run()
