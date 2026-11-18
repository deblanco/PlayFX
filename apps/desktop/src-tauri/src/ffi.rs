//! C ABI exported by packages/streamcore (MacOSBridge.swift), and `MacCore`, the real `NativeCore`.

use std::ffi::{CStr, CString, c_char, c_void};

use crate::native::{ControllerState, NativeCore};

unsafe extern "C" {
    // main thread
    pub fn sc_attach_macos_window(ns_window: *mut c_void) -> bool;
    pub fn sc_set_render_params(params: *const c_char) -> bool;
    pub fn sc_metalfx_supported() -> bool;
    pub fn sc_active_mode() -> i32;
    pub fn sc_session_start(request: *const c_char) -> *mut c_char;
    pub fn sc_session_stop();
    pub fn sc_session_set_login_pin(pin: *const c_char);
    pub fn sc_session_set_controller(
        buttons: u32, l2: u8, r2: u8, left_x: i16, left_y: i16, right_x: i16, right_y: i16,
    );
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
    fn set_render_params(&self, params: &str) -> bool {
        unsafe { sc_set_render_params(cstr(params).as_ptr()) }
    }
    fn metalfx_supported(&self) -> bool {
        unsafe { sc_metalfx_supported() }
    }
    fn active_mode(&self) -> i32 {
        unsafe { sc_active_mode() }
    }
    fn session_stats(&self) -> String {
        take(unsafe { sc_session_stats() })
    }
}
