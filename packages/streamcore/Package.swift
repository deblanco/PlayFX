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

let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

// SwiftPM only instruments Swift for coverage; scripts/coverage.sh sets this to measure the C shim too.
// Never set for builds that are linked elsewhere (the instrumented objects need the profile runtime).
let cCoverage: [CSetting] = Context.environment["STREAMCORE_C_COVERAGE"] == "1"
    ? [.unsafeFlags(["-fprofile-instr-generate", "-fcoverage-mapping"])] : []

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
        .target(name: "CChiaki", cSettings: cCoverage, linkerSettings: chiakiLinkerSettings),
        // Catches Objective-C exceptions thrown inside framework calls, which Swift can't.
        .target(name: "CObjCCatch"),
        .target(name: "StreamCore", dependencies: ["CChiaki", "CObjCCatch"]),
        .executableTarget(name: "psrp", dependencies: ["StreamCore"]),
        // swift-testing ships with the Command Line Tools as a framework outside the default search
        // paths, and its Foundation cross-import overlay has no module there, so overlays are off.
        .testTarget(
            name: "StreamCoreTests", dependencies: ["StreamCore", "CChiaki", "CObjCCatch"],
            swiftSettings: [.unsafeFlags(["-F", cltFrameworks, "-Xfrontend", "-disable-cross-import-overlays"])],
            linkerSettings: [.unsafeFlags(["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks])]),
    ]
)
