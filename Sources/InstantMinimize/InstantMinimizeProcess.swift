/// Finds and restarts the current user's Dock, and runs the bundled injector outside the UI thread.
import AppKit
import Darwin

struct InstantMinimizeDock: Codable, Equatable {
    let pid: pid_t
    let launchedAt: Date

    static func current() -> Self? {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        guard applications.count == 1, let app = applications.first,
              app.isFinishedLaunching, !app.isTerminated else { return nil }
        // Dock has no NSRunningApplication.launchDate on some systems. Use the kernel's
        // start time, which the privileged helper can also verify without Launch Services.
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(app.processIdentifier, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid() else { return nil }
        let start = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
        return Self(pid: app.processIdentifier, launchedAt: Date(timeIntervalSince1970: start))
    }

    func restart() -> String? {
        // An exit, replacement, or reused PID must never restart an unrelated process.
        guard Self.current() == self else { return nil }
        if kill(pid, SIGTERM) == 0 || errno == ESRCH { return nil }
        return String(cString: strerror(errno))
    }
}

struct InstantMinimizeResult: Decodable {
    enum Status: String, Decodable { case active, permissionDenied, failed }
    let status: Status
    let needsDockRestart: Bool
    let message: String

    static func failure(_ message: String, needsRestart: Bool) -> Self {
        Self(status: .failed, needsDockRestart: needsRestart, message: message)
    }

    var failureDescription: String {
        let lines = message.split(whereSeparator: \.isNewline).map(String.init)
        let error = lines.first(where: { $0.hasPrefix("error:") }) ??
            lines.first(where: { !$0.contains("ZONOGY_INJECTION_STARTED") }) ?? "Dock patch verification failed."
        return String(error.prefix(350))
    }
}

extension InstantMinimizeController.Environment {
    static var live: Self {
        Self(
            prerequisiteFailure: InstantMinimizeProcess.prerequisiteFailure,
            currentDock: InstantMinimizeDock.current,
            loadActivation: { InstantMinimizeActivationStore.load() },
            saveActivation: { InstantMinimizeActivationStore.save($0) },
            watchExit: { dock, callback in
                let source = DispatchSource.makeProcessSource(identifier: dock.pid, eventMask: .exit, queue: .main)
                source.setEventHandler(handler: callback)
                source.resume()
                return { source.setEventHandler(handler: nil); source.cancel() }
            },
            inject: InstantMinimizeProcess.run,
            restart: { $0.restart() },
            schedule: { delay, callback in
                let item = DispatchWorkItem(block: callback)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
                return { item.cancel() }
            },
            now: { ProcessInfo.processInfo.systemUptime }
        )
    }
}

private enum InstantMinimizeProcess {
    private static let helperName = "Zonogy-helper"

    private static var directory: URL {
        // App bundles carry their own tools. Plain swift builds can use separately built tools
        // beside the build products, without depending on an instantmini installation.
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/InstantMinimize")
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/InstantMinimize")
    }

    static func prerequisiteFailure() -> String? {
        #if !arch(arm64)
        return "Instant minimize requires an Apple Silicon Mac."
        #else
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else {
            return "Instant minimize currently supports macOS 27 only."
        }
        for name in [helperName, "loader", "payload.dylib", "lldb_inject.py"] {
            let path = directory.appendingPathComponent(name).path
            guard FileManager.default.isReadableFile(atPath: path),
                  ![helperName, "loader"].contains(name) || FileManager.default.isExecutableFile(atPath: path) else {
                return "This build does not contain the instant minimize tools."
            }
        }
        return nil
        #endif
    }

    static func run(dock: InstantMinimizeDock, authorized: Bool,
                    completion: @escaping (InstantMinimizeResult) -> Void) -> InstantMinimizeController.Cancel {
        let process = Process()
        process.executableURL = directory.appendingPathComponent(helperName)
        process.arguments = [authorized ? "--authorize" : "--inject", String(dock.pid), String(getuid()),
                             String(format: "%.6f", dock.launchedAt.timeIntervalSince1970)]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        // All completion/cancellation state stays on the main queue. The helper's output is
        // bounded (one JSON result); stderr only contains launch/runtime diagnostics.
        var finished = false
        var timeout: DispatchWorkItem?
        func finish(_ result: InstantMinimizeResult) {
            guard !finished else { return }
            finished = true
            timeout?.cancel()
            timeout = nil
            completion(result)
        }
        process.terminationHandler = { task in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                guard !finished else { return }
                if task.terminationReason == .exit, task.terminationStatus == 0,
                   let result = try? JSONDecoder().decode(InstantMinimizeResult.self, from: data) {
                    finish(result)
                } else {
                    let detail = String(data: errorData, encoding: .utf8) ?? ""
                    finish(.failure("The injection helper exited without verification. \(detail)", needsRestart: true))
                }
            }
        }
        do {
            try process.run()
            let item = DispatchWorkItem {
                if process.isRunning { process.terminate() }
                finish(.failure("The injection attempt timed out. Turn this setting off and on to retry.", needsRestart: true))
            }
            timeout = item
            DispatchQueue.main.asyncAfter(deadline: .now() + (authorized ? 120 : 20), execute: item)
        } catch {
            DispatchQueue.main.async {
                finish(.failure("Could not start the injection helper: \(error.localizedDescription)", needsRestart: false))
            }
        }
        return {
            finished = true
            timeout?.cancel()
            timeout = nil
            if process.isRunning { process.terminate() }
        }
    }
}
