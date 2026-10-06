// swift-tools-version:6.2
// LOOM VENDOR: reduced from upstream SwiftTerm fe4fb45d5888ce33ff3788d6873870a73894a41b
// (see LOOM-VENDOR.md). Only the library, its build-info plugin and generator
// are kept; the target settings below are unchanged from upstream.

import PackageDescription

let graphicsDependencies: [Target.Dependency] = [
    .product(
        name: "PNG",
        package: "swift-png",
        condition: .when(platforms: [.linux, .windows, .wasi], traits: ["PortableGraphics"])
    ),
    .product(
        name: "LZ77",
        package: "swift-png",
        condition: .when(platforms: [.linux, .windows, .wasi], traits: ["PortableGraphics"])
    ),
]

let portableTraitSettings: [SwiftSetting] = [
    .define("SWIFTTERM_EMBEDDED", .when(traits: ["Embedded"])),
    .enableExperimentalFeature("Embedded", .when(traits: ["Embedded"])),
    .define("SWIFTTERM_WASM", .when(traits: ["Wasm"])),
]

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    traits: [
        .default(enabledTraits: ["PortableGraphics"]),
        .trait(name: "PortableGraphics", description: "PNG and zlib decoders for the full non-Apple core"),
        .trait(
            name: "Embedded",
            description: "Foundation-free portable core for Embedded Swift"
        ),
        .trait(
            name: "Wasm",
            description: "Full WASI core with Foundation and graphics; use Embedded separately for the reduced core",
            enabledTraits: ["PortableGraphics"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/tayloraswift/swift-png", from: "4.5.0"),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            dependencies: graphicsDependencies,
            path: "Sources/SwiftTerm",
            exclude: [
                "Mac/README.md",
                "Apple/Metal/Shaders.metal",
            ],
            swiftSettings: portableTraitSettings,
            plugins: [
                .plugin(name: "SwiftTermBuildInfoPlugin")
            ]
        ),
        .executableTarget(
            name: "SwiftTermBuildInfoGenerator",
            path: "Sources/SwiftTermBuildInfoGenerator"
        ),
        .plugin(
            name: "SwiftTermBuildInfoPlugin",
            capability: .buildTool(),
            dependencies: ["SwiftTermBuildInfoGenerator"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
