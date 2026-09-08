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
            swiftSettings: [.swiftLanguageMode(.v6)],
            // Section 2.3: SQLite is preferred for explicit retention and batch
            // writes. Linking the system library rather than vendoring GRDB keeps
            // the dependency surface at zero, which Section 9 cares about.
            linkerSettings: [.linkedLibrary("sqlite3")]
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
