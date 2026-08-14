// swift-tools-version: 5.9
import PackageDescription

// The GUI app is SwiftUI-only. The manifest is compiled and run on the host, so
// this selects on the build machine: platforms without SwiftUI get the core
// library, the CLI, and the tests, and never see the app target at all.
#if canImport(SwiftUI)
let applePlatforms: [SupportedPlatform]? = [
    .macOS(.v14)
]
let guiProducts: [Product] = [
    .executable(name: "MiniDumpTruck", targets: ["MiniDumpTruck"])
]
let guiTargets: [Target] = [
    // Main executable app (depends on core library)
    .executableTarget(
        name: "MiniDumpTruck",
        dependencies: ["MiniDumpTruckCore"],
        path: "MiniDumpTruck",
        exclude: [
            "Info.plist",
            "MiniDumpTruck.entitlements",
            "Models",
            "Parsers",
            "Services",
            "Utilities"
        ],
        sources: [
            "MiniDumpTruckApp.swift",
            "MinidumpDocument.swift",
            "Views",
            "ViewModels"
        ]
    )
]
#else
let applePlatforms: [SupportedPlatform]? = nil
let guiProducts: [Product] = []
let guiTargets: [Target] = []
#endif

let package = Package(
    name: "MiniDumpTruck",
    platforms: applePlatforms,
    products: guiProducts + [
        .executable(name: "minidumptruck-cli", targets: ["MiniDumpTruckCLI"]),
        .library(name: "MiniDumpTruckCore", targets: ["MiniDumpTruckCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.7.0"),
        .package(url: "https://github.com/apple/swift-crypto", exact: "4.5.1")
    ],
    targets: [
        // System zlib, used for DEFLATE on every platform
        .systemLibrary(name: "CZlib", path: "CZlib"),
        // Core library for testing (non-UI code only)
        .target(
            name: "MiniDumpTruckCore",
            dependencies: [
                "CZlib",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "MiniDumpTruck",
            exclude: [
                "Info.plist",
                "MiniDumpTruck.entitlements",
                "MiniDumpTruckApp.swift",
                "MinidumpDocument.swift",
                "Views",
                "ViewModels"
            ],
            sources: [
                "Models",
                "Parsers",
                "Services",
                "Utilities"
            ]
        )
    ] + guiTargets + [
        // CLI tool
        .executableTarget(
            name: "MiniDumpTruckCLI",
            dependencies: [
                "MiniDumpTruckCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "CLI"
        ),
        // Test target for core library
        .testTarget(
            name: "MiniDumpTruckTests",
            dependencies: ["MiniDumpTruckCore", "CZlib"],
            path: "Tests"
        )
    ]
)
