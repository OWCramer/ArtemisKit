// swift-tools-version: 6.0
// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import PackageDescription

let package = Package(
    name: "ArtemisKit",
    platforms: [.iOS(.v18), .macOS(.v15), .tvOS(.v18)],
    products: [
        .library(name: "ArtemisKit", targets: ["ArtemisKit"]),
        .executable(name: "artemis-cli", targets: ["artemis-cli"]),
    ],
    targets: [
        .target(name: "ArtemisKit", dependencies: ["CLua", "CVorbis", "CVideo"]),
        // Ogg Theora (libogg + libtheora) and MPEG-1 (pl_mpeg) decoding; see Sources/CVideo/README.md.
        .target(
            name: "CVideo",
            exclude: ["README.md", "ogg/COPYING", "theora/COPYING"],
            cSettings: [.headerSearchPath("theora")]
        ),
        // Ogg Vorbis decoding (stb_vorbis); see Sources/CVorbis/README.md.
        .target(
            name: "CVorbis",
            exclude: ["README.md"],
            cSettings: []
        ),
        // Lua 5.1.5 and Shiori's bridge for the engine's `e` object; see Sources/CLua/README.md.
        .target(
            name: "CLua",
            exclude: ["README.md", "COPYRIGHT"],
            cSettings: []
        ),
        // Developer tool: lists, extracts and inventories a game's archives from the Mac.
        .executableTarget(name: "artemis-cli", dependencies: ["ArtemisKit"]),
        .testTarget(name: "ArtemisKitTests", dependencies: ["ArtemisKit"]),
    ]
)
