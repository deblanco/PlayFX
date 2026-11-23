// swift-tools-version:6.0
import PackageDescription

let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

let package = Package(
    name: "PlayFXProtocol",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "PlayFXProtocol", targets: ["PlayFXProtocol"]),
    ],
    targets: [
        .target(name: "PlayFXProtocol"),
        // swift-testing ships with the Command Line Tools as a framework outside the default search
        // paths, and its Foundation cross-import overlay has no module there, so overlays are off.
        .testTarget(
            name: "PlayFXProtocolTests", dependencies: ["PlayFXProtocol"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.unsafeFlags(["-F", cltFrameworks, "-Xfrontend", "-disable-cross-import-overlays"])],
            linkerSettings: [.unsafeFlags(["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks])]),
    ]
)
