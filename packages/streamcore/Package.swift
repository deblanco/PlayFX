// swift-tools-version:5.9
import Foundation
import PackageDescription

// libopus (BSD-3-Clause), linked statically from Homebrew's opus keg (`brew install opus`): the PlayFX engine's game
// audio decode and microphone encode. `OPUS_PREFIX` names the keg (the desktop app's build.rs sets it from
// `brew --prefix opus`); otherwise Homebrew's usual prefixes are tried. The archive is linked by its path, never
// `-lopus`, so a dynamic libopus next to it can't be picked instead.
let opusPrefix = Context.environment["OPUS_PREFIX"]
    ?? ["/opt/homebrew/opt/opus", "/usr/local/opt/opus"]
        .first { FileManager.default.fileExists(atPath: $0 + "/lib/libopus.a") }
    ?? "/opt/homebrew/opt/opus"

let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

let package = Package(
    name: "StreamCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        // Static library: linked into the Tauri binary (macOS) and later the Expo module (iOS).
        .library(name: "StreamCore", type: .static, targets: ["StreamCore"]),
        // Headless debugging tool: discover / register / stream with snapshots and remote input.
        .executable(name: "psrp", targets: ["psrp"]),
    ],
    dependencies: [
        // PlayFX's own Remote Play protocol implementation, which PlayFXEngine runs on.
        .package(path: "../playfxprotocol"),
    ],
    targets: [
        // Catches Objective-C exceptions thrown inside framework calls, which Swift can't.
        .target(name: "CObjCCatch"),
        // The libopus calls the PlayFX engine makes (game audio decode, microphone encode), over the static libopus.
        .target(
            name: "COpus",
            cSettings: [.unsafeFlags(["-I", opusPrefix + "/include/opus"])],
            linkerSettings: [.unsafeFlags([opusPrefix + "/lib/libopus.a"])]),
        .target(
            name: "StreamCore",
            dependencies: ["CObjCCatch", "COpus", .product(name: "PlayFXProtocol", package: "playfxprotocol")]),
        .executableTarget(name: "psrp", dependencies: ["StreamCore"]),
        // swift-testing ships with the Command Line Tools as a framework outside the default search
        // paths, and its Foundation cross-import overlay has no module there, so overlays are off.
        .testTarget(
            name: "StreamCoreTests",
            dependencies: [
                "StreamCore", "CObjCCatch", "COpus",
                .product(name: "PlayFXProtocol", package: "playfxprotocol"),
                .product(name: "PlayFXProtocolTestSupport", package: "playfxprotocol"),
            ],
            swiftSettings: [.unsafeFlags(["-F", cltFrameworks, "-Xfrontend", "-disable-cross-import-overlays"])],
            linkerSettings: [.unsafeFlags(["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks])]),
    ]
)
