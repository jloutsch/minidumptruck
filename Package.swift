// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MiniDumpTruck",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MiniDumpTruck", targets: ["MiniDumpTruck"])
    ],
    targets: [
        .executableTarget(
            name: "MiniDumpTruck",
            path: "MacDumper",
            exclude: ["Info.plist"]
        )
    ]
)
