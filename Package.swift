// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArtemisKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ArtemisKit", targets: ["ArtemisKit"]),
        .executable(name: "artemis-cli", targets: ["artemis-cli"]),
    ],
    targets: [
        .target(name: "ArtemisKit"),
        // Developer tool: lists, extracts and inventories a game's archives from the Mac.
        .executableTarget(name: "artemis-cli", dependencies: ["ArtemisKit"]),
        .testTarget(name: "ArtemisKitTests", dependencies: ["ArtemisKit"]),
    ]
)
