// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Unarchive",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Unarchive",
            path: "Sources/Entpacker",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        )
    ]
)
