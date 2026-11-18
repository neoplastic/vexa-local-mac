// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VexaLocal",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "VexaCore", path: "Sources/VexaCore"),
        .executableTarget(name: "VexaLocal", dependencies: ["VexaCore"], path: "Sources/VexaLocal"),
        .testTarget(name: "VexaCoreTests", dependencies: ["VexaCore"], path: "Tests/VexaCoreTests"),
        .testTarget(name: "VexaLocalTests", dependencies: ["VexaLocal", "VexaCore"], path: "Tests/VexaLocalTests"),
    ]
)
