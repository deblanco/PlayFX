// swift-tools-version:5.9
import PackageDescription

// Static libchiaki + dependencies staged by scripts/build-chiaki.sh.
let vendorLib = Context.packageDirectory + "/vendor/macos/lib"
let chiakiLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L", vendorLib]),
    .linkedLibrary("chiaki"), .linkedLibrary("protobuf-nanopb"), .linkedLibrary("jerasure"),
    .linkedLibrary("gf_complete"), .linkedLibrary("curl"), .linkedLibrary("ssl"), .linkedLibrary("crypto"),
    .linkedLibrary("opus"), .linkedLibrary("json-c"), .linkedLibrary("miniupnpc"), .linkedLibrary("event"),
    .linkedLibrary("z"),
    .linkedFramework("CoreServices"), .linkedFramework("SystemConfiguration"), .linkedFramework("Security"),
]

let package = Package(
    name: "StreamCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        // Static library: linked into the Tauri binary (macOS) and later the Expo module (iOS).
        .library(name: "StreamCore", type: .static, targets: ["StreamCore"]),
        // Headless debugging tool: discover / register / stream with snapshots and remote input.
        .executable(name: "psrp", targets: ["psrp"]),
    ],
    targets: [
        // Thin C API over libchiaki (PS Remote Play protocol).
        .target(name: "CChiaki", linkerSettings: chiakiLinkerSettings),
        .target(name: "StreamCore", dependencies: ["CChiaki"]),
        .executableTarget(name: "psrp", dependencies: ["StreamCore"]),
    ]
)
