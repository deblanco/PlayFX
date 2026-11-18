#if os(macOS)
import AppKit

// C ABI for the Tauri (Rust) host. All functions must be called on the main thread.
// iOS (Expo module) will use `StreamRenderer` directly from Swift instead.

private var renderer: StreamRenderer?

/// Embeds the stream view at the bottom of the window's content view, i.e. behind the
/// (transparent) webview, so the web UI can overlay the video.
@_cdecl("sc_attach_macos_window")
public func sc_attach_macos_window(_ nsWindow: UnsafeMutableRawPointer) -> Bool {
    let window = Unmanaged<NSWindow>.fromOpaque(nsWindow).takeUnretainedValue()
    guard renderer == nil, let content = window.contentView, let r = StreamRenderer() else { return false }
    r.view.frame = content.bounds
    r.view.autoresizingMask = [.width, .height]
    content.addSubview(r.view, positioned: .below, relativeTo: nil)
    renderer = r
    return true
}

@_cdecl("sc_set_upscale_mode")
public func sc_set_upscale_mode(_ mode: Int32) {
    renderer?.mode = UpscaleMode(rawValue: mode) ?? .bilinear
}

@_cdecl("sc_set_input_size")
public func sc_set_input_size(_ width: Int32, _ height: Int32) {
    renderer?.setInputSize(width: Int(width), height: Int(height))
}

@_cdecl("sc_metalfx_supported")
public func sc_metalfx_supported() -> Bool {
    renderer?.metalFXSupported ?? false
}

/// Upscaler used for the last frame: 0 = bilinear, 1 = MetalFX, -1 = no renderer.
@_cdecl("sc_active_mode")
public func sc_active_mode() -> Int32 {
    renderer?.activeMode.rawValue ?? -1
}
#endif
