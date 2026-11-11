/// Locates the files Zonogy ships with. They sit in the app bundle's Resources folder; an unbundled debug run
/// (`swift run`) finds them in the repository's Resources folder instead.
import Foundation

enum BundledResource {
    /// Path of the resource `name`: a file name, or a path below Resources such as "Tour/zones.svg".
    /// Nil if no copy of it exists.
    static func path(_ name: String) -> String? {
        let executableDirectory = (ProcessInfo.processInfo.arguments[0] as NSString).deletingLastPathComponent
        let candidates = [
            // Resources directory relative to working directory (for development)
            "Resources/\(name)",
            // Resources directory relative to executable (for deployed binary)
            executableDirectory + "/../Resources/\(name)",
            // Same directory as executable
            executableDirectory + "/\(name)",
        ]
        return candidates.lazy
            .map { ($0 as NSString).standardizingPath }
            .first { FileManager.default.fileExists(atPath: $0) }
    }
}
