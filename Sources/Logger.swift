import Foundation

/// Simple logging utility for debugging
enum Logger {
    static var logToFile = false
    static let logPath = "/tmp/lattice-topology-debug.log"

    static func debug(_ message: String) {
        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let logMessage = "[\(formatter.string(from: timestamp))] \(message)\n"

        // Always print to stdout
        print("[\(formatter.string(from: timestamp))] \(message)")

        // Also write to file if enabled
        if logToFile {
            if let data = logMessage.data(using: .utf8),
               let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                // Create file if it doesn't exist
                try? logMessage.write(toFile: logPath, atomically: true, encoding: .utf8)
            }
        }
    }
}
