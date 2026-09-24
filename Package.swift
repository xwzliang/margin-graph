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
        .target(name: "MarginGraphCore", linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("AVKit")]),
        .executableTarget(name: "MarginGraphApp", dependencies: ["MarginGraphCore"], linkerSettings: [.linkedFramework("AVKit")]),
        .testTarget(name: "MarginGraphCoreTests", dependencies: ["MarginGraphCore"], linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("AVKit")])
    ]
)
