use serde::Serialize;
use tauri::{AppHandle, Manager};

/// C ABI exported by packages/streamcore (MacOSBridge.swift). Main thread only.
#[cfg(target_os = "macos")]
mod streamcore {
    use std::ffi::c_void;
    unsafe extern "C" {
        pub fn sc_attach_macos_window(ns_window: *mut c_void) -> bool;
        pub fn sc_set_upscale_mode(mode: i32);
        pub fn sc_set_input_size(width: i32, height: i32);
        pub fn sc_metalfx_supported() -> bool;
        pub fn sc_active_mode() -> i32;
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RendererStatus {
    metalfx_supported: bool,
    /// "bilinear" | "metalfx" | "none"
    active_mode: &'static str,
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

#[tauri::command(async)]
fn set_upscaler(app: AppHandle, mode: String) -> Result<(), String> {
    let mode = match mode.as_str() {
        "bilinear" => 0,
        "metalfx" => 1,
        other => return Err(format!("unknown upscaler: {other}")),
    };
    #[cfg(target_os = "macos")]
    on_main(&app, move || unsafe { streamcore::sc_set_upscale_mode(mode) })?;
    Ok(())
}

#[tauri::command(async)]
fn set_input_size(app: AppHandle, width: i32, height: i32) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    on_main(&app, move || unsafe { streamcore::sc_set_input_size(width, height) })?;
    Ok(())
}

#[tauri::command(async)]
fn renderer_status(app: AppHandle) -> Result<RendererStatus, String> {
    #[cfg(target_os = "macos")]
    let (metalfx_supported, mode) =
        on_main(&app, || unsafe { (streamcore::sc_metalfx_supported(), streamcore::sc_active_mode()) })?;
    #[cfg(not(target_os = "macos"))]
    let (metalfx_supported, mode) = (false, -1);
    Ok(RendererStatus {
        metalfx_supported,
        active_mode: match mode {
            0 => "bilinear",
            1 => "metalfx",
            _ => "none",
        },
    })
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            #[cfg(target_os = "macos")]
            {
                let window = app.get_webview_window("main").expect("main window");
                // `setup` runs on the main thread, as AppKit requires.
                let attached = unsafe { streamcore::sc_attach_macos_window(window.ns_window()?) };
                if !attached {
                    eprintln!("StreamCore: failed to attach Metal view");
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![set_upscaler, set_input_size, renderer_status])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
