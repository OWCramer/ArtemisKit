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
        .target(name: "ArtemisKit", dependencies: ["CLua", "CVorbis"]),
        // Ogg Vorbis decoding (stb_vorbis); see Sources/CVorbis/README.md.
        .target(
            name: "CVorbis",
            exclude: ["README.md"],
            cSettings: [.unsafeFlags(["-w"])]
        ),
        // Lua 5.1.5 and Shiori's bridge for the engine's `e` object; see Sources/CLua/README.md.
        .target(
            name: "CLua",
            exclude: ["README.md", "COPYRIGHT"],
            cSettings: [.unsafeFlags(["-Wno-deprecated-declarations", "-Wno-shorten-64-to-32"])]
        ),
        // Developer tool: lists, extracts and inventories a game's archives from the Mac.
        .executableTarget(name: "artemis-cli", dependencies: ["ArtemisKit"]),
        .testTarget(name: "ArtemisKitTests", dependencies: ["ArtemisKit"]),
    ]
)
