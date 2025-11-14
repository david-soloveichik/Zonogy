// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zonogy",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "Zonogy",
            targets: ["Zonogy"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Zonogy",
            path: "Sources"
        )
    ]
)
