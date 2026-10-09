/// Guardrails for instant minimize preferences, crash recovery, cancellation, and Dock cleanup.
import Foundation

enum InstantMinimizeControllerTests {
    private final class System {
        var dock: InstantMinimizeDock? = .init(pid: 100, launchedAt: Date(timeIntervalSince1970: 100))
        var activation: InstantMinimizeActivation?
        var prerequisite: String?
        var time: TimeInterval = 100
        var restartError: String?
        var restarts: [InstantMinimizeDock] = []
        var injections: [(dock: InstantMinimizeDock, authorized: Bool, reply: (InstantMinimizeResult) -> Void)] = []
        var exits: [() -> Void] = []
        var scheduled: [() -> Void] = []
        var cancellations = 0

        var environment: InstantMinimizeController.Environment {
            .init(
                prerequisiteFailure: { self.prerequisite },
                currentDock: { self.dock },
                loadActivation: { self.activation },
                saveActivation: { self.activation = $0 },
                watchExit: { _, callback in self.exits.append(callback); return {} },
                inject: { dock, authorized, reply in
                    self.injections.append((dock, authorized, reply))
                    return { self.cancellations += 1 }
                },
                restart: { dock in self.restarts.append(dock); return self.restartError },
                schedule: { _, callback in self.scheduled.append(callback); return {} },
                now: { self.time }
            )
        }
    }

    static func run() -> Bool {
        var passed = true
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { print("InstantMinimizeControllerTests: \(message)"); passed = false }
        }
        let active = InstantMinimizeResult(status: .active, needsDockRestart: true, message: "verified")
        let denied = InstantMinimizeResult(status: .permissionDenied, needsDockRestart: false, message: "Access denied")

        do {
            let defaults = UserDefaults.standard
            let key = UserDefaultsKeys.instantMinimizeEnabled
            let previousValue = defaults.object(forKey: key)
            defer {
                if let previousValue { defaults.set(previousValue, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            defaults.removeObject(forKey: key)
            check(!ExperimentalPreferencesStore.loadInstantMinimizeEnabled(), "the experimental preference must default to off")
            ExperimentalPreferencesStore.saveInstantMinimizeEnabled(true)
            check(ExperimentalPreferencesStore.loadInstantMinimizeEnabled(), "the experimental preference must persist enabling")
            ExperimentalPreferencesStore.saveInstantMinimizeEnabled(false)
            check(!ExperimentalPreferencesStore.loadInstantMinimizeEnabled(), "the experimental preference must persist disabling")
        }
        do {
            let suite = "Zonogy.InstantMinimizeActivationTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let activation = InstantMinimizeActivation(
                dock: .init(pid: 100, launchedAt: Date(timeIntervalSince1970: 1_791_548_400.123456)),
                verifiedAt: 4_200.12345
            )
            check(InstantMinimizeActivationStore.load(defaults: defaults) == nil,
                  "an absent activation record must not claim a patch")
            InstantMinimizeActivationStore.save(activation, defaults: defaults)
            check(InstantMinimizeActivationStore.load(defaults: defaults) == activation,
                  "activation persistence must preserve the exact Dock identity and verification time")
            InstantMinimizeActivationStore.save(nil, defaults: defaults)
            check(InstantMinimizeActivationStore.load(defaults: defaults) == nil,
                  "clearing activation must remove the saved record")
        }
        do {
            let system = System()
            let controller = InstantMinimizeController(environment: system.environment)
            controller.start(enabled: false)
            check(!controller.isEnabled && !controller.isActive && system.injections.isEmpty && system.restarts.isEmpty,
                  "startup without a preference or activation record must leave Dock alone")
        }
        for savedEnabled in [false, true] {
            let system = System()
            var previous: InstantMinimizeController? = InstantMinimizeController(environment: system.environment)
            previous?.start(enabled: true)
            check(system.activation == nil, "an unverified attempt must not be remembered as active")
            system.injections[0].reply(active)
            check(system.activation?.dock == system.dock, "verified success must remember its Dock")
            previous = nil // A crash does not call shutdown.

            let controller = InstantMinimizeController(environment: system.environment)
            system.prerequisite = "Injection tools are unavailable"
            controller.start(enabled: savedEnabled)
            check(controller.isEnabled && controller.isActive && !controller.hasError && system.exits.count == 2,
                  "a surviving verified Dock must restore enabled/active state and its exit watcher")
            check(system.injections.count == 1 && system.restarts.isEmpty,
                  "recovery must not reinject, request authorization, or restart Dock")
            if savedEnabled { controller.shutdown() }
            else { controller.setEnabled(false) }
            check(system.restarts == [system.dock!] && system.activation == nil && !controller.isActive,
                  "disable and quit must clean up a recovered patch and forget its activation")
        }
        for savedEnabled in [false, true] {
            let replacements: [InstantMinimizeDock?] = [
                .init(pid: 100, launchedAt: Date(timeIntervalSince1970: 200)),
                .init(pid: 101, launchedAt: Date(timeIntervalSince1970: 100)),
                nil,
            ]
            for replacement in replacements {
                let system = System()
                system.activation = .init(dock: system.dock!, verifiedAt: system.time)
                system.dock = replacement
                let controller = InstantMinimizeController(environment: system.environment)
                controller.start(enabled: savedEnabled)
                check(!controller.isActive && system.activation == nil && system.restarts.isEmpty,
                      "a missing Dock or different PID/start time must discard the old activation")
                check(controller.isEnabled == savedEnabled &&
                      system.injections.count == (savedEnabled && replacement != nil ? 1 : 0) &&
                      system.scheduled.count == (savedEnabled && replacement == nil ? 1 : 0),
                      "a changed Dock must follow the saved checkbox setting")
            }
        }
        for age in [2.0, 10.0] {
            let system = System()
            system.activation = .init(dock: system.dock!, verifiedAt: system.time - age)
            let controller = InstantMinimizeController(environment: system.environment)
            controller.start(enabled: true)
            system.dock = .init(pid: 101, launchedAt: Date(timeIntervalSince1970: 200))
            system.exits[0]()
            check(system.activation == nil && !controller.isActive && system.restarts.isEmpty,
                  "a recovered Dock exiting must clear its activation and leave the replacement alone")
            check(controller.hasError == (age < 5) && system.injections.count == (age < 5 ? 0 : 1),
                  "crash recovery must preserve the original activation time for the immediate-exit guard")
        }
        do {
            let system = System()
            system.prerequisite = "Unsupported configuration"
            let controller = InstantMinimizeController(environment: system.environment)
            controller.setEnabled(true)
            check(controller.hasError && system.injections.isEmpty && system.restarts.isEmpty,
                  "unsupported configurations must fail before touching Dock")
        }
        do {
            let system = System()
            let controller = InstantMinimizeController(environment: system.environment)
            controller.setEnabled(true)
            check(!controller.isActive, "loading is not verified success")
            system.injections[0].reply(active)
            check(controller.isActive, "verified success should be active")
            controller.setEnabled(false)
            check(!controller.isActive, "disabling must clear the active state")
            system.exits[0]()
            check(system.restarts.count == 1 && system.injections.count == 1,
                  "disable must restart once without reinjecting from its exit event")
            controller.shutdown()
            check(system.restarts.count == 1, "quit after disabling must not restart Dock again")
        }
        do {
            let system = System()
            let controller = InstantMinimizeController(environment: system.environment)
            controller.setEnabled(true)
            system.injections[0].reply(denied)
            check(system.injections.count == 2 && system.injections[1].authorized,
                  "a denied ordinary attempt should offer administrator authorization")
            system.injections[1].reply(denied)
            check(controller.hasError && system.injections.count == 2 && system.restarts.isEmpty,
                  "denial after authorization must neither loop nor restart an unmodified Dock")
        }
        do {
            let system = System()
            let controller = InstantMinimizeController(environment: system.environment)
            controller.setEnabled(true)
            system.injections[0].reply(denied)
            system.injections[1].reply(.failure("Authorization cancelled", needsRestart: false))
            check(controller.hasError && system.restarts.isEmpty, "cancelled authorization must leave Dock alone")
        }
        do {
            let system = System()
            let controller = InstantMinimizeController(environment: system.environment)
            controller.setEnabled(true)
            system.injections[0].reply(.failure("Partial patch", needsRestart: true))
            system.exits[0]()
            check(controller.hasError && system.restarts.count == 1 && system.injections.count == 1 && system.activation == nil,
                  "a partial failure must be cleaned up once and stop automatic retries")
        }
        do {
            let system = System()
            let controller = InstantMinimizeController(environment: system.environment)
            controller.setEnabled(true)
            system.injections[0].reply(denied)
            let original = system.dock!
            controller.shutdown()
            system.dock = .init(pid: 101, launchedAt: Date(timeIntervalSince1970: 101))
            system.injections[1].reply(active)
            system.exits[0]()
            check(system.cancellations == 1 && system.restarts == [original] && system.injections.count == 2,
                  "quit during approval must cancel, restart only its target, and ignore late success")
            check(system.activation == nil, "late success after quit must not leave an activation record")
        }
        do {
            let system = System()
            let controller = InstantMinimizeController(environment: system.environment)
            controller.setEnabled(true)
            system.injections[0].reply(active)
            system.time += 10
            system.dock = .init(pid: 101, launchedAt: Date(timeIntervalSince1970: 101))
            system.exits[0]()
            check(system.injections.count == 2 && system.injections[1].dock == system.dock && system.restarts.isEmpty,
                  "a later Dock restart should apply to the new process without killing it")
            // Delivery of the old exit event again must not disturb the replacement attempt.
            system.exits[0]()
            check(system.injections.count == 2, "stale exit events must be ignored")
        }
        for verified in [false, true] {
            let system = System()
            let controller = InstantMinimizeController(environment: system.environment)
            controller.setEnabled(true)
            if verified { system.injections[0].reply(active) }
            system.exits[0]()
            check(controller.hasError && system.injections.count == 1 && system.restarts.isEmpty,
                  "Dock exiting during or just after patching must not create a crash loop")
        }
        do {
            let system = System()
            system.dock = nil
            let controller = InstantMinimizeController(environment: system.environment)
            controller.setEnabled(true)
            for _ in 0..<8 { system.scheduled.removeFirst()() }
            check(controller.hasError && system.scheduled.isEmpty && system.injections.isEmpty,
                  "Dock readiness waits must be bounded")
            controller.setEnabled(false)
            controller.setEnabled(true)
            let pending = system.scheduled.removeFirst()
            controller.setEnabled(false)
            system.dock = .init(pid: 101, launchedAt: Date(timeIntervalSince1970: 101))
            pending()
            check(system.injections.isEmpty, "a delayed readiness callback must not enable a disabled feature")
        }
        do {
            let system = System()
            let controller = InstantMinimizeController(environment: system.environment)
            controller.setEnabled(true)
            system.injections[0].reply(active)
            system.restartError = "Permission denied"
            controller.setEnabled(false)
            check(controller.hasError && system.activation?.dock == system.dock,
                  "restart failures must remain visible and retain the surviving activation")
            system.restartError = nil
            controller.shutdown()
            check(system.restarts.count == 2 && system.activation == nil,
                  "failed cleanup must retain its target for retry on quit, then clear its activation")
        }
        if passed { print("InstantMinimizeControllerTests: all tests passed") }
        return passed
    }
}
