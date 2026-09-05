import Foundation

/// Guardrail tests for the time-travel capture interval and log tool arguments.
enum TimeTravelLogCaptureTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("TimeTravelLogCaptureTests: \(message)")
                allPassed = false
            }
        }

        let now = Date(timeIntervalSince1970: 1_000_000)
        let window: TimeInterval = 60

        let fresh = TimeTravelLogCapture.captureInterval(now: now, previousCapture: nil, window: window)
        assert(
            fresh.start == now.addingTimeInterval(-window) && fresh.end == now,
            "without a previous capture the interval is the full window"
        )

        let recent = now.addingTimeInterval(-10)
        let sinceRecent = TimeTravelLogCapture.captureInterval(now: now, previousCapture: recent, window: window)
        assert(
            sinceRecent.start == recent && sinceRecent.end == now,
            "a previous capture inside the window cuts the interval short at that capture"
        )

        let old = now.addingTimeInterval(-500)
        let sinceOld = TimeTravelLogCapture.captureInterval(now: now, previousCapture: old, window: window)
        assert(
            sinceOld.start == now.addingTimeInterval(-window) && sinceOld.end == now,
            "a previous capture older than the window leaves the full window"
        )

        let future = now.addingTimeInterval(30)
        let clamped = TimeTravelLogCapture.captureInterval(now: now, previousCapture: future, window: window)
        assert(
            clamped.start == now && clamped.duration == 0,
            "a previous capture after now (clock change) yields an empty interval, never an invalid one"
        )

        let arguments = TimeTravelLogCapture.logArguments(for: sinceRecent)
        assert(arguments.first == "show", "arguments invoke the show subcommand")
        assert(arguments.contains("--info"), "arguments include info-level lines")
        assert(
            argument(after: "--start", in: arguments) == TimeTravelLogCapture.timestampString(recent),
            "the start argument is the interval start"
        )
        assert(
            argument(after: "--end", in: arguments) == TimeTravelLogCapture.timestampString(now),
            "the end argument is the interval end"
        )
        assert(
            argument(after: "--predicate", in: arguments)?.contains(Logger.subsystem) == true,
            "the predicate selects Zonogy's subsystem"
        )

        let stamp = TimeTravelLogCapture.timestampString(now)
        assert(
            stamp.count == 19 && stamp[stamp.index(stamp.startIndex, offsetBy: 10)] == " ",
            "timestamps use the yyyy-MM-dd HH:mm:ss form the log tool accepts (got \(stamp))"
        )

        if allPassed {
            print("TimeTravelLogCaptureTests: all tests passed")
        }
        return allPassed
    }

    private static func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}
