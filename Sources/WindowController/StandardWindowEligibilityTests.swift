import Foundation
import ApplicationServices

/// Guardrail tests for the pure role/subrole eligibility decision used by `isStandardWindow`.
enum StandardWindowEligibilityTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("StandardWindowEligibilityTests: \(message)")
                allPassed = false
            }
        }

        let windowRole = kAXWindowRole as String
        let standardSubrole = kAXStandardWindowSubrole as String
        let dialogSubrole = kAXDialogSubrole as String
        let unknownRole = "AXUnknown"

        func rejection(
            roleReadable: Bool = true,
            role: String?,
            subroleReadable: Bool = true,
            subrole: String?,
            skipSubroleCheck: Bool = false,
            allowsNonStandardWindow: Bool = false
        ) -> WindowController.RoleSubroleRejection? {
            WindowController.roleSubroleRejection(
                roleReadable: roleReadable,
                role: role,
                subroleReadable: subroleReadable,
                subrole: subrole,
                skipSubroleCheck: skipSubroleCheck,
                allowsNonStandardWindow: allowsNonStandardWindow
            )
        }

        // Standard window passes.
        assert(rejection(role: windowRole, subrole: standardSubrole) == nil,
               "standard role + subrole should pass")

        // Non-standard role/subrole rejected by default.
        assert(rejection(role: unknownRole, subrole: standardSubrole) == .nonStandardRole(unknownRole),
               "non-standard role should be rejected by default")
        assert(rejection(role: windowRole, subrole: dialogSubrole) == .nonStandardSubrole(dialogSubrole),
               "non-standard subrole should be rejected by default")

        // manageNonStandardWindows relaxes both (the Adobe Premiere case: AXUnknown + AXDialog).
        assert(rejection(role: unknownRole, subrole: dialogSubrole, allowsNonStandardWindow: true) == nil,
               "manageNonStandardWindows should accept a non-standard role and subrole")

        // A failed role read is always rejected, even with the flag (Codex review finding).
        assert(rejection(roleReadable: false, role: nil, subrole: standardSubrole, allowsNonStandardWindow: true) == .roleUnreadable,
               "an unreadable role must be rejected even when managing non-standard windows")
        // A role attribute that isn't a string is likewise rejected.
        assert(rejection(role: nil, subrole: standardSubrole) == .roleUnreadable,
               "a non-string role must be rejected")

        // Minimized windows skip only the subrole check, never the role check.
        assert(rejection(role: windowRole, subrole: dialogSubrole, skipSubroleCheck: true) == nil,
               "minimized window should skip the subrole check")
        assert(rejection(role: unknownRole, subrole: dialogSubrole, skipSubroleCheck: true) == .nonStandardRole(unknownRole),
               "minimized window should still enforce the role check")

        // An unreadable subrole is non-fatal for an otherwise-standard window.
        assert(rejection(role: windowRole, subroleReadable: false, subrole: nil) == nil,
               "an unreadable subrole should not by itself reject a standard-role window")

        if allPassed {
            print("StandardWindowEligibilityTests: all tests passed")
        }
        return allPassed
    }
}
