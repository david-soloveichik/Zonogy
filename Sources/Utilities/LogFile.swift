/// The log file: while the Debug tab's "Save the log to a file" toggle is on, every line the Logger
/// emits is also appended to a file in /tmp in the `log` tool's compact style, so a trace outlives the
/// unified log's in-memory buffers. Once the file is a day old, the next line retires it to the
/// previous-day file (replacing that one) and starts afresh, so the pair holds the last one to two days
/// and old lines go a file at a time, never one by one. The calling thread only notes the time and
/// thread; a serial utility queue formats and writes, unbuffered, so a crash loses at most the few
/// lines still queued, and quitting drains the queue first.
import Foundation

enum LogFile {
    static let path = "/tmp/zonogy-debug.log"
    static let previousPath = "/tmp/zonogy-debug-previous.log"
    static let rotationInterval: TimeInterval = 24 * 60 * 60

    /// Read on every log call, so a lock-protected flag rather than a trip through the queue.
    @ThreadSafe private static var isEnabled = DebugPreferencesStore.loadLogFileEnabled()

    private static let queue = DispatchQueue(label: "\(Logger.subsystem).log-file", qos: .utility)

    // Confined to `queue`.
    private static var descriptor: Int32?
    private static var rotationDeadline: TimeInterval = .infinity
    private static var formatter = LogLineFormatter()

    /// Applies the Debug toggle. Off marks the file and closes it once the lines already queued are
    /// written; on has the next line open it again.
    static func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            let time = Date().timeIntervalSince1970
            queue.async {
                if let descriptor {
                    write("--- Saving the log to a file turned off \(formatter.timestamp(time))\n", to: descriptor)
                }
                closeFile()
            }
        }
    }

    /// Mirrors one line while enabled. `Logger` calls this for every line it emits.
    static func append(_ level: LogLineFormatter.Level, category: String, message: String) {
        guard isEnabled else { return }
        let time = Date().timeIntervalSince1970
        var threadID: UInt64 = 0
        pthread_threadid_np(nil, &threadID)
        queue.async {
            record(formatter.line(time: time, threadID: threadID, level: level, category: category, message: message), at: time)
        }
    }

    /// Waits for the queued lines to be written. Called as Zonogy quits, whose last lines are logged
    /// moments before the process exits.
    static func drain() {
        queue.sync {}
    }

    // MARK: - Queue-confined file handling

    private static func record(_ line: String, at time: TimeInterval) {
        if descriptor == nil || time >= rotationDeadline {
            // A line queued just as the toggle went off must not reopen the file.
            guard isEnabled else { return }
            openFile(at: time)
        }
        guard let descriptor else {
            // Only an unwritable /tmp, or something else planted at the path. Turn the preference off
            // as well, so the Debug tab shows what is happening.
            isEnabled = false
            DebugPreferencesStore.saveLogFileEnabled(false)
            Logger.error("Could not open \(path); turned off saving the log to a file")
            return
        }
        write(line, to: descriptor)
    }

    /// Opens the file for appending, first retiring it to the previous-day file if it is a day old, and
    /// marks the spot with a version line. Dating the deadline from the file's creation keeps relaunches
    /// and toggling filling the same day's file.
    private static func openFile(at time: TimeInterval) {
        closeFile()
        var fileStart = creationTime(of: path) ?? time
        if time >= fileStart + rotationInterval {
            // Should the rename fail, the old file keeps growing and retiring it is retried in a day.
            rename(path, previousPath)
            fileStart = time
        }
        // Private to the user, and never through a symlink someone else left at the path.
        let opened = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard opened >= 0 else { return }
        descriptor = opened
        rotationDeadline = fileStart + rotationInterval
        write("--- \(AppVersion.preferencesDisplayString), log file opened \(formatter.timestamp(time))\n", to: opened)
    }

    private static func closeFile() {
        if let descriptor {
            close(descriptor)
        }
        descriptor = nil
    }

    private static func write(_ text: String, to descriptor: Int32) {
        var text = text
        text.withUTF8 { bytes in
            _ = Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
    }

    /// When the file at `path` was created, as a Unix time, if it exists.
    private static func creationTime(of path: String) -> TimeInterval? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return TimeInterval(status.st_birthtimespec.tv_sec) + TimeInterval(status.st_birthtimespec.tv_nsec) / 1_000_000_000
    }
}
