/// Logging façade over the macOS unified log. Every line is recorded under Zonogy's subsystem with
/// the source file as its category. `debug` lines are kept in memory only (info level); `keep` and
/// `error` lines are the ones macOS also persists for days: countable events and unexpected failures.
import Foundation
import os

enum Logger {
    /// The unified-log subsystem for every Zonogy log line and signpost (also the bundle identifier).
    static let subsystem = "com.dsemeas.zonogy"

    /// The everything log. Info level: macOS keeps it in memory and purges it as its buffers fill.
    /// Read it while it lasts with the time-travel capture, `log stream`, or `log show --info`.
    static func debug(_ message: String, file: String = #fileID) {
        logger(forFile: file).info("\(message, privacy: .public)")
    }

    /// A notable event worth counting over time, such as a slow accessibility call. Notice level,
    /// which macOS persists for days. An explicit `category` lets the events be counted with one
    /// predicate; otherwise the category is the source file, like every other line.
    static func keep(_ message: String, category: String? = nil, file: String = #fileID) {
        let logger = category.map { Self.logger(category: $0) } ?? Self.logger(forFile: file)
        logger.notice("\(message, privacy: .public)")
    }

    /// An unexpected failure or inconsistency. Error level, which macOS persists for days, so it can
    /// be found later even when nobody was watching. The message must stand alone: by then the
    /// surrounding trace is gone.
    static func error(_ message: String, file: String = #fileID) {
        logger(forFile: file).error("\(message, privacy: .public)")
    }

    // MARK: - Logger cache

    /// One `os.Logger` per category, keyed by the `#fileID` or explicit category it was requested
    /// with, so the hot path is a single dictionary lookup.
    private static let loggersByKey = OSAllocatedUnfairLock<[String: os.Logger]>(initialState: [:])

    private static func logger(forFile fileID: String) -> os.Logger {
        logger(key: fileID, category: Self.category(forFile: fileID))
    }

    private static func logger(category: String) -> os.Logger {
        logger(key: category, category: category)
    }

    private static func logger(key: String, category: @autoclosure () -> String) -> os.Logger {
        if let existing = loggersByKey.withLock({ $0[key] }) {
            return existing
        }
        let created = os.Logger(subsystem: subsystem, category: category())
        return loggersByKey.withLock { table in
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
