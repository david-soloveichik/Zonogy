// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LatticeTopology",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "LatticeTopology",
            targets: ["LatticeTopology"]
        )
    ],
    targets: [
        .executableTarget(
            name: "LatticeTopology",
            path: "Sources"
        )
    ]
)
