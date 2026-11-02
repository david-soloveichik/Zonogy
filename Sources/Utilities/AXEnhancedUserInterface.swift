/// Frame writes to windows of an application whose `AXEnhancedUserInterface` attribute is on. While
/// it is on, macOS animates the writes, which can also leave a window at the wrong frame. Assistive
/// applications such as VoiceOver turn it on, and Firefox turns it on itself whenever an Accessibility
/// client asks for its application role, so it is checked before every write rather than turned off
/// once.

import ApplicationServices

enum AXEnhancedUserInterface {
    private static let attribute = "AXEnhancedUserInterface" as CFString

    /// Runs `writes`, which move or resize `window`, with its application's `AXEnhancedUserInterface`
    /// off, turning it back on afterward if it was on, so assistive applications keep working. When it
    /// is already off, this costs one request to the application.
    static func whileOff(for window: AXUIElement, _ writes: () -> Void) {
        var pid: pid_t = 0
        var value: CFTypeRef?
        guard AXUIElementGetPid(window, &pid) == .success else {
            writes()
            return
        }
        let application = AXUIElementCreateApplication(pid)
        guard AXCall.copyAttribute(application, attribute, &value) == .success,
              value as? Bool == true else {
            writes()
            return
        }
        AXCall.setAttribute(application, attribute, kCFBooleanFalse)
        writes()
        AXCall.setAttribute(application, attribute, kCFBooleanTrue)
    }
}
