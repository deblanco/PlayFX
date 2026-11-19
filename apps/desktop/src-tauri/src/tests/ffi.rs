use std::ffi::{CString, c_char};
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::json;

use crate::ffi::*;
use crate::native::{NativeCore, reply};

static FREED: AtomicUsize = AtomicUsize::new(0);

unsafe extern "C" fn free_cstring(p: *mut c_char) {
    drop(unsafe { CString::from_raw(p) });
    FREED.fetch_add(1, Ordering::SeqCst);
}

#[test]
fn take_with_copies_and_frees() {
    let before = FREED.load(Ordering::SeqCst);
    let p = CString::new("héllo").unwrap().into_raw();
    assert_eq!(take_with(p, free_cstring), "héllo");
    assert_eq!(FREED.load(Ordering::SeqCst), before + 1);
}

unsafe extern "C" fn must_not_free(_: *mut c_char) {
    panic!("null must not be freed");
}

#[test]
fn take_with_null_is_empty_and_frees_nothing() {
    assert_eq!(take_with(std::ptr::null_mut(), must_not_free), "");
    assert_eq!(take(std::ptr::null_mut()), "");
}

#[test]
fn cstr_strips_interior_nuls() {
    assert_eq!(cstr("a\0b\0").as_bytes(), b"ab");
    assert_eq!(cstr("{}").as_bytes(), b"{}");
}

/// Exercises the real StreamCore with no renderer, no session and invalid input: nothing here
/// touches the network or a console. `sc_discover` (UDP broadcast) is deliberately not called.
#[test]
fn mac_core_without_session_or_renderer() {
    let core = MacCore;
    let login: tauri::Url = core.psn_login_url().parse().expect("login URL");
    assert_eq!(login.scheme(), "https");
    assert!(!core.psn_redirect_url().is_empty());
    assert!(reply(&core.psn_account_id("https://example.invalid/no-code")).is_err());
    assert!(reply(&core.register("{}")).is_err());
    assert!(!core.wakeup("{}"));
    assert!(reply(&core.session_start("{}")).is_err());
    core.set_login_pin("1234");
    assert!(core.set_render_params(r#"{"upscaler":"metalfx"}"#)); // no renderer: accepted, no-op
    assert!(!core.set_render_params(r#"{"upscaler":"fsr"}"#));
    assert!(!core.metalfx_supported());
    assert_eq!(core.active_mode(), -1);
    assert_eq!(core.gpu_milliseconds(), 0.0);
    assert_eq!(core.ml_status(), (false, false)); // no renderer attached
    assert_eq!(core.interpolation_status(), (false, false));
    assert!(!core.hdr_active());
    assert_eq!(core.display_milliseconds(), 0.0);
    assert_eq!(core.shown_fps(), 0.0);
    assert_eq!(reply(&core.pacing_stats()).map(|v| v["skippedFrames"].clone()), Ok(json!(0)));
    assert_eq!(reply(&core.session_stats()), Ok(json!({"active": false})));
    // Input without a session is dropped.
    core.set_controller(crate::native::ControllerState::default());
    core.set_pointer_touch(crate::native::PointerTouch { down: false, x: 0.0, y: 0.0, pressed: false });
    core.keyboard_set_text("a\0b");
    core.keyboard_done(false);
    core.set_microphone(false);
    core.set_detailed_logs(false);
    assert!(reply(&core.audio_devices()).is_ok());
    // Read-only: whether a PSN sign-in is kept, and a key no one ever writes.
    let _ = core.psn_signed_in();
    assert_eq!(reply(&core.secret_get("playfx-test-never-written")), Ok(json!({"value": null})));
    core.session_sleep(); // no session: nothing to put to sleep
    // A direct probe of an address nothing answers on (TEST-NET-1): no consoles, quickly.
    assert_eq!(reply(&core.discover_host("192.0.2.1", 100)), Ok(json!([])));
    core.session_stop();
}
