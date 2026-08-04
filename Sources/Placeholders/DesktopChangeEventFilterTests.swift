import CoreServices
import Foundation

/// Simple assertions for DesktopChangeWatchService's FSEvents relevance filter.
enum DesktopChangeEventFilterTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        let desktop = "/Users/me/Desktop"
        func assertRelevance(_ expected: Bool, path: String, flags: Int, label: String) {
            let actual = DesktopChangeWatchService.isIconRelevantEvent(
                path: path,
                flags: FSEventStreamEventFlags(flags),
                desktopPath: desktop
            )
            if actual != expected {
                print("DesktopChangeEventFilterTests: \(label) failed (expected \(expected), got \(actual))")
                allPassed = false
            }
        }

        // Direct children of the Desktop are icons: entry changes are relevant.
        assertRelevance(true, path: "\(desktop)/file.txt", flags: kFSEventStreamEventFlagItemCreated, label: "direct-child-created")
        assertRelevance(true, path: "\(desktop)/file.txt", flags: kFSEventStreamEventFlagItemRemoved, label: "direct-child-removed")
        assertRelevance(true, path: "\(desktop)/Folder", flags: kFSEventStreamEventFlagItemRenamed, label: "direct-child-renamed")
        // A trailing slash on a delivered directory path does not defeat the direct-child check.
        assertRelevance(true, path: "\(desktop)/Folder/", flags: kFSEventStreamEventFlagItemCreated, label: "direct-child-trailing-slash")

        // Activity deeper in the subtree (e.g. a project folder living on the Desktop)
        // cannot move an icon.
        assertRelevance(false, path: "\(desktop)/Project/build/out.o", flags: kFSEventStreamEventFlagItemCreated, label: "nested-created")
        assertRelevance(false, path: "\(desktop)/Project/src/main.swift", flags: kFSEventStreamEventFlagItemRenamed, label: "nested-renamed")

        // The root .DS_Store carries icon positions; nested ones belong to other folders.
        assertRelevance(true, path: "\(desktop)/.DS_Store", flags: kFSEventStreamEventFlagItemModified, label: "root-ds-store")
        assertRelevance(false, path: "\(desktop)/Project/.DS_Store", flags: kFSEventStreamEventFlagItemModified, label: "nested-ds-store")

        // Content saves of documents that merely live on the Desktop are irrelevant.
        assertRelevance(false, path: "\(desktop)/notes.txt", flags: kFSEventStreamEventFlagItemModified, label: "direct-child-content-modified")

        // The Desktop directory itself changing (without entry flags) is not an icon change.
        assertRelevance(false, path: desktop, flags: kFSEventStreamEventFlagItemModified, label: "root-itself-modified")

        // Dropped events force a conservative refresh regardless of path.
        assertRelevance(true, path: "\(desktop)/Project/build", flags: kFSEventStreamEventFlagMustScanSubDirs, label: "must-scan-subdirs")

        if allPassed {
            print("DesktopChangeEventFilterTests: all tests passed")
        }
        return allPassed
    }
}
