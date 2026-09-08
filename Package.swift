// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PowerTask",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PowerTaskKit", targets: ["PowerTaskKit"]),
        .executable(name: "PowerTask", targets: ["PowerTask"]),
    ],
    targets: [
        .target(
            name: "PowerTaskKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "PowerTask",
            dependencies: ["PowerTaskKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PowerTaskKitTests",
            dependencies: ["PowerTaskKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
