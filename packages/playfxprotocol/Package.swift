// swift-tools-version:6.0
import PackageDescription

let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

let package = Package(
    name: "PlayFXProtocol",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "PlayFXProtocol", targets: ["PlayFXProtocol"]),
        // The fake console (session init, ctrl, probe and stream over loopback) and the helpers it needs, shared by
        // this package's tests and StreamCore's. Test code only: it imports PlayFXProtocol with `@testable`, so it
        // builds in debug (or with `-enable-testing`), and nothing ships it.
        .library(name: "PlayFXProtocolTestSupport", targets: ["PlayFXProtocolTestSupport"]),
        // Drives the package against a real console, side by side with psrp (libchiaki).
        .executable(name: "pfxp", targets: ["pfxp"]),
    ],
    targets: [
        // libsecp256k1 v0.8.0 (MIT, vendored unmodified, core + ECDH only): the stream handshake's ECDH.
        .target(
            name: "CSecp256k1",
            exclude: ["COPYING", "README.PlayFX"],
            sources: ["src/secp256k1.c", "src/precomputed_ecmult.c", "src/precomputed_ecmult_gen.c"],
            publicHeadersPath: "include",
            cSettings: [.define("ENABLE_MODULE_ECDH", to: "1"), .unsafeFlags(["-w"])]),
        .target(name: "PlayFXProtocol", dependencies: ["CSecp256k1"]),
        .executableTarget(name: "pfxp", dependencies: ["PlayFXProtocol"]),
        .target(
            name: "PlayFXProtocolTestSupport", dependencies: ["PlayFXProtocol"],
            resources: [.copy("Fixtures")]),
        // swift-testing ships with the Command Line Tools as a framework outside the default search
        // paths, and its Foundation cross-import overlay has no module there, so overlays are off.
        .testTarget(
            name: "PlayFXProtocolTests", dependencies: ["PlayFXProtocol", "PlayFXProtocolTestSupport"],
            swiftSettings: [.unsafeFlags(["-F", cltFrameworks, "-Xfrontend", "-disable-cross-import-overlays"])],
            linkerSettings: [.unsafeFlags(["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks])]),
    ]
)
