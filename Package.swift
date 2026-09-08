// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Runwell",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RunwellKit", targets: ["RunwellKit"]),
        .executable(name: "Runwell", targets: ["Runwell"]),
    ],
    targets: [
        .target(
            name: "RunwellKit",
            swiftSettings: [.swiftLanguageMode(.v6)],
            // Section 2.3: SQLite is preferred for explicit retention and batch
            // writes. Linking the system library rather than vendoring GRDB keeps
            // the dependency surface at zero, which Section 9 cares about.
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Runwell",
            dependencies: ["RunwellKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RunwellKitTests",
            dependencies: ["RunwellKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
