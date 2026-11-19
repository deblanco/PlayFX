//! The desktop app's commands and the bridge to StreamCore. The app's entry point (window setup, the
//! native callbacks) lives in `main.rs`, a thin adapter that only runs against a real window.

#[cfg(debug_assertions)]
pub mod dev_control;
#[cfg(target_os = "macos")]
mod ffi;
mod native;
#[cfg(test)]
mod tests;

use native::{
    controller_state, is_psn_redirect, psn_account, native_level, renderer_status_json, reply, tail_lines, with_psn_token, CoreHandle, RendererState,
    NativeCore, PointerTouch,
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

/// StreamCore's log entries (already scrubbed) into the app's log, under `streamcore::<area>`.
extern "C" fn on_native_log(level: i32, area: *const std::ffi::c_char, message: *const std::ffi::c_char) {
    let area = unsafe { std::ffi::CStr::from_ptr(area) }.to_string_lossy();
    let message = unsafe { std::ffi::CStr::from_ptr(message) }.to_string_lossy();
    log::log!(target: &format!("streamcore::{area}"), native_level(level), "{message}");
}

/// The app's log: native, Rust and web UI entries in one time-ordered file,
/// ~/Library/Logs/<identifier>/playfx.log (5 MB, the last 3 kept), and the terminal. Our own
/// entries at every level; other crates' from info up.
pub fn log_plugin<R: Runtime>() -> tauri::plugin::TauriPlugin<R> {
    use tauri_plugin_log::{RotationStrategy, Target, TargetKind, TimezoneStrategy};
    tauri_plugin_log::Builder::new()
        .clear_targets()
        .targets([
            Target::new(TargetKind::LogDir { file_name: Some("playfx".into()) }),
            Target::new(TargetKind::Stdout),
        ])
        .level(log::LevelFilter::Info)
        .level_for("streamcore", log::LevelFilter::Trace)
        .level_for("webview", log::LevelFilter::Trace)
        .level_for(env!("CARGO_CRATE_NAME"), log::LevelFilter::Trace)
        .max_file_size(5_000_000)
        .rotation_strategy(RotationStrategy::KeepSome(3))
        .timezone_strategy(TimezoneStrategy::UseLocal)
        .build()
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
    .map_err(error_text)?;
    rx.recv().map_err(error_text)
}

// Blocking commands run on Tauri's async thread pool (`async` attribute), never on main.

#[tauri::command(async)]
fn discover<R: Runtime>(app: AppHandle<R>, host: Option<String>) -> Result<Value, String> {
    match host {
        // Only an IP address goes to the console: anything else is a mistake to report, not resolve.
        Some(host) => {
            let ip: std::net::IpAddr = host.trim().parse().map_err(|_| format!("{host} isn't an IP address"))?;
            reply(&core(&app).discover_host(&ip.to_string(), 1500))
        }
        None => reply(&core(&app).discover(1500)),
    }
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
    log::info!("Opening the PSN sign-in window");
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
    let result = psn_account(core(app), url);
    match result.get("error") {
        Some(error) => log::warn!("PSN sign-in failed: {error}"),
        None => log::info!("PSN sign-in finished"),
    }
    let _ = app.emit("psn-account", result);
    if let Some(w) = app.get_webview_window(PSN_WINDOW) {
        let _ = w.close();
    }
}

#[tauri::command(async)]
fn start_stream<R: Runtime>(app: AppHandle<R>, request: Value) -> Result<Value, String> {
    let core = core(&app);
    log::info!(
        "Starting a stream {}",
        if request.get("remote").is_some() { "over the internet (PSN)" } else { "on the local network" }
    );
    // Off the main thread: fetching the PSN token may refresh it over the network.
    let req = with_psn_token(core, request)?.to_string();
    let text = on_main(&app, move || core.session_start(&req))?;
    reply(&text)
}

#[tauri::command(async)]
fn stop_stream<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    let core = core(&app);
    on_main(&app, move || core.session_stop())
}

/// Puts the console in rest mode; the session ends when it goes to sleep.
#[tauri::command(async)]
fn sleep_console<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    log::info!("Putting the console in rest mode");
    let core = core(&app);
    on_main(&app, move || core.session_sleep())
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
fn keyboard_set_text<R: Runtime>(app: AppHandle<R>, text: String) -> Result<(), String> {
    let core = core(&app);
    on_main(&app, move || core.keyboard_set_text(&text))
}

#[tauri::command(async)]
fn set_microphone<R: Runtime>(app: AppHandle<R>, on: bool) -> Result<(), String> {
    log::info!("Microphone {}", if on { "on requested" } else { "off" });
    let core = core(&app);
    on_main(&app, move || core.set_microphone(on))
}

#[tauri::command(async)]
fn keyboard_done<R: Runtime>(app: AppHandle<R>, accept: bool) -> Result<(), String> {
    let core = core(&app);
    on_main(&app, move || core.keyboard_done(accept))
}

#[tauri::command(async)]
fn set_pointer_touch<R: Runtime>(app: AppHandle<R>, touch: Value) -> Result<(), String> {
    let touch: PointerTouch = serde_json::from_value(touch).map_err(error_text)?;
    let core = core(&app);
    on_main(&app, move || core.set_pointer_touch(touch))
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
fn psn_signed_in<R: Runtime>(app: AppHandle<R>) -> bool {
    core(&app).psn_signed_in()
}

#[tauri::command(async)]
fn audio_devices<R: Runtime>(app: AppHandle<R>) -> Result<Value, String> {
    reply(&core(&app).audio_devices())
}

#[tauri::command(async)]
fn set_audio_output<R: Runtime>(app: AppHandle<R>, output: Value) -> Result<Value, String> {
    reply(&core(&app).set_audio_output(&output.to_string()))
}

#[tauri::command(async)]
fn secret_get<R: Runtime>(app: AppHandle<R>, key: String) -> Result<Value, String> {
    reply(&core(&app).secret_get(&key))
}

#[tauri::command(async)]
fn secret_set<R: Runtime>(app: AppHandle<R>, key: String, value: String) -> Result<Value, String> {
    reply(&core(&app).secret_set(&key, &value))
}

#[tauri::command(async)]
fn secret_remove<R: Runtime>(app: AppHandle<R>, key: String) {
    core(&app).secret_remove(&key);
}

#[tauri::command(async)]
fn psn_consoles<R: Runtime>(app: AppHandle<R>) -> Result<Value, String> {
    reply(&core(&app).psn_consoles())
}

#[tauri::command(async)]
fn psn_sign_out<R: Runtime>(app: AppHandle<R>) {
    core(&app).psn_sign_out();
}

#[tauri::command(async)]
fn set_detailed_logs<R: Runtime>(app: AppHandle<R>, on: bool) {
    log::info!("Detailed logs {}", if on { "on" } else { "off" });
    core(&app).set_detailed_logs(on);
}

/// Shows the folder with the app's log file in Finder.
#[tauri::command(async)]
fn open_logs_folder<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    let dir = app.path().app_log_dir().map_err(error_text)?;
    std::fs::create_dir_all(&dir).map_err(error_text)?;
    std::process::Command::new("open").arg(&dir).spawn().map_err(error_text)?;
    Ok(())
}

/// Where PlayFX's source code lives (AGPL-3.0: every build points users to it).
const SOURCE_URL: &str = "https://github.com/deblanco/PlayFX";

/// Opens the source code in the browser. The URL is fixed here, never taken from the web view.
#[tauri::command(async)]
fn open_source_code() -> Result<(), String> {
    std::process::Command::new("open").arg(SOURCE_URL).spawn().map_err(error_text)?;
    Ok(())
}

/// For bug reports: versions and the end of the log file (already scrubbed of credentials).
#[tauri::command(async)]
fn diagnostics<R: Runtime>(app: AppHandle<R>) -> Result<Value, String> {
    let dir = app.path().app_log_dir().map_err(error_text)?;
    let log = std::fs::read_to_string(dir.join("playfx.log")).unwrap_or_default();
    let os = std::process::Command::new("sw_vers")
        .arg("-productVersion")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();
    Ok(serde_json::json!({
        "appVersion": app.package_info().version.to_string(),
        "os": format!("macOS {os}"),
        "logFolder": dir.display().to_string(),
        "recentLog": tail_lines(&log, 200),
    }))
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
            interpolation: core.interpolation_status(),
            hdr: core.hdr_active(),
            display_ms: core.display_milliseconds(),
            shown_fps: core.shown_fps(),
            pacing: core.pacing_stats(),
        };
        (state, core.session_stats())
    })?;
    Ok(renderer_status_json(&state, &stats))
}

/// Registers the commands the React UI invokes (see apps/desktop/src/core/core.ts).
pub fn with_commands<R: Runtime>(builder: Builder<R>) -> Builder<R> {
    builder.invoke_handler(tauri::generate_handler![
        discover,
        register_console,
        wakeup,
        psn_login,
        start_stream,
        stop_stream,
        sleep_console,
        set_login_pin,
        set_controller,
        set_pointer_touch,
        keyboard_set_text,
        keyboard_done,
        set_microphone,
        secret_get,
        audio_devices,
        set_audio_output,
        secret_set,
        secret_remove,
        set_render_params,
        toggle_fullscreen,
        psn_signed_in,
        psn_consoles,
        psn_sign_out,
        set_detailed_logs,
        open_logs_folder,
        open_source_code,
        diagnostics,
        renderer_status
    ])
}

/// The dev control port's view of the app (debug builds only; see docs/dev-control.md).
#[cfg(debug_assertions)]
struct AppDevHost<R: Runtime>(AppHandle<R>);

#[cfg(debug_assertions)]
impl<R: Runtime> dev_control::DevHost for AppDevHost<R> {
    fn status(&self) -> Result<Value, String> {
        renderer_status(self.0.clone())
    }
    fn press(&self, buttons: u32, ms: u64) -> Result<(), String> {
        let core = core(&self.0);
        let held = native::ControllerState { buttons, ..Default::default() };
        on_main(&self.0, move || core.set_controller(held))?;
        std::thread::sleep(std::time::Duration::from_millis(ms));
        on_main(&self.0, move || core.set_controller(native::ControllerState::default()))
    }
    fn fullscreen(&self) -> Result<bool, String> {
        toggle_fullscreen(self.0.clone())
    }
    fn emit(&self, command: Value) -> Result<(), String> {
        self.0.emit("dev-control", command).map_err(error_text)
    }
}

/// Starts the dev control port when `PLAYFX_DEV_CONTROL` names one (debug builds only).
#[cfg(debug_assertions)]
pub fn start_dev_control<R: Runtime>(app: &AppHandle<R>, port: Option<u16>) -> Option<std::net::SocketAddr> {
    let port = port?;
    match dev_control::start(port, std::sync::Arc::new(AppDevHost(app.clone()))) {
        Ok(address) => {
            log::warn!("Dev control port open on http://{address} (debug build, {})", dev_control::ENV);
            Some(address)
        }
        Err(error) => {
            log::error!("{error}");
            None
        }
    }
}

/// Connects StreamCore to the running app: the native core behind the commands, its events and log,
/// and its Metal view under the main window's web view. Called from `main.rs` during setup, on the
/// main thread, as AppKit requires.
pub fn attach_streamcore(app: &tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    log::info!("PlayFX {} starting", app.package_info().version);
    let _ = APP.set(app.handle().clone());
    #[cfg(target_os = "macos")]
    {
        app.manage(CoreHandle(&ffi::MacCore));
        #[cfg(debug_assertions)]
        start_dev_control(app.handle(), dev_control::port(std::env::var(dev_control::ENV).ok().as_deref()));
        unsafe { ffi::sc_set_event_callback(Some(on_stream_event)) };
        // Detailed logs start off (the web UI switches them on from its saved preference).
        unsafe { ffi::sc_set_log_callback(Some(on_native_log), std::env::var_os("PSRP_VERBOSE").is_some()) };
        let window = app.get_webview_window("main").ok_or("no main window")?;
        if !unsafe { ffi::sc_attach_macos_window(window.ns_window()?) } {
            log::error!("StreamCore: failed to attach the Metal view");
        }
    }
    Ok(())
}
