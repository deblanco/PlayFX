//! C ABI exported by packages/streamcore (MacOSBridge.swift), and `MacCore`, the real `NativeCore`.

use std::ffi::{CStr, CString, c_char, c_void};

use crate::native::{ControllerState, NativeCore, PointerTouch};

unsafe extern "C" {
    // main thread
    pub fn sc_attach_macos_window(ns_window: *mut c_void) -> bool;
    pub fn sc_set_render_params(params: *const c_char) -> bool;
    pub fn sc_metalfx_supported() -> bool;
    pub fn sc_active_mode() -> i32;
    pub fn sc_gpu_milliseconds() -> f64;
    pub fn sc_ml_supported() -> bool;
    pub fn sc_ml_active() -> bool;
    pub fn sc_smooth_supported() -> bool;
    pub fn sc_smooth_active() -> bool;
    pub fn sc_hdr_active() -> bool;
    pub fn sc_session_start(request: *const c_char) -> *mut c_char;
    pub fn sc_session_stop();
    pub fn sc_session_set_login_pin(pin: *const c_char);
    pub fn sc_session_set_controller(
        buttons: u32, l2: u8, r2: u8, left_x: i16, left_y: i16, right_x: i16, right_y: i16,
    );
    pub fn sc_session_set_pointer_touch(down: bool, x: f32, y: f32, pressed: bool);
    pub fn sc_session_keyboard_set_text(text: *const c_char);
    pub fn sc_session_keyboard_done(accept: bool);
    pub fn sc_session_set_mic(on: bool);
    pub fn sc_session_stats() -> *mut c_char;
    pub fn sc_secret_get(key: *const c_char) -> *mut c_char;
    pub fn sc_secret_set(key: *const c_char, value: *const c_char) -> *mut c_char;
    pub fn sc_secret_remove(key: *const c_char);
    // any thread (blocking ones must stay off the main thread)
    pub fn sc_set_event_callback(cb: Option<extern "C" fn(*const c_char)>);
    pub fn sc_set_log_callback(cb: Option<extern "C" fn(i32, *const c_char, *const c_char)>, detailed: bool);
    pub fn sc_set_log_detailed(detailed: bool);
    pub fn sc_discover(timeout_ms: i32) -> *mut c_char;
    pub fn sc_register(request: *const c_char) -> *mut c_char;
    pub fn sc_wakeup(credentials: *const c_char) -> bool;
    pub fn sc_psn_login_url() -> *mut c_char;
    pub fn sc_psn_redirect_url() -> *mut c_char;
    pub fn sc_psn_account_id(redirect: *const c_char) -> *mut c_char;
    pub fn sc_psn_signed_in() -> bool;
    pub fn sc_psn_consoles() -> *mut c_char;
    pub fn sc_psn_access_token() -> *mut c_char;
    pub fn sc_psn_sign_out();
    fn sc_free(p: *mut c_char);
}

/// Copies a C string out and releases it with `free`; null becomes "".
pub fn take_with(p: *mut c_char, free: unsafe extern "C" fn(*mut c_char)) -> String {
    if p.is_null() {
        return String::new();
    }
    let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    unsafe { free(p) };
    s
}

/// Takes ownership of a string returned by StreamCore.
pub fn take(p: *mut c_char) -> String {
    take_with(p, sc_free)
}

/// A C string for StreamCore; interior NULs are dropped.
pub fn cstr(s: &str) -> CString {
    CString::new(s.replace('\0', "")).unwrap()
}

/// `NativeCore` backed by the linked StreamCore library.
pub struct MacCore;

impl NativeCore for MacCore {
    fn discover(&self, timeout_ms: i32) -> String {
        take(unsafe { sc_discover(timeout_ms) })
    }
    fn register(&self, request: &str) -> String {
        take(unsafe { sc_register(cstr(request).as_ptr()) })
    }
    fn wakeup(&self, credentials: &str) -> bool {
        unsafe { sc_wakeup(cstr(credentials).as_ptr()) }
    }
    fn psn_login_url(&self) -> String {
        take(unsafe { sc_psn_login_url() })
    }
    fn psn_redirect_url(&self) -> String {
        take(unsafe { sc_psn_redirect_url() })
    }
    fn psn_account_id(&self, redirect: &str) -> String {
        take(unsafe { sc_psn_account_id(cstr(redirect).as_ptr()) })
    }
    fn set_detailed_logs(&self, on: bool) {
        unsafe { sc_set_log_detailed(on) }
    }
    fn psn_signed_in(&self) -> bool {
        unsafe { sc_psn_signed_in() }
    }
    fn secret_get(&self, key: &str) -> String {
        let key = cstr(key);
        take(unsafe { sc_secret_get(key.as_ptr()) })
    }
    fn secret_set(&self, key: &str, value: &str) -> String {
        let (key, value) = (cstr(key), cstr(value));
        take(unsafe { sc_secret_set(key.as_ptr(), value.as_ptr()) })
    }
    fn secret_remove(&self, key: &str) {
        let key = cstr(key);
        unsafe { sc_secret_remove(key.as_ptr()) }
    }
    fn psn_consoles(&self) -> String {
        take(unsafe { sc_psn_consoles() })
    }
    fn psn_access_token(&self) -> String {
        take(unsafe { sc_psn_access_token() })
    }
    fn psn_sign_out(&self) {
        unsafe { sc_psn_sign_out() }
    }
    fn session_start(&self, request: &str) -> String {
        take(unsafe { sc_session_start(cstr(request).as_ptr()) })
    }
    fn session_stop(&self) {
        unsafe { sc_session_stop() }
    }
    fn set_login_pin(&self, pin: &str) {
        unsafe { sc_session_set_login_pin(cstr(pin).as_ptr()) }
    }
    fn set_controller(&self, s: ControllerState) {
        unsafe { sc_session_set_controller(s.buttons, s.l2, s.r2, s.left_x, s.left_y, s.right_x, s.right_y) }
    }
    fn keyboard_set_text(&self, text: &str) {
        let text = CString::new(text.replace('\0', "")).unwrap_or_default();
        unsafe { sc_session_keyboard_set_text(text.as_ptr()) }
    }
    fn set_microphone(&self, on: bool) {
        unsafe { sc_session_set_mic(on) }
    }
    fn keyboard_done(&self, accept: bool) {
        unsafe { sc_session_keyboard_done(accept) }
    }
    fn set_pointer_touch(&self, t: PointerTouch) {
        unsafe { sc_session_set_pointer_touch(t.down, t.x, t.y, t.pressed) }
    }
    fn set_render_params(&self, params: &str) -> bool {
        unsafe { sc_set_render_params(cstr(params).as_ptr()) }
    }
    fn metalfx_supported(&self) -> bool {
        unsafe { sc_metalfx_supported() }
    }
    fn active_mode(&self) -> i32 {
        unsafe { sc_active_mode() }
    }
    fn gpu_milliseconds(&self) -> f64 {
        unsafe { sc_gpu_milliseconds() }
    }
    fn ml_status(&self) -> (bool, bool) {
        unsafe { (sc_ml_supported(), sc_ml_active()) }
    }
    fn hdr_active(&self) -> bool {
        unsafe { sc_hdr_active() }
    }
    fn smooth_status(&self) -> (bool, bool) {
        unsafe { (sc_smooth_supported(), sc_smooth_active()) }
    }
    fn session_stats(&self) -> String {
        take(unsafe { sc_session_stats() })
    }
}
