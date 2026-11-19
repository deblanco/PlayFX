fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        link_streamcore();
    }
    // The app's own commands are access-controlled like plugin ones: only windows granted them (the main
    // window, capabilities/default.json) can call them. The PSN sign-in window shows Sony's site and must
    // never reach secret_get or start_stream.
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(&[
        "discover",
        "register_console",
        "wakeup",
        "psn_login",
        "start_stream",
        "stop_stream",
        "sleep_console",
        "set_login_pin",
        "set_controller",
        "set_pointer_touch",
        "keyboard_set_text",
        "keyboard_done",
        "set_microphone",
        "secret_get",
        "audio_devices",
        "peer_wifi_status",
        "set_peer_wifi_paused",
        "set_audio_output",
        "secret_set",
        "secret_remove",
        "set_render_params",
        "toggle_fullscreen",
        "psn_signed_in",
        "psn_consoles",
        "psn_sign_out",
        "set_detailed_logs",
        "open_logs_folder",
        "open_source_code",
        "diagnostics",
        "renderer_status",
    ])))
    .expect("tauri build");
}

/// Compiles and links the shared Swift core (Metal/MetalFX renderer + libchiaki session).
fn link_streamcore() {
    let pkg = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../packages/streamcore");
    let vendor = pkg.join("vendor/macos/lib");
    if !vendor.join("libchiaki.a").exists() {
        panic!("libchiaki not built: run packages/streamcore/scripts/build-chiaki.sh");
    }

    swift_rs::SwiftLinker::new("13.0").with_package("StreamCore", &pkg).link();

    // A static Swift library doesn't carry its link settings; repeat Package.swift's here.
    println!("cargo:rustc-link-search=native={}", vendor.display());
    for lib in [
        "chiaki", "protobuf-nanopb", "jerasure", "gf_complete", "curl", "ssl", "crypto", "opus", "json-c",
        "miniupnpc", "event",
    ] {
        println!("cargo:rustc-link-lib=static={lib}");
    }
    println!("cargo:rustc-link-lib=z");
    // Swift runtime (libswift_Concurrency etc.) ships with macOS under /usr/lib/swift.
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    for fw in [
        "CoreServices", "SystemConfiguration", "Security", "Metal", "MetalKit", "MetalFX", "QuartzCore",
        "VideoToolbox", "CoreMedia", "CoreVideo", "AVFoundation", "GameController", "CoreImage",
    ] {
        println!("cargo:rustc-link-lib=framework={fw}");
    }
    println!("cargo:rerun-if-changed={}", vendor.display());
}
