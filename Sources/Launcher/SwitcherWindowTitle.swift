import ApplicationServices
import Foundation

/// Resolves the user-facing title shown for a managed window in the switcher surfaces
/// (Launcher drill-down, DockMenus hover panel, CmdTab), and owns the accessibility reads
/// that feed it so every surface stays consistent.
///
/// Resolution precedence:
/// 1. the window's own title (with a redundant trailing app-name suffix stripped),
/// 2. the open document's filename (from `AXDocument`) when the window has no title of its own,
/// 3. the app name, then a generic label.
///
/// Zonogy manages windows with empty titles (see the window-management criteria), so those
/// windows must still resolve to something visible and selectable rather than being hidden.
enum SwitcherWindowTitle {
    /// Separators an app may place before its own name inside a window title (e.g. "Doc — App").
    /// Handles hyphen (-), en-dash (–), em-dash (—), and pipe (|).
    private static let appNameSeparators = [" - ", " – ", " — ", " | "]

    /// Reads the relevant accessibility attributes from `element` and resolves the display title.
    /// The `AXDocument` read is performed lazily — only when the window has no usable title of its
    /// own — so the common (titled) case costs a single AX call.
    static func resolve(for element: AXUIElement, appName: String?) -> String {
        display(
            rawTitle: stringAttribute(element, kAXTitleAttribute as CFString) ?? "",
            appName: appName,
            documentPath: { stringAttribute(element, kAXDocumentAttribute as CFString) }
        )
    }

    /// Pure precedence logic (testable). `documentPath` is a closure so callers can defer the
    /// (impure) `AXDocument` read until the title is known to be unusable.
    /// - Returns: a non-empty display title whenever any source is available.
    static func display(
        rawTitle: String,
        appName: String?,
        documentPath: () -> String?
    ) -> String {
        let stripped = strippingAppNameSuffix(rawTitle, appName: appName)
        if !stripped.isEmpty {
            return stripped
        }

        if let path = documentPath(), let filename = documentFilename(fromDocument: path) {
            return filename
        }

        if let appName, !appName.isEmpty {
            return appName
        }
        return "Window"
    }

    /// Strips a redundant trailing " <sep> AppName" suffix (e.g. "Notes — Texifier" -> "Notes").
    static func strippingAppNameSuffix(_ title: String, appName: String?) -> String {
        guard let appName, !appName.isEmpty else {
            return title
        }
        for separator in appNameSeparators {
            let suffix = separator + appName
            if title.hasSuffix(suffix) {
                return String(title.dropLast(suffix.count))
            }
        }
        return title
    }

    /// Extracts a display filename from an `AXDocument` value, which is typically a `file://` URL
    /// string (percent-encoded) but may be a plain POSIX path.
    static func documentFilename(fromDocument document: String) -> String? {
        let trimmed = document.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let url = trimmed.contains("://") ? URL(string: trimmed) : URL(fileURLWithPath: trimmed)
        guard let name = url?.lastPathComponent, !name.isEmpty, name != "/" else {
            return nil
        }
        return name
    }

    /// Reads a string-valued AX attribute, returning `nil` for missing, non-string, or empty values.
    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXCall.copyAttribute(element, attribute, &value) == .success,
              let string = value as? String,
              !string.isEmpty else {
            return nil
        }
        return string
    }
}
