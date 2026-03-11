import AppKit

/// Parses pasteboard content from external drag-and-drop gestures into normalized URL payloads.
struct ExternalDropItem: Hashable {
    let url: URL
}

struct ExternalDropPayload {
    let items: [ExternalDropItem]

    var isEmpty: Bool { items.isEmpty }
}

enum ExternalDropParser {
    static let registeredPasteboardTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .URL,
        .string
    ]

    static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else {
            return false
        }

        if types.contains(.fileURL) || types.contains(.URL) {
            return true
        }

        if types.contains(.string),
           let stringValue = pasteboard.string(forType: .string),
           parseLaunchableURL(from: stringValue) != nil {
            return true
        }

        return false
    }

    static func canAccept(_ draggingInfo: NSDraggingInfo) -> Bool {
        canAccept(draggingInfo.draggingPasteboard)
    }

    static func payload(from pasteboard: NSPasteboard) -> ExternalDropPayload? {
        var discovered: [URL] = []

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: false
        ]) as? [URL] {
            discovered.append(contentsOf: urls)
        }

        if let stringValue = pasteboard.string(forType: .string),
           let parsed = parseLaunchableURL(from: stringValue) {
            discovered.append(parsed)
        }

        let unique = uniqueNormalized(discovered)
        guard !unique.isEmpty else {
            return nil
        }

        let items = unique.map { ExternalDropItem(url: $0) }
        return ExternalDropPayload(items: items)
    }

    static func payload(from draggingInfo: NSDraggingInfo) -> ExternalDropPayload? {
        payload(from: draggingInfo.draggingPasteboard)
    }

    private static func parseURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    private static func parseLaunchableURL(from rawValue: String) -> URL? {
        guard let url = parseURL(from: rawValue) else {
            return nil
        }
        guard canOpen(url) else {
            return nil
        }
        return url
    }

    private static func canOpen(_ url: URL) -> Bool {
        if url.isFileURL {
            return true
        }
        return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    private static func uniqueNormalized(_ urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        var result: [URL] = []

        for url in urls {
            if seen.insert(url).inserted {
                result.append(url)
            }
        }

        return result
    }
}
