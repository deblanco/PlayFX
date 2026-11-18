use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

/// C ABI exported by packages/streamcore (MacOSBridge.swift).
#[cfg(target_os = "macos")]
mod streamcore {
    use std::ffi::{c_char, c_void, CStr, CString};

    unsafe extern "C" {
        // main thread
        pub fn sc_attach_macos_window(ns_window: *mut c_void) -> bool;
        pub fn sc_set_upscale_mode(mode: i32);
        pub fn sc_metalfx_supported() -> bool;
        pub fn sc_active_mode() -> i32;
        pub fn sc_session_start(request: *const c_char) -> *mut c_char;
        pub fn sc_session_stop();
        pub fn sc_session_set_login_pin(pin: *const c_char);
        pub fn sc_session_stats() -> *mut c_char;
        // any thread (blocking ones must stay off the main thread)
        pub fn sc_set_event_callback(cb: Option<extern "C" fn(*const c_char)>);
        pub fn sc_discover(timeout_ms: i32) -> *mut c_char;
        pub fn sc_register(request: *const c_char) -> *mut c_char;
        pub fn sc_wakeup(credentials: *const c_char) -> bool;
        pub fn sc_psn_login_url() -> *mut c_char;
        pub fn sc_psn_redirect_url() -> *mut c_char;
        pub fn sc_psn_account_id(redirect: *const c_char) -> *mut c_char;
        fn sc_free(p: *mut c_char);
    }

    /// Takes ownership of a string returned by StreamCore.
    pub fn take(p: *mut c_char) -> String {
        if p.is_null() {
            return String::new();
        }
        let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
        unsafe { sc_free(p) };
        s
    }

    pub fn cstr(s: &str) -> CString {
        CString::new(s.replace('\0', "")).unwrap()
    }
}

#[cfg(target_os = "macos")]
use streamcore::*;

static APP: std::sync::OnceLock<AppHandle> = std::sync::OnceLock::new();

/// Session events from StreamCore (any thread) → "stream-event" in the webview.
extern "C" fn on_stream_event(json: *const std::ffi::c_char) {
    let text = unsafe { std::ffi::CStr::from_ptr(json) }.to_string_lossy().into_owned();
    if let (Some(app), Ok(value)) = (APP.get(), serde_json::from_str::<Value>(&text)) {
        let _ = app.emit("stream-event", value);
    }
}

/// Runs `f` on the main thread and waits for its result.
fn on_main<T: Send + 'static>(app: &AppHandle, f: impl FnOnce() -> T + Send + 'static) -> Result<T, String> {
    let (tx, rx) = std::sync::mpsc::channel();
    app.run_on_main_thread(move || {
        let _ = tx.send(f());
    })
    .map_err(|e| e.to_string())?;
    rx.recv().map_err(|e| e.to_string())
}

/// Turns a StreamCore JSON reply into Ok(value) / Err(message).
fn reply(text: String) -> Result<Value, String> {
    let value: Value = serde_json::from_str(&text).map_err(|e| format!("bad reply from core: {e}"))?;
    match value.get("error").and_then(Value::as_str) {
        Some(err) => Err(err.to_string()),
        None => Ok(value),
    }
}

// Blocking commands run on Tauri's async thread pool (`async` attribute), never on main.

#[tauri::command(async)]
fn discover() -> Result<Value, String> {
    reply(take(unsafe { sc_discover(1500) }))
}

#[tauri::command(async)]
fn register_console(request: Value) -> Result<Value, String> {
    let req = cstr(&request.to_string());
    reply(take(unsafe { sc_register(req.as_ptr()) }))
}

#[tauri::command(async)]
fn wakeup(credentials: Value) -> bool {
    let c = cstr(&credentials.to_string());
    unsafe { sc_wakeup(c.as_ptr()) }
}

/// Opens Sony's sign-in page in a window; when it redirects back with ?code=…, exchanges the
/// code for the account ID and emits "psn-account" ({accountId} or {error}).
#[tauri::command(async)]
fn psn_login(app: AppHandle) -> Result<(), String> {
    let login_url: tauri::Url = take(unsafe { sc_psn_login_url() }).parse().map_err(|e| format!("{e}"))?;
    let redirect = take(unsafe { sc_psn_redirect_url() });
    if let Some(w) = app.get_webview_window("psn-login") {
        let _ = w.close();
    }
    let handle = app.clone();
    WebviewWindowBuilder::new(&app, "psn-login", WebviewUrl::External(login_url))
        .title("Sign in to PlayStation Network")
        .inner_size(520.0, 720.0)
        .on_navigation(move |url| {
            if !url.as_str().starts_with(&redirect) {
                return true;
            }
            let url = url.to_string();
            let app = handle.clone();
            std::thread::spawn(move || {
                let u = cstr(&url);
                let result = match reply(take(unsafe { sc_psn_account_id(u.as_ptr()) })) {
                    Ok(v) => v,
                    Err(e) => serde_json::json!({ "error": e }),
                };
                let _ = app.emit("psn-account", result);
                if let Some(w) = app.get_webview_window("psn-login") {
                    let _ = w.close();
                }
            });
            false
        })
        .build()
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command(async)]
fn start_stream(app: AppHandle, request: Value) -> Result<Value, String> {
    let req = request.to_string();
    let text = on_main(&app, move || take(unsafe { sc_session_start(cstr(&req).as_ptr()) }))?;
    reply(text)
}

#[tauri::command(async)]
fn stop_stream(app: AppHandle) -> Result<(), String> {
    on_main(&app, || unsafe { sc_session_stop() })
}

#[tauri::command(async)]
fn set_login_pin(app: AppHandle, pin: String) -> Result<(), String> {
    on_main(&app, move || unsafe { sc_session_set_login_pin(cstr(&pin).as_ptr()) })
}

#[tauri::command(async)]
fn set_upscaler(app: AppHandle, mode: String) -> Result<(), String> {
    let mode = match mode.as_str() {
        "bilinear" => 0,
        "metalfx" => 1,
        other => return Err(format!("unknown upscaler: {other}")),
    };
    on_main(&app, move || unsafe { sc_set_upscale_mode(mode) })
}

#[tauri::command(async)]
fn renderer_status(app: AppHandle) -> Result<Value, String> {
    let (metalfx, mode, stats) = on_main(&app, || unsafe {
        (sc_metalfx_supported(), sc_active_mode(), take(sc_session_stats()))
    })?;
    Ok(serde_json::json!({
        "metalfxSupported": metalfx,
        "activeMode": match mode { 0 => "bilinear", 1 => "metalfx", _ => "none" },
        "stream": serde_json::from_str::<Value>(&stats).unwrap_or(Value::Null),
    }))
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            let _ = APP.set(app.handle().clone());
            #[cfg(target_os = "macos")]
            {
                unsafe { sc_set_event_callback(Some(on_stream_event)) };
                let window = app.get_webview_window("main").expect("main window");
                // `setup` runs on the main thread, as AppKit requires.
                let attached = unsafe { sc_attach_macos_window(window.ns_window()?) };
                if !attached {
                    eprintln!("StreamCore: failed to attach Metal view");
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            discover,
            register_console,
            wakeup,
            psn_login,
            start_stream,
            stop_stream,
            set_login_pin,
            set_upscaler,
            renderer_status
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
