fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        link_streamcore();
    }
    embed_commit();
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
        "request_keyframe",
        "set_login_pin",
        "set_controller",
        "set_pointer_touch",
        "set_touchpad_touches",
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
        "fullscreen_state",
        "psn_signed_in",
        "psn_consoles",
        "psn_sign_out",
        "pair_psn",
        "cancel_psn_pair",
        "set_detailed_logs",
        "open_logs_folder",
        "open_source_code",
        "open_help",
        "open_local_network_settings",
        "diagnostics",
        "app_info",
        "renderer_status",
        "update_check",
        "update_install",
        "update_restart",
        "update_set_playing",
        "open_release_page",
    ])))
    .expect("tauri build");
}

/// The commit the app is built from, as `PLAYFX_COMMIT` (short hash, "+changes" when the tree differs from it;
/// "unknown" outside a git checkout), so the Diagnostics panel, the log and a bug report name the exact code.
fn embed_commit() {
    let git = |args: &[&str]| {
        std::process::Command::new("git")
            .args(args)
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
    };
    let commit = git(&["rev-parse", "--short=7", "HEAD"]).unwrap_or_else(|| "unknown".into());
    let changed = git(&["status", "--porcelain", "--untracked-files=no"]).is_some_and(|s| !s.is_empty());
    println!("cargo:rustc-env=PLAYFX_COMMIT={commit}{}", if changed { "+changes" } else { "" });
    // Again after a commit or checkout (the reflog moves with both).
    if let Some(dir) = git(&["rev-parse", "--absolute-git-dir"]) {
        println!("cargo:rerun-if-changed={dir}/logs/HEAD");
        println!("cargo:rerun-if-changed={dir}/index");
    }
}

/// Compiles and links the shared Swift core (Metal/MetalFX renderer, the PlayFX protocol engine).
fn link_streamcore() {
    let pkg = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../packages/streamcore");
    let opus = opus_prefix();
    let libopus = opus.join("lib/libopus.a");
    if !libopus.exists() {
        panic!("no static libopus at {}: brew install opus (or set OPUS_PREFIX)", libopus.display());
    }
    // Package.swift links the same keg's archive into psrp and the tests, and compiles against its headers.
    // SAFETY: the build script is single-threaded; this is set before `swift build` is spawned.
    unsafe { std::env::set_var("OPUS_PREFIX", &opus) };

    swift_rs::SwiftLinker::new("13.0").with_package("StreamCore", &pkg).link();

    // A static Swift library doesn't carry its link settings; repeat Package.swift's here. libopus goes in by its
    // path, never `-lopus`, so the keg's dynamic libopus can't be picked instead.
    println!("cargo:rustc-link-arg={}", libopus.display());
    // Swift runtime (libswift_Concurrency etc.) ships with macOS under /usr/lib/swift.
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    for fw in [
        "Security", "Metal", "MetalKit", "MetalFX", "QuartzCore", "VideoToolbox", "CoreMedia", "CoreVideo",
        "AVFoundation", "GameController", "CoreImage", "IOKit",
    ] {
        println!("cargo:rustc-link-lib=framework={fw}");
    }
    println!("cargo:rerun-if-env-changed=OPUS_PREFIX");
    println!("cargo:rerun-if-changed={}", libopus.display());
}

/// Homebrew's opus keg: `OPUS_PREFIX` when set, else `brew --prefix opus`.
fn opus_prefix() -> std::path::PathBuf {
    if let Some(prefix) = std::env::var_os("OPUS_PREFIX") {
        return prefix.into();
    }
    std::process::Command::new("brew")
        .args(["--prefix", "opus"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().into())
        .unwrap_or_else(|| panic!("libopus: brew install opus (or set OPUS_PREFIX to its prefix)"))
}
