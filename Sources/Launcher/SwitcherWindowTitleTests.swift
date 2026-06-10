import Foundation

/// Guardrail tests for `SwitcherWindowTitle`.
enum SwitcherWindowTitleTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("SwitcherWindowTitleTests: \(message)")
                allPassed = false
            }
        }

        // Convenience: resolve with an optional document path (defaults to none).
        func resolve(rawTitle: String, appName: String?, document: String? = nil) -> String {
            SwitcherWindowTitle.display(rawTitle: rawTitle, appName: appName, documentPath: { document })
        }

        // A real title passes through unchanged, and the document is NOT consulted (lazy read).
        var documentConsulted = false
        let titled = SwitcherWindowTitle.display(rawTitle: "Notes.tex", appName: "Texifier") {
            documentConsulted = true
            return "file:///Users/me/other.tex"
        }
        assert(titled == "Notes.tex", "a plain title should pass through unchanged")
        assert(documentConsulted == false, "the document read must be skipped when a title is present")

        // A redundant trailing app-name suffix is stripped for each supported separator.
        assert(resolve(rawTitle: "Inbox - Mail", appName: "Mail") == "Inbox", "hyphen app-name suffix should be stripped")
        assert(resolve(rawTitle: "Doc – Pages", appName: "Pages") == "Doc", "en-dash app-name suffix should be stripped")
        assert(resolve(rawTitle: "Inbox — Mail", appName: "Mail") == "Inbox", "em-dash app-name suffix should be stripped")
        assert(resolve(rawTitle: "Project | Slack", appName: "Slack") == "Project", "pipe app-name suffix should be stripped")

        // The app name is only stripped as a trailing separated suffix, not mid-title.
        assert(resolve(rawTitle: "Mail merge", appName: "Mail") == "Mail merge", "app name should only strip as a trailing suffix")

        // Empty title -> the open document's filename (file URL, plain path, percent-encoded).
        assert(
            resolve(rawTitle: "", appName: "Texifier", document: "file:///Users/me/thesis.tex") == "thesis.tex",
            "empty title should use the document filename from a file URL"
        )
        assert(
            resolve(rawTitle: "", appName: "Texifier", document: "/Users/me/report.tex") == "report.tex",
            "empty title should use the document filename from a POSIX path"
        )
        assert(
            resolve(rawTitle: "", appName: "Texifier", document: "file:///Users/me/My%20Paper.tex") == "My Paper.tex",
            "document filename should be percent-decoded"
        )

        // Empty title, no usable document -> app name, then a generic label.
        assert(resolve(rawTitle: "", appName: "Texifier") == "Texifier", "empty title with no document should fall back to the app name")
        assert(
            resolve(rawTitle: "", appName: "Texifier", document: "file:///") == "Texifier",
            "a document path with no filename should fall back to the app name"
        )
        assert(resolve(rawTitle: "", appName: nil) == "Window", "empty title, no document, no app name should use a generic fallback")
        assert(resolve(rawTitle: "", appName: "") == "Window", "empty title, empty app name, no document should use a generic fallback")

        // A title that is exactly the app-name suffix empties on strip, then falls to the document.
        assert(
            resolve(rawTitle: " - Mail", appName: "Mail", document: "file:///Users/me/draft.eml") == "draft.eml",
            "a title that is only the suffix should fall through to the document filename"
        )

        // documentFilename parses URL strings and plain paths, and rejects blank input.
        assert(SwitcherWindowTitle.documentFilename(fromDocument: "file:///a/b/c.txt") == "c.txt", "documentFilename should parse a file URL")
        assert(SwitcherWindowTitle.documentFilename(fromDocument: "/a/b/c.txt") == "c.txt", "documentFilename should parse a POSIX path")
        assert(SwitcherWindowTitle.documentFilename(fromDocument: "   ") == nil, "documentFilename should reject blank input")

        if allPassed {
            print("SwitcherWindowTitleTests: all tests passed")
        }
        return allPassed
    }
}
