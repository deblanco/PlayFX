fn main() {
    // Compile and link the shared Swift core (Metal + MetalFX) on macOS.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        swift_rs::SwiftLinker::new("13.0")
            .with_package("StreamCore", "../../../packages/streamcore")
            .link();
    }
    tauri_build::build()
}
