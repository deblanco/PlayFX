// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! The app's entry point: builds it on the real window system and attaches StreamCore. It only runs
//! against a real window, so it stays a thin adapter over the library, where the logic is tested.

fn main() {
    desktop_lib::with_commands(tauri::Builder::default().plugin(desktop_lib::log_plugin()))
        .setup(|app| desktop_lib::attach_streamcore(app))
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(desktop_lib::on_run_event);
}
