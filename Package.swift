// swift-tools-version:5.9
// Defines the app and developer tools, including metadata for unbundled debug runs.
import Foundation
import PackageDescription

let debugInfoPlistPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/DebugInfo.plist")
    .path

let package = Package(
    name: "Zonogy",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .executable(
            name: "Zonogy",
            targets: ["Zonogy"]
        ),
        // Dev-only test tool; never packaged into Zonogy.app (build.sh copies only the Zonogy binary).
        .executable(
            name: "unrulywin",
            targets: ["unrulywin"]
        ),
        .executable(
            name: "FullScreenLab",
            targets: ["FullScreenLab"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Zonogy",
            path: "Sources",
            linkerSettings: [
                // `swift run Zonogy` has no app bundle, so embed its AutoFill policy.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", debugInfoPlistPath
                ], .when(configuration: .debug))
            ]
        ),
        .executableTarget(
            name: "unrulywin",
            path: "TestTools/UnrulyWin"
        ),
        .executableTarget(
            name: "FullScreenLab",
            path: "TestTools/FullScreenLab",
            exclude: ["README.md", "Info.plist", "build.zsh"]
        )
    ]
)
