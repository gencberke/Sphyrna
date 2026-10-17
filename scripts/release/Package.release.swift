// swift-tools-version: 6.2
// Release manifest of the clean loom tree. GENERATED from loom-dev
// (scripts/release/Package.release.swift); do not edit by hand. Product targets
// only; every target declaration below is identical to the loom-dev manifest
// (promote.sh checks this), so behavior and build settings match the tested tree.
import PackageDescription

let package = Package(
    name: "Loom",
    // Accepted product minimum (contract §3, 28 September 2026).
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "loom-app", targets: ["loom-app"]),
        .executable(name: "loom-hook", targets: ["loom-hook"]),
        .executable(name: "loom-run-host", targets: ["loom-run-host"]),
    ],
    dependencies: [
        .package(path: "Vendor/SwiftTerm"),
    ],
    targets: [
        .target(name: "CLoomPOSIX", linkerSettings: [.linkedLibrary("bsm")]),
        .target(name: "LoomCore", dependencies: ["CLoomPOSIX"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "LoomTerminal", dependencies: [
            "LoomCore", .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),
        .target(name: "LoomCatalogUI", dependencies: ["LoomCore", "LoomTerminal"]),
        .target(name: "LoomChat", dependencies: ["LoomCore"]),
        .target(name: "LoomLaunchOptions"),
        .executableTarget(name: "loom-app", dependencies: ["LoomCore", "LoomTerminal", "LoomCatalogUI", "LoomLaunchOptions"]),
        .executableTarget(name: "loom-hook", dependencies: ["LoomCore"]),
        .executableTarget(name: "loom-run-host", dependencies: ["CLoomPOSIX"], linkerSettings: [
            .linkedFramework("Security"), .linkedFramework("CoreFoundation"),
        ]),
    ]
)
