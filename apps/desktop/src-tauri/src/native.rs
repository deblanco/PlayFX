//! The StreamCore boundary as a trait, plus the pure logic around it.
//!
//! Command handlers talk to `NativeCore` through `CoreHandle` (Tauri managed state), so tests can
//! swap the real FFI implementation (`ffi::MacCore`) for a fake.

use serde_json::{Value, json};

/// Everything the commands need from StreamCore. Strings are JSON in and out, as in the C ABI.
pub trait NativeCore: Send + Sync {
    // any thread (blocking ones must stay off the main thread)
    fn discover(&self, timeout_ms: i32) -> String;
    fn register(&self, request: &str) -> String;
    fn wakeup(&self, credentials: &str) -> bool;
    fn psn_login_url(&self) -> String;
    fn psn_redirect_url(&self) -> String;
    fn psn_account_id(&self, redirect: &str) -> String;
    // main thread
    fn session_start(&self, request: &str) -> String;
    fn session_stop(&self);
    fn set_login_pin(&self, pin: &str);
    fn set_upscale_mode(&self, mode: i32);
    fn metalfx_supported(&self) -> bool;
    fn active_mode(&self) -> i32;
    fn session_stats(&self) -> String;
}

/// Managed state holding the core the commands use.
pub struct CoreHandle(pub &'static dyn NativeCore);

/// Turns a StreamCore JSON reply into Ok(value) / Err(message).
pub fn reply(text: &str) -> Result<Value, String> {
    let value: Value = serde_json::from_str(text).map_err(|e| format!("bad reply from core: {e}"))?;
    match value.get("error").and_then(Value::as_str) {
        Some(err) => Err(err.to_string()),
        None => Ok(value),
    }
}

/// Upscaler name from the UI → StreamCore mode number.
pub fn upscale_mode(name: &str) -> Result<i32, String> {
    match name {
        "bilinear" => Ok(0),
        "metalfx" => Ok(1),
        other => Err(format!("unknown upscaler: {other}")),
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

/// The `renderer_status` reply; unparseable stats become `null`.
pub fn renderer_status_json(metalfx_supported: bool, active_mode: i32, stats: &str) -> Value {
    json!({
        "metalfxSupported": metalfx_supported,
        "activeMode": mode_name(active_mode),
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
