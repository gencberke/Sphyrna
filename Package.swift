// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Loom",
    // Accepted product minimum (contract §3, 28 September 2026).
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "LoomCore", targets: ["LoomCore"]),
        .library(name: "LoomChat", targets: ["LoomChat"]),
        .executable(name: "loom-app", targets: ["loom-app"]),
        .executable(name: "loom-catalog-fixture", targets: ["loom-catalog-fixture"]),
        .executable(name: "loom-hook", targets: ["loom-hook"]),
        .executable(name: "loom-run-host", targets: ["loom-run-host"]),
        .executable(name: "loom-probe", targets: ["loom-probe"]),
        .executable(name: "loom-test-child", targets: ["loom-test-child"]),
        .executable(name: "loom-fake-provider", targets: ["loom-fake-provider"]),
    ],
    dependencies: [
        // Pinned revision (plans/CHECKPOINT-5-HISTORY.md §3.1) plus Loom's local patches; see Vendor/SwiftTerm/LOOM-VENDOR.md.
        .package(path: "Vendor/SwiftTerm"),
    ],
    targets: [
        .target(name: "CLoomPOSIX", linkerSettings: [.linkedLibrary("bsm")]),
        .target(name: "CLoomTestSupport"),
        .target(name: "LoomCore", dependencies: ["CLoomPOSIX"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "LoomTerminal", dependencies: [
            "LoomCore", .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),
        .target(name: "LoomCatalogUI", dependencies: ["LoomCore", "LoomTerminal", "LoomChat"]),
        // The chat engine's pure model and wire protocol (v2): no UI, no process spawning.
        .target(name: "LoomChat", dependencies: ["LoomCore"]),
        // Remora's call (v2): one owned `claude -p` child per question or brief and its answer. No UI.
        .target(name: "LoomRemora", dependencies: ["LoomCore", "LoomChat"]),
        // Pure launch-option rules (data root, evidence channel), testable without AppKit.
        .target(name: "LoomLaunchOptions"),
        // LOOM_EVIDENCE compiles Sources/loom-app/Evidence (acceptance tooling) into the development flavor only;
        // the release manifest and the clean loom tree have neither the define nor that directory.
        .executableTarget(name: "loom-app", dependencies: ["LoomCore", "LoomTerminal", "LoomCatalogUI", "LoomLaunchOptions"],
                          swiftSettings: [.define("LOOM_EVIDENCE")]),
        // Development/acceptance only: writes an isolated catalog. Never bundled.
        .executableTarget(name: "loom-catalog-fixture", dependencies: ["LoomCore"]),
        .executableTarget(name: "loom-hook", dependencies: ["LoomCore"]),
        // Bundled as Contents/Helpers/LoomRunHost.app; one instance per run scope.
        .executableTarget(name: "loom-run-host", dependencies: ["CLoomPOSIX"], linkerSettings: [
            .linkedFramework("Security"), .linkedFramework("CoreFoundation"),
        ]),
        .executableTarget(name: "loom-probe", dependencies: ["LoomCore"]),
        .executableTarget(name: "loom-test-child", dependencies: ["CLoomTestSupport"]),
        // Development/test only: a provider-shaped terminal fixture. Never bundled.
        .executableTarget(name: "loom-fake-provider"),
        .testTarget(name: "LoomCoreTests", dependencies: ["LoomCore"]),
        .testTarget(name: "LoomTerminalTests", dependencies: ["LoomCore", "LoomTerminal"]),
        .testTarget(name: "LoomChatTests", dependencies: ["LoomChat", "LoomCore"]),
        .testTarget(name: "LoomRemoraTests", dependencies: ["LoomRemora", "LoomChat", "LoomCore"]),
        .testTarget(name: "LoomLaunchOptionsTests", dependencies: ["LoomLaunchOptions"]),
        .testTarget(name: "LoomCatalogUITests", dependencies: ["LoomCore", "LoomTerminal", "LoomCatalogUI", "LoomChat"]),
    ]
)
