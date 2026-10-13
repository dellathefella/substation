// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SubstationDaemon",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.92.0"),
    ],
    targets: [
        .executableTarget(
            name: "substationd",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
