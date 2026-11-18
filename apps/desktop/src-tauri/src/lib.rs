#[cfg(target_os = "macos")]
mod ffi;
mod native;
#[cfg(test)]
mod tests;

use native::{
    controller_state, is_psn_redirect, psn_account, renderer_status_json, reply, CoreHandle, RendererState,
    NativeCore,
};
use serde_json::Value;
use tauri::{AppHandle, Builder, Emitter, Manager, Runtime, Url, WebviewUrl, WebviewWindowBuilder};

const PSN_WINDOW: &str = "psn-login";

static APP: std::sync::OnceLock<AppHandle> = std::sync::OnceLock::new();

/// Session events from StreamCore (any thread) → "stream-event" in the webview.
extern "C" fn on_stream_event(json: *const std::ffi::c_char) {
    let text = unsafe { std::ffi::CStr::from_ptr(json) }.to_string_lossy().into_owned();
    if let (Some(app), Some(value)) = (APP.get(), native::parse_event(&text)) {
        let _ = app.emit("stream-event", value);
    }
}

/// The StreamCore the commands use (managed in `run`, faked in tests).
fn core<R: Runtime>(app: &AppHandle<R>) -> &'static dyn NativeCore {
    app.state::<CoreHandle>().0
}

/// Runs `f` on the main thread and waits for its result.
fn on_main<R: Runtime, T: Send + 'static>(
    app: &AppHandle<R>,
    f: impl FnOnce() -> T + Send + 'static,
) -> Result<T, String> {
    let (tx, rx) = std::sync::mpsc::channel();
    app.run_on_main_thread(move || {
        let _ = tx.send(f());
    })
    .map_err(|e| e.to_string())?;
    rx.recv().map_err(|e| e.to_string())
}

// Blocking commands run on Tauri's async thread pool (`async` attribute), never on main.

#[tauri::command(async)]
fn discover<R: Runtime>(app: AppHandle<R>) -> Result<Value, String> {
    reply(&core(&app).discover(1500))
}

#[tauri::command(async)]
fn register_console<R: Runtime>(app: AppHandle<R>, request: Value) -> Result<Value, String> {
    reply(&core(&app).register(&request.to_string()))
}

#[tauri::command(async)]
fn wakeup<R: Runtime>(app: AppHandle<R>, credentials: Value) -> bool {
    core(&app).wakeup(&credentials.to_string())
}

/// Opens Sony's sign-in page in a window; when it redirects back with ?code=…, exchanges the
/// code for the account ID and emits "psn-account" ({accountId} or {error}). An already open
/// sign-in window is restarted and focused: closing it is asynchronous, so rebuilding under the
/// same label would fail while it is still registered.
#[tauri::command(async)]
fn psn_login<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    let core = core(&app);
    let login_url: Url = core.psn_login_url().parse().map_err(error_text)?;
    let redirect = core.psn_redirect_url();
    if let Some(w) = app.get_webview_window(PSN_WINDOW) {
        w.navigate(login_url).map_err(error_text)?;
        let _ = w.set_focus();
        return Ok(());
    }
    let handle = app.clone();
    WebviewWindowBuilder::new(&app, PSN_WINDOW, WebviewUrl::External(login_url))
        .title("Sign in to PlayStation Network")
        .inner_size(520.0, 720.0)
        .on_navigation(move |url| on_psn_navigation(&handle, &redirect, url.as_str()))
        .build()
        .map_err(error_text)?;
    Ok(())
}

fn error_text(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// Lets the sign-in window navigate, except to the redirect, which is handled off-thread.
fn on_psn_navigation<R: Runtime>(app: &AppHandle<R>, redirect: &str, url: &str) -> bool {
    if !is_psn_redirect(url, redirect) {
        return true;
    }
    let url = url.to_string();
    let app = app.clone();
    std::thread::spawn(move || finish_psn_login(&app, &url));
    false
}

/// Exchanges the redirect for the account ID, emits "psn-account" and closes the sign-in window.
fn finish_psn_login<R: Runtime>(app: &AppHandle<R>, url: &str) {
    let _ = app.emit("psn-account", psn_account(core(app), url));
    if let Some(w) = app.get_webview_window(PSN_WINDOW) {
        let _ = w.close();
    }
}

#[tauri::command(async)]
fn start_stream<R: Runtime>(app: AppHandle<R>, request: Value) -> Result<Value, String> {
    let core = core(&app);
    let req = request.to_string();
    let text = on_main(&app, move || core.session_start(&req))?;
    reply(&text)
}

#[tauri::command(async)]
fn stop_stream<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    let core = core(&app);
    on_main(&app, move || core.session_stop())
}

#[tauri::command(async)]
fn set_login_pin<R: Runtime>(app: AppHandle<R>, pin: String) -> Result<(), String> {
    let core = core(&app);
    on_main(&app, move || core.set_login_pin(&pin))
}

#[tauri::command(async)]
fn set_controller<R: Runtime>(app: AppHandle<R>, state: Value) -> Result<(), String> {
    let state = controller_state(state)?;
    let core = core(&app);
    on_main(&app, move || core.set_controller(state))
}

#[tauri::command(async)]
fn set_render_params<R: Runtime>(app: AppHandle<R>, params: Value) -> Result<(), String> {
    let core = core(&app);
    let json = params.to_string();
    if on_main(&app, move || core.set_render_params(&json))? {
        Ok(())
    } else {
        Err(format!("invalid picture settings: {params}"))
    }
}

/// Toggles native fullscreen on the main window; replies with the new state. Reads the window's actual
/// state, so it stays right when the user also uses the green button.
#[tauri::command(async)]
fn toggle_fullscreen<R: Runtime>(app: AppHandle<R>) -> Result<bool, String> {
    let window = app.get_webview_window("main").ok_or("no main window")?;
    let on = !window.is_fullscreen().map_err(|e| e.to_string())?;
    window.set_fullscreen(on).map_err(|e| e.to_string())?;
    Ok(on)
}

#[tauri::command(async)]
fn renderer_status<R: Runtime>(app: AppHandle<R>) -> Result<Value, String> {
    let core = core(&app);
    let (state, stats) = on_main(&app, move || {
        let state = RendererState {
            metalfx_supported: core.metalfx_supported(),
            active_mode: core.active_mode(),
            gpu_ms: core.gpu_milliseconds(),
            ml: core.ml_status(),
        };
        (state, core.session_stats())
    })?;
    Ok(renderer_status_json(&state, &stats))
}

/// Registers the commands the React UI invokes (see apps/desktop/src/core/core.ts).
fn with_commands<R: Runtime>(builder: Builder<R>) -> Builder<R> {
    builder.invoke_handler(tauri::generate_handler![
        discover,
        register_console,
        wakeup,
        psn_login,
        start_stream,
        stop_stream,
        set_login_pin,
        set_controller,
        set_render_params,
        toggle_fullscreen,
        renderer_status
    ])
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    with_commands(tauri::Builder::default())
        .setup(|app| {
            let _ = APP.set(app.handle().clone());
            #[cfg(target_os = "macos")]
            {
                app.manage(CoreHandle(&ffi::MacCore));
                unsafe { ffi::sc_set_event_callback(Some(on_stream_event)) };
                let window = app.get_webview_window("main").expect("main window");
                // `setup` runs on the main thread, as AppKit requires.
                let attached = unsafe { ffi::sc_attach_macos_window(window.ns_window()?) };
                if !attached {
                    eprintln!("StreamCore: failed to attach Metal view");
                }
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
