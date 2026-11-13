// swift-tools-version: 6.0
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "DevDeck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DevDeck", targets: ["DevDeck"]),
    ],
    targets: [
        .target(name: "DevDeckCore", swiftSettings: swift5),
        .executableTarget(name: "DevDeck", dependencies: ["DevDeckCore"], swiftSettings: swift5),
        .testTarget(name: "DevDeckCoreTests", dependencies: ["DevDeckCore"], swiftSettings: swift5),
    ]
)
