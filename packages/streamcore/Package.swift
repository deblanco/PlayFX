// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StreamCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        // Static library: linked into the Tauri binary (macOS) and later the Expo module (iOS).
        .library(name: "StreamCore", type: .static, targets: ["StreamCore"]),
    ],
    targets: [
        .target(name: "StreamCore"),
    ]
)
