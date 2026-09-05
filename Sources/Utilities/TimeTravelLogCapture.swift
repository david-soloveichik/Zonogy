/// Time-travel debug capture: when the capture shortcut is pressed, saves Zonogy's recent unified-log
/// lines to a file. Covers the last `window` seconds, cut short at the previous capture request
/// (successful or not), so two presses in quick succession save only the log between them.
import Foundation

enum TimeTravelLogCapture {
    static let outputPath = "/tmp/zonogy-debug-time-travel.log"
    static let window: TimeInterval = 60

    /// When the previous capture ran. Main-thread only.
    private static var previousCaptureTime: Date?

    /// Serial, so a quick second press (a narrower query) cannot be overwritten by the slower first.
    private static let captureQueue = DispatchQueue(label: "\(Logger.subsystem).time-travel-capture", qos: .utility)

    /// The interval a capture at `now` covers: the last `window` seconds, starting no earlier than
    /// the previous capture and never after `now`.
    static func captureInterval(now: Date, previousCapture: Date?, window: TimeInterval = window) -> DateInterval {
        let windowStart = now.addingTimeInterval(-window)
        let start = min(now, max(windowStart, previousCapture ?? windowStart))
        return DateInterval(start: start, end: now)
    }

    /// Arguments for `/usr/bin/log`: Zonogy's lines at info level and above within `interval`.
    static func logArguments(for interval: DateInterval) -> [String] {
        [
            "show",
            "--start", timestampString(interval.start),
            "--end", timestampString(interval.end),
            "--info",
            "--style", "compact",
            "--predicate", "subsystem == \"\(Logger.subsystem)\"",
        ]
    }

    /// Writes the capture file off the main thread. `completion` runs on the main thread with
    /// whether the file was written and the log tool succeeded.
    static func capture(completion: @escaping (Bool) -> Void) {
        let now = Date()
        let interval = captureInterval(now: now, previousCapture: previousCaptureTime)
        previousCaptureTime = now
        let arguments = logArguments(for: interval)
        let header = "\(AppVersion.preferencesDisplayString)\n"
            + "Capture window: \(timestampString(interval.start)) to \(timestampString(interval.end))\n"
        let footer = "Capture timestamp: \(isoTimestampString(now))\n"

        captureQueue.async {
            let success = writeCapture(arguments: arguments, header: header, footer: footer)
            DispatchQueue.main.async {
                completion(success)
            }
        }
    }

    private static func writeCapture(arguments: [String], header: String, footer: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return false
        }
        // Drain before waiting, or a large capture fills the pipe and the tool never exits.
        let logText = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        do {
            try (header + logText + footer).write(toFile: outputPath, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        return process.terminationStatus == 0
    }

    /// The local-time form the `log` tool accepts for `--start` and `--end`.
    static func timestampString(_ date: Date) -> String {
        logTimestampFormatter.string(from: date)
    }

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func isoTimestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
