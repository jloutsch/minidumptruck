// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MiniDumpTruck",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MiniDumpTruck", targets: ["MiniDumpTruck"]),
        .library(name: "MiniDumpTruckCore", targets: ["MiniDumpTruckCore"])
    ],
    targets: [
        // Core library for testing (non-UI code only)
        .target(
            name: "MiniDumpTruckCore",
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
        ),
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
        ),
        // Test target for core library
        .testTarget(
            name: "MiniDumpTruckTests",
            dependencies: ["MiniDumpTruckCore"],
            path: "Tests"
        )
    ]
)
