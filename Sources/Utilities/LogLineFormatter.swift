/// Formats log lines the way `log show --style compact` prints them, so the log file reads like the
/// time-travel capture and the Terminal commands on the Debug tab:
///
///     2026-09-10 19:35:41.013 I  Zonogy[67950:1560ae3] [com.dsemeas.zonogy:WindowCapturePipeline] message
///
/// The timestamp is local time truncated to milliseconds, like the tool's. It is built with integer
/// arithmetic from a cached local date and UTC offset, refreshed only when the day, the
/// daylight-saving offset, or the hour changes, so formatting costs far less than writing the line.
import Foundation

struct LogLineFormatter {
    /// The tool's two-character type column for the levels Zonogy logs at.
    enum Level: String {
        case info = "I "
        case notice = "Df"
        case error = "E "
    }

    /// "Zonogy[67950:", completed per line with the thread id.
    private let processPrefix: String
    private let subsystem: String
    private let timeZone: TimeZone

    /// The cached local day: its "yyyy-MM-dd " prefix and UTC offset hold for Unix times in
    /// `cacheStart ..< cacheEnd`.
    private var dayPrefix = ""
    private var utcOffset: TimeInterval = 0
    private var cacheStart: TimeInterval = .infinity
    private var cacheEnd: TimeInterval = -.infinity

    init(
        processName: String = ProcessInfo.processInfo.processName,
        pid: pid_t = getpid(),
        subsystem: String = Logger.subsystem,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        processPrefix = "\(processName)[\(pid):"
        self.subsystem = subsystem
        self.timeZone = timeZone
    }

    /// One newline-terminated line. `time` is a Unix time; `threadID` is the value
    /// `pthread_threadid_np` reports, which is the thread the unified log records.
    mutating func line(time: TimeInterval, threadID: UInt64, level: Level, category: String, message: String) -> String {
        "\(timestamp(time)) \(level.rawValue) \(processPrefix)\(String(threadID, radix: 16))] [\(subsystem):\(category)] \(message)\n"
    }

    /// "yyyy-MM-dd HH:mm:ss.SSS" in local time, milliseconds truncated.
    mutating func timestamp(_ time: TimeInterval) -> String {
        if time < cacheStart || time >= cacheEnd {
            refreshCache(at: time)
        }
        let localMilliseconds = Int((time + utcOffset) * 1000)
        let secondOfDay = localMilliseconds / 1000 % 86_400
        return dayPrefix
            + twoDigits(secondOfDay / 3600) + ":" + twoDigits(secondOfDay / 60 % 60) + ":" + twoDigits(secondOfDay % 60)
            + "." + threeDigits(localMilliseconds % 1000)
    }

    /// Recomputes the cached day for `time`. It holds until the next local midnight or
    /// daylight-saving transition, and at most an hour so a changed system time zone shows up soon.
    private mutating func refreshCache(at time: TimeInterval) {
        let date = Date(timeIntervalSince1970: time)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        dayPrefix = "\(day.year ?? 0)-\(twoDigits(day.month ?? 0))-\(twoDigits(day.day ?? 0)) "
        utcOffset = TimeInterval(timeZone.secondsFromGMT(for: date))
        // The day's interval, not its start plus a day: a day that begins at 01:00 because clocks
        // sprang forward at midnight still ends at the next midnight.
        let dayEnd = calendar.dateInterval(of: .day, for: date)?.end
        let nextTransition = timeZone.nextDaylightSavingTimeTransition(after: date)
        cacheStart = time
        cacheEnd = min(
            dayEnd?.timeIntervalSince1970 ?? .infinity,
            nextTransition?.timeIntervalSince1970 ?? .infinity,
            time + 3600
        )
    }

    private func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : String(value)
    }

    private func threeDigits(_ value: Int) -> String {
        value < 10 ? "00\(value)" : value < 100 ? "0\(value)" : String(value)
    }
}
