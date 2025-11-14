import Foundation

/// Simple logging utility for debugging
enum Logger {
    static var logToFile = false
    static let logPath = "/tmp/zonogy-debug.log"
    private static let timeTravelLogFilename = "time_travel_log.txt"
    private static let bufferRetentionWindow: TimeInterval = 10
    private static let bufferQueue = DispatchQueue(label: "com.zonogy.logger.buffer", qos: .utility)
    private static var recentEntries: [LogEntry] = []

    static func debug(_ message: String) {
        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let formattedTimestamp = formatter.string(from: timestamp)
        let logLine = "[\(formattedTimestamp)] \(message)"
        let logMessage = "\(logLine)\n"

        recordForTimeTravel(line: logLine, timestamp: timestamp)

        // Always print to stdout
        print(logLine)

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

    @discardableResult
    static func dumpRecentLogs(
        destinationURL: URL? = nil,
        captureTimestamp: Date = Date()
    ) -> Bool {
        let window = bufferRetentionWindow
        let cutoff = captureTimestamp.addingTimeInterval(-window)
        let entries = bufferQueue.sync {
            recentEntries.filter { entry in
                entry.timestamp >= cutoff && entry.timestamp <= captureTimestamp
            }
        }

        var lines: [String] = []
        if entries.isEmpty {
            let windowDescription = String(format: "%.1f", window)
            lines.append("<<No log entries captured in the last \(windowDescription) seconds>>")
        } else {
            lines.append(contentsOf: entries.map(\.line))
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        lines.append("Capture timestamp: \(isoFormatter.string(from: captureTimestamp))")

        let output = lines.joined(separator: "\n") + "\n"
        let targetURL: URL
        if let destinationURL {
            targetURL = destinationURL
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            targetURL = URL(fileURLWithPath: cwd, isDirectory: true)
                .appendingPathComponent(timeTravelLogFilename, isDirectory: false)
        }

        do {
            try output.write(to: targetURL, atomically: true, encoding: .utf8)
            clearEntries(through: captureTimestamp)
            return true
        } catch {
            fputs("Logger dump failed: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    private static func recordForTimeTravel(line: String, timestamp: Date) {
        bufferQueue.sync {
            recentEntries.append(LogEntry(timestamp: timestamp, line: line))
            let retentionCutoff = timestamp.addingTimeInterval(-bufferRetentionWindow)
            while let first = recentEntries.first, first.timestamp < retentionCutoff {
                recentEntries.removeFirst()
            }
        }
    }

    private static func clearEntries(through timestamp: Date) {
        bufferQueue.sync {
            recentEntries.removeAll { $0.timestamp <= timestamp }
        }
    }

    private struct LogEntry {
        let timestamp: Date
        let line: String
    }
}
