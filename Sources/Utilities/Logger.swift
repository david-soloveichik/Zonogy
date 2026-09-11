/// Logging façade over the macOS unified log. Every line is recorded under Zonogy's subsystem with
/// the source file as its category. `debug` lines are kept in memory only (info level); `keep` and
/// `error` lines are the ones macOS also persists for days: countable events and unexpected failures.
/// While the Debug tab's "Save the log to a file" toggle is on, every line also goes to `LogFile`.
import Foundation
import os

enum Logger {
    /// The unified-log subsystem for every Zonogy log line and signpost (also the bundle identifier).
    static let subsystem = "com.dsemeas.zonogy"

    /// The everything log. Info level: macOS keeps it in memory and purges it as its buffers fill.
    /// Read it while it lasts with the time-travel capture, `log stream`, or `log show --info`.
    static func debug(_ message: String, file: String = #fileID) {
        let channel = channel(forFile: file)
        channel.logger.info("\(message, privacy: .public)")
        LogFile.append(.info, category: channel.category, message: message)
    }

    /// A notable event worth counting over time, such as a slow accessibility call. Notice level,
    /// which macOS persists for days. An explicit `category` lets the events be counted with one
    /// predicate; otherwise the category is the source file, like every other line.
    static func keep(_ message: String, category: String? = nil, file: String = #fileID) {
        let channel = category.map { Self.channel(category: $0) } ?? Self.channel(forFile: file)
        channel.logger.notice("\(message, privacy: .public)")
        LogFile.append(.notice, category: channel.category, message: message)
    }

    /// An unexpected failure or inconsistency. Error level, which macOS persists for days, so it can
    /// be found later even when nobody was watching. The message must stand alone: by then the
    /// surrounding trace is gone.
    static func error(_ message: String, file: String = #fileID) {
        let channel = channel(forFile: file)
        channel.logger.error("\(message, privacy: .public)")
        LogFile.append(.error, category: channel.category, message: message)
    }

    // MARK: - Channel cache

    /// A category's `os.Logger` with the category's name, which the log file needs for every line.
    private struct Channel: Sendable {
        let logger: os.Logger
        let category: String
    }

    /// One channel per category, keyed by the `#fileID` or explicit category it was requested with,
    /// so the hot path is a single dictionary lookup.
    private static let channelsByKey = OSAllocatedUnfairLock<[String: Channel]>(initialState: [:])

    private static func channel(forFile fileID: String) -> Channel {
        channel(key: fileID, category: Self.category(forFile: fileID))
    }

    private static func channel(category: String) -> Channel {
        channel(key: category, category: category)
    }

    private static func channel(key: String, category: @autoclosure () -> String) -> Channel {
        if let existing = channelsByKey.withLock({ $0[key] }) {
            return existing
        }
        let name = category()
        let created = Channel(logger: os.Logger(subsystem: subsystem, category: name), category: name)
        return channelsByKey.withLock { table in
            if let raced = table[key] {
                return raced
            }
            table[key] = created
            return created
        }
    }

    /// "Zonogy/DockClickInterceptor.swift" becomes "DockClickInterceptor".
    private static func category(forFile fileID: String) -> String {
        let fileName = fileID.split(separator: "/").last.map(String.init) ?? fileID
        return fileName.hasSuffix(".swift") ? String(fileName.dropLast(".swift".count)) : fileName
    }
}
