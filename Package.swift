// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zonogy",
    platforms: [
        .macOS(.v14)
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
        )
    ],
    targets: [
        .executableTarget(
            name: "Zonogy",
            path: "Sources"
        ),
        .executableTarget(
            name: "unrulywin",
            path: "TestTools/UnrulyWin"
        )
    ]
)
