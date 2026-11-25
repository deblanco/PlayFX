// swift-tools-version:5.9
import PackageDescription

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
        // libopus v1.6.1 (BSD-3-Clause, vendored unmodified, float build, generic C on arm64 and x86_64): game audio
        // decode and microphone encode. Compiled here for the package's deployment targets. The defines are what
        // upstream's CMake sets by default (VLAs, lrint/lrintf, hardening; no float approximations), with intrinsics
        // off; PACKAGE_VERSION as its autotools and Meson builds set it (opus_get_version_string).
        .target(
            name: "CLibopus",
            exclude: ["COPYING", "README.PlayFX"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("celt"), .headerSearchPath("silk"), .headerSearchPath("silk/float"),
                .define("OPUS_BUILD"), .define("VAR_ARRAYS"), .define("HAVE_LRINT"), .define("HAVE_LRINTF"),
                .define("ENABLE_HARDENING"), .define("PACKAGE_VERSION", to: "\"1.6.1\""), .unsafeFlags(["-w"]),
            ]),
        // The libopus calls the PlayFX engine makes (game audio decode, microphone encode), over CLibopus.
        .target(name: "COpus", dependencies: ["CLibopus"]),
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
