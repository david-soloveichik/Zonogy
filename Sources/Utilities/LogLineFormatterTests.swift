import Foundation

/// Guardrail tests for the compact-style log line and its arithmetic timestamps.
enum LogLineFormatterTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("LogLineFormatterTests: \(message)")
                allPassed = false
            }
        }

        let chicago = TimeZone(identifier: "America/Chicago")!
        let havana = TimeZone(identifier: "America/Havana")!
        let kolkata = TimeZone(identifier: "Asia/Kolkata")!
        let utc = TimeZone(identifier: "UTC")!

        // The line matches one the log tool printed for the same event (19:35:41.013 in Chicago, UTC-5).
        var sample = LogLineFormatter(processName: "Zonogy", pid: 67950, subsystem: "com.dsemeas.zonogy", timeZone: chicago)
        let sampleTime = unixTime(2026, 9, 11, 0, 35, 41) + 0.0135
        let line = sample.line(time: sampleTime, threadID: 0x1560ae3, level: .info, category: "WindowCapturePipeline", message: "capturing")
        assert(
            line == "2026-09-10 19:35:41.013 I  Zonogy[67950:1560ae3] [com.dsemeas.zonogy:WindowCapturePipeline] capturing\n",
            "the line matches the log tool's compact style (got \(line))"
        )
        assert(
            sample.line(time: sampleTime, threadID: 1, level: .notice, category: "SlowAX", message: "m").contains(" Df Zonogy[67950:1] "),
            "notice level uses the tool's Df code"
        )
        assert(
            sample.line(time: sampleTime, threadID: 1, level: .error, category: "C", message: "m").contains(" E  Zonogy[67950:1] "),
            "error level uses the tool's E code"
        )

        // Timestamps agree with DateFormatter across midnights, daylight-saving changes (including
        // Havana's, at midnight, which makes that day start at 01:00), a year end, a half-hour zone,
        // and a clock that jumps backwards, so the cached day is refreshed correctly.
        let runStarts = [
            unixTime(2026, 3, 8, 6, 0, 0),    // Chicago springs forward at 08:00 UTC
            unixTime(2026, 11, 1, 5, 0, 0),   // Chicago falls back at 07:00 UTC
            unixTime(2026, 12, 31, 20, 0, 0), // year end in every zone
            unixTime(2026, 3, 9, 3, 30, 0),   // 23:30 in Havana on the day it sprang forward at midnight
            unixTime(2026, 3, 7, 6, 0, 0),    // earlier than the runs before it
        ]
        for zone in [chicago, havana, kolkata, utc] {
            var formatter = LogLineFormatter(processName: "Zonogy", pid: 1, subsystem: "s", timeZone: zone)
            let reference = DateFormatter()
            reference.locale = Locale(identifier: "en_US_POSIX")
            reference.calendar = Calendar(identifier: .gregorian)
            reference.timeZone = zone
            reference.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            for start in runStarts {
                for step in 0..<40 {
                    let time = start + Double(step) * 17 * 60 + 0.5
                    let expected = reference.string(from: Date(timeIntervalSince1970: time))
                    let actual = formatter.timestamp(time)
                    assert(actual == expected, "\(zone.identifier): expected \(expected), got \(actual)")
                }
            }
        }

        // Milliseconds are truncated like the log tool's, not rounded.
        var truncating = LogLineFormatter(processName: "Zonogy", pid: 1, subsystem: "s", timeZone: utc)
        assert(
            truncating.timestamp(unixTime(2026, 9, 10, 0, 0, 0) + 0.0625) == "2026-09-10 00:00:00.062",
            "a fraction of 62.5 milliseconds prints as 062"
        )
        assert(
            truncating.timestamp(unixTime(2026, 9, 10, 23, 59, 59) + 0.9995) == "2026-09-10 23:59:59.999",
            "the last millisecond of a day stays in that day"
        )

        if allPassed {
            print("LogLineFormatterTests: all tests passed")
        }
        return allPassed
    }

    /// The Unix time of a UTC calendar instant.
    private static func unixTime(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        return calendar.date(from: components)!.timeIntervalSince1970
    }
}
