//! The StreamCore boundary as a trait, plus the pure logic around it.
//!
//! Command handlers talk to `NativeCore` through `CoreHandle` (Tauri managed state), so tests can
//! swap the real FFI implementation (`ffi::MacCore`) for a fake.

use serde::Deserialize;
use serde_json::{Value, json};

/// A controller state sent from the web UI (keyboard-as-controller, on-screen pad, etc.).
/// The Mac's pointer as a touchpad finger: `down` = touching at (x, y), 0–1 from the video's
/// top-left; `pressed` = the touchpad is clicked.
#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
pub struct PointerTouch {
    pub down: bool,
    pub x: f32,
    pub y: f32,
    pub pressed: bool,
}

/// Field order and ranges match StreamCore's `sc_session_set_controller`.
#[derive(Deserialize, Clone, Copy, Debug, Default, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ControllerState {
    pub buttons: u32,
    pub l2: u8,
    pub r2: u8,
    pub left_x: i16,
    pub left_y: i16,
    pub right_x: i16,
    pub right_y: i16,
}

/// Decodes a controller state from the command payload.
pub fn controller_state(value: Value) -> Result<ControllerState, String> {
    serde_json::from_value(value).map_err(|e| format!("invalid controller state: {e}"))
}

/// Everything the commands need from StreamCore. Strings are JSON in and out, as in the C ABI.
pub trait NativeCore: Send + Sync {
    // any thread (blocking ones must stay off the main thread)
    fn discover(&self, timeout_ms: i32) -> String;
    fn register(&self, request: &str) -> String;
    fn wakeup(&self, credentials: &str) -> bool;
    fn psn_login_url(&self) -> String;
    fn psn_redirect_url(&self) -> String;
    fn psn_account_id(&self, redirect: &str) -> String;
    /// Detailed (debug) native logs, including libchiaki's verbose ones.
    fn set_detailed_logs(&self, on: bool);
    /// Whether PSN tokens are kept for playing over the internet (Keychain).
    fn psn_signed_in(&self) -> bool;
    fn psn_sign_out(&self);
    /// Blocking: the PS5s on the PSN account, as JSON (or {"error"}).
    fn psn_consoles(&self) -> String;
    /// The app's secrets (pairing keys, account ID): Keychain in release builds, a 0600 file in dev.
    /// `secret_get` replies {"value": "…" | null}; `secret_set` {"ok"} or {"error"}.
    fn secret_get(&self, key: &str) -> String;
    /// The Mac's sound outputs as [{"uid", "name"}].
    fn audio_devices(&self) -> String;
    /// Sound volume and output device ({"volume", "deviceUID"?}) for this stream and later ones.
    fn set_audio_output(&self, request: &str) -> String;
    fn secret_set(&self, key: &str, value: &str) -> String;
    fn secret_remove(&self, key: &str);
    /// Blocking: a fresh PSN access token as {"token"} (or {"error"}). Stays native.
    fn psn_access_token(&self) -> String;
    // main thread
    fn session_start(&self, request: &str) -> String;
    fn session_stop(&self);
    /// Puts the console in rest mode (it ends the session itself).
    fn session_sleep(&self);
    /// Discovery aimed at one address, for consoles broadcast discovery can't reach.
    fn discover_host(&self, host: &str, timeout_ms: i32) -> String;
    fn set_login_pin(&self, pin: &str);
    fn set_controller(&self, state: ControllerState);
    /// Types into the console's open text field (replacing its text), then sends or cancels it.
    fn keyboard_set_text(&self, text: &str);
    fn keyboard_done(&self, accept: bool);
    /// Voice chat: the Mac's microphone on/off; the outcome arrives as a "microphone" stream event.
    fn set_microphone(&self, on: bool);
    /// The Mac's pointer as a touchpad finger, merged with the pad's state.
    fn set_pointer_touch(&self, touch: PointerTouch);
    /// Picture settings as JSON (see StreamCore's RenderParams); false if StreamCore rejects them.
    fn set_render_params(&self, params: &str) -> bool;
    fn metalfx_supported(&self) -> bool;
    fn active_mode(&self) -> i32;
    /// Smoothed GPU time per rendered frame (0 = nothing rendered yet).
    fn gpu_milliseconds(&self) -> f64;
    /// Apple ML super-resolution: (can run here, ran on the last frame).
    fn ml_status(&self) -> (bool, bool);
    /// Frame interpolation ("Smooth motion"): (can run here, made the last in-between frame).
    fn smooth_status(&self) -> (bool, bool);
    /// HDR10 frames are on screen (EDR output).
    fn hdr_active(&self) -> bool;
    /// From a decoded frame arriving to it being on screen, smoothed (ms).
    fn display_milliseconds(&self) -> f64;
    /// New images put on screen per second (with Smooth motion, more than the stream sends).
    fn shown_fps(&self) -> f64;
    fn session_stats(&self) -> String;
}

/// Managed state holding the core the commands use.
pub struct CoreHandle(pub &'static dyn NativeCore);

/// Internet play: the web UI only names the console's PSN device ID (`"remote": {"duid"}`); the PSN
/// token is added here, natively, so it never passes through the web UI. Blocking (token refresh).
pub fn with_psn_token(core: &dyn NativeCore, mut request: Value) -> Result<Value, String> {
    if let Some(remote) = request.get_mut("remote").and_then(Value::as_object_mut) {
        let reply = reply(&core.psn_access_token())?;
        let token = reply.get("token").cloned().ok_or("no PSN token in reply")?;
        remote.insert("token".into(), token);
    }
    Ok(request)
}

/// StreamCore's log levels (0 debug … 3 error) → the `log` crate's.
pub fn native_level(level: i32) -> log::Level {
    match level {
        0 => log::Level::Debug,
        1 => log::Level::Info,
        2 => log::Level::Warn,
        _ => log::Level::Error,
    }
}

/// The last `count` lines of a log file's text.
pub fn tail_lines(text: &str, count: usize) -> String {
    let lines: Vec<&str> = text.lines().collect();
    lines[lines.len().saturating_sub(count)..].join("\n")
}

/// Turns a StreamCore JSON reply into Ok(value) / Err(message).
pub fn reply(text: &str) -> Result<Value, String> {
    let value: Value = serde_json::from_str(text).map_err(|e| {
        log::error!("bad reply from StreamCore: {e}");
        format!("bad reply from core: {e}")
    })?;
    match value.get("error").and_then(Value::as_str) {
        Some(err) => {
            log::warn!("StreamCore: {err}");
            Err(err.to_string())
        }
        None => Ok(value),
    }
}

/// StreamCore mode number → upscaler name for the UI.
pub fn mode_name(mode: i32) -> &'static str {
    match mode {
        0 => "bilinear",
        1 => "metalfx",
        _ => "none",
    }
}

/// What the renderer reports for the `renderer_status` reply.
pub struct RendererState {
    pub metalfx_supported: bool,
    pub active_mode: i32,
    pub gpu_ms: f64,
    /// Apple ML super-resolution: (can run here, ran on the last frame).
    pub ml: (bool, bool),
    /// Frame interpolation ("Smooth motion"): (can run here, active on the last frame).
    pub smooth: (bool, bool),
    pub hdr: bool,
    pub display_ms: f64,
    pub shown_fps: f64,
}

/// The `renderer_status` reply; unparseable stats become `null`.
pub fn renderer_status_json(state: &RendererState, stats: &str) -> Value {
    json!({
        "metalfxSupported": state.metalfx_supported,
        "activeMode": mode_name(state.active_mode),
        "gpuMs": (state.gpu_ms * 100.0).round() / 100.0,
        "mlSupported": state.ml.0,
        "mlActive": state.ml.1,
        "smoothSupported": state.smooth.0,
        "smoothActive": state.smooth.1,
        "hdrActive": state.hdr,
        "displayMs": (state.display_ms * 10.0).round() / 10.0,
        "shownFps": state.shown_fps.round(),
        "stream": serde_json::from_str::<Value>(stats).unwrap_or(Value::Null),
    })
}

/// Whether a navigation in the PSN sign-in window is the redirect carrying the sign-in code.
pub fn is_psn_redirect(url: &str, redirect: &str) -> bool {
    url.starts_with(redirect)
}

/// A session event from StreamCore, if it is valid JSON.
pub fn parse_event(text: &str) -> Option<Value> {
    serde_json::from_str(text).ok()
}

/// Exchanges the PSN redirect URL for the "psn-account" payload: {accountId} or {error}.
pub fn psn_account(core: &dyn NativeCore, redirect_url: &str) -> Value {
    match reply(&core.psn_account_id(redirect_url)) {
        Ok(v) => v,
        Err(e) => json!({ "error": e }),
    }
}
