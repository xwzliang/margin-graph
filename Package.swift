// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MarginGraph",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarginGraphCore", targets: ["MarginGraphCore"]),
        .executable(name: "MarginGraphApp", targets: ["MarginGraphApp"])
    ],
    targets: [
        .target(name: "MarginGraphCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "MarginGraphApp", dependencies: ["MarginGraphCore"]),
        .testTarget(name: "MarginGraphCoreTests", dependencies: ["MarginGraphCore"], linkerSettings: [.linkedLibrary("sqlite3")])
    ]
)
