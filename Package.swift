// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Loom",
    // Swift Testing toolchain baseline only; product deployment minimum is still undecided.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LoomCore", targets: ["LoomCore"]),
        .executable(name: "loom-probe", targets: ["loom-probe"]),
        .executable(name: "loom-test-child", targets: ["loom-test-child"]),
    ],
    targets: [
        .target(name: "CLoomPOSIX"),
        .target(name: "CLoomTestSupport"),
        .target(name: "LoomCore", dependencies: ["CLoomPOSIX"]),
        .executableTarget(name: "loom-probe", dependencies: ["LoomCore"]),
        .executableTarget(name: "loom-test-child", dependencies: ["CLoomTestSupport"]),
        .testTarget(name: "LoomCoreTests", dependencies: ["LoomCore"]),
    ]
)
