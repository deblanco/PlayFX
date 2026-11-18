use std::sync::mpsc;
use std::time::Duration;

use serde_json::{Value, json};
use tauri::test::{INVOKE_KEY, MockRuntime, get_ipc_response, mock_builder, mock_context, noop_assets};
use tauri::webview::InvokeRequest;
use tauri::{App, Listener, Manager, WebviewUrl, WebviewWindowBuilder};

use super::fake::FakeCore;
use crate::native::CoreHandle;
use crate::*;

const REDIRECT: &str = "https://remoteplay.dl.playstation.net/remoteplay/redirect";

fn mock(core: &'static FakeCore) -> App<MockRuntime> {
    let app = with_commands(mock_builder()).build(mock_context(noop_assets())).expect("mock app");
    app.manage(CoreHandle(core));
    app
}

fn ok_reply() -> &'static FakeCore {
    FakeCore { reply: r#"{"ok":true}"#.into(), ..Default::default() }.leak()
}

fn err_reply() -> &'static FakeCore {
    FakeCore { reply: r#"{"error":"nope"}"#.into(), ..Default::default() }.leak()
}

/// Invokes `cmd` through the IPC layer, as the React UI does.
fn invoke(app: &App<MockRuntime>, cmd: &str, args: Value) -> Result<Value, Value> {
    let webview = match app.get_webview_window("main") {
        Some(w) => w,
        None => WebviewWindowBuilder::new(app, "main", WebviewUrl::default()).build().expect("webview"),
    };
    get_ipc_response(
        &webview,
        InvokeRequest {
            cmd: cmd.into(),
            callback: tauri::ipc::CallbackFn(0),
            error: tauri::ipc::CallbackFn(1),
            url: "tauri://localhost".parse().unwrap(),
            body: tauri::ipc::InvokeBody::Json(args),
            headers: Default::default(),
            invoke_key: INVOKE_KEY.to_string(),
        },
    )
    .map(|body| body.deserialize::<Value>().expect("json body"))
}

#[test]
fn discover_replies_and_maps_errors() {
    let core = ok_reply();
    assert_eq!(discover(mock(core).handle().clone()), Ok(json!({"ok": true})));
    assert_eq!(core.calls(), ["discover 1500"]);
    assert_eq!(discover(mock(err_reply()).handle().clone()), Err("nope".into()));
}

#[test]
fn register_console_forwards_request_json() {
    let core = ok_reply();
    let app = mock(core);
    let request = json!({"address": "10.0.0.2", "ps5": true, "accountId": "x", "pin": "12345678"});
    assert_eq!(register_console(app.handle().clone(), request.clone()), Ok(json!({"ok": true})));
    assert_eq!(core.calls(), [format!("register {request}")]);
}

#[test]
fn wakeup_forwards_credentials() {
    let core = FakeCore { wakeup_ok: true, ..Default::default() }.leak();
    assert!(wakeup(mock(core).handle().clone(), json!({"host": "h"})));
    assert_eq!(core.calls(), [r#"wakeup {"host":"h"}"#]);
}

#[test]
fn start_stream_runs_session_start_on_main() {
    let core = ok_reply();
    let app = mock(core);
    assert_eq!(start_stream(app.handle().clone(), json!({"a": 1})), Ok(json!({"ok": true})));
    assert_eq!(core.calls(), [r#"session_start {"a":1}"#]);
    assert_eq!(start_stream(mock(err_reply()).handle().clone(), json!({})), Err("nope".into()));
}

#[test]
fn session_commands_reach_the_core() {
    let core = FakeCore::default().leak();
    let app = mock(core);
    assert_eq!(stop_stream(app.handle().clone()), Ok(()));
    assert_eq!(set_login_pin(app.handle().clone(), "1234".into()), Ok(()));
    assert_eq!(set_controller(app.handle().clone(), json!({"buttons": 1, "l2": 0, "r2": 0, "leftX": 0, "leftY": 0, "rightX": 0, "rightY": 0})), Ok(()));
    assert!(set_controller(app.handle().clone(), json!({"buttons": "x"})).is_err());
    assert_eq!(
        set_pointer_touch(app.handle().clone(), json!({"down": true, "x": 0.5, "y": 0.25, "pressed": false})),
        Ok(())
    );
    assert!(set_pointer_touch(app.handle().clone(), json!({"down": "yes"})).is_err());
    assert_eq!(keyboard_set_text(app.handle().clone(), "hello".into()), Ok(()));
    assert_eq!(keyboard_done(app.handle().clone(), true), Ok(()));
    assert_eq!(set_microphone(app.handle().clone(), true), Ok(()));
    assert_eq!(set_render_params(app.handle().clone(), json!({"upscaler": "metalfx"})), Ok(()));
    assert_eq!(
        set_render_params(app.handle().clone(), json!({"upscaler": "fsr"})),
        Err(r#"invalid picture settings: {"upscaler":"fsr"}"#.into())
    );
    assert_eq!(
        core.calls(),
        ["session_stop", "set_login_pin 1234", "set_controller 1", "set_pointer_touch true 0.5 0.25 false", "keyboard_set_text hello", "keyboard_done true", "set_microphone true",
         r#"set_render_params {"upscaler":"metalfx"}"#, r#"set_render_params {"upscaler":"fsr"}"#]
    );
}

#[test]
fn renderer_status_reports_core_state() {
    let core =
        FakeCore { metalfx: true, mode: 0, gpu_ms: 2.5, ml: (true, true), smooth: (true, false), stats: r#"{"active":true}"#.into(), ..Default::default() }
            .leak();
    assert_eq!(
        renderer_status(mock(core).handle().clone()),
        Ok(json!({
            "metalfxSupported": true, "activeMode": "bilinear", "gpuMs": 2.5, "mlSupported": true, "mlActive": true,
            "smoothSupported": true, "smoothActive": false, "hdrActive": false, "stream": {"active": true}
        }))
    );
}

#[test]
fn on_main_runs_closure_and_returns_value() {
    let app = mock(FakeCore::default().leak());
    assert_eq!(on_main(app.handle(), || 41 + 1), Ok(42));
}

#[test]
fn psn_login_opens_sign_in_window() {
    let core = FakeCore {
        login_url: "https://my.account.sony.com/signin".into(),
        redirect_url: REDIRECT.into(),
        ..Default::default()
    }
    .leak();
    let app = mock(core);
    assert_eq!(psn_login(app.handle().clone()), Ok(()));
    assert!(app.get_webview_window(PSN_WINDOW).is_some());
    let window = app.get_webview_window(PSN_WINDOW).expect("sign-in window");
    window.navigate("https://my.account.sony.com/elsewhere".parse().expect("url")).expect("navigate");
    // A second call reuses the open window (restarting sign-in) instead of closing it and
    // rebuilding under the same label, which fails while the asynchronous close is pending.
    assert_eq!(psn_login(app.handle().clone()), Ok(()));
    let url = app.get_webview_window(PSN_WINDOW).expect("sign-in window").url().expect("url");
    assert_eq!(url.as_str(), "https://my.account.sony.com/signin");
}

#[test]
fn psn_tokens_status_and_sign_out() {
    let core = FakeCore { psn_signed_in: true, ..Default::default() }.leak();
    let app = mock(core);
    assert!(psn_signed_in(app.handle().clone()));
    psn_sign_out(app.handle().clone());
    assert_eq!(core.calls(), ["psn_sign_out"]);
}

#[test]
fn psn_consoles_replies_or_maps_errors() {
    assert_eq!(psn_consoles(mock(ok_reply()).handle().clone()), Ok(json!({"ok": true})));
    assert_eq!(psn_consoles(mock(err_reply()).handle().clone()), Err("nope".into()));
}

#[test]
fn diagnostics_and_detailed_logs() {
    let core = FakeCore::default().leak();
    let app = mock(core);
    set_detailed_logs(app.handle().clone(), true);
    assert_eq!(core.calls(), ["set_detailed_logs true"]);
    let report = diagnostics(app.handle().clone()).expect("diagnostics");
    assert!(report["os"].as_str().is_some_and(|os| os.starts_with("macOS")));
    assert!(report["logFolder"].as_str().is_some_and(|dir| !dir.is_empty()));
    assert!(report["recentLog"].is_string());
}

#[test]
fn toggle_fullscreen_needs_the_main_window() {
    let app = mock(FakeCore::default().leak());
    assert_eq!(toggle_fullscreen(app.handle().clone()), Err("no main window".into()));
    WebviewWindowBuilder::new(&app, "main", WebviewUrl::default()).build().expect("webview");
    assert!(toggle_fullscreen(app.handle().clone()).is_ok());
}

#[test]
fn psn_login_rejects_bad_login_url() {
    let core = FakeCore { login_url: "not a url".into(), ..Default::default() }.leak();
    let err = psn_login(mock(core).handle().clone()).unwrap_err();
    assert!(err.contains("relative URL"), "{err}");
}

/// Waits for the next "psn-account" payload.
fn psn_account_events(app: &App<MockRuntime>) -> mpsc::Receiver<Value> {
    let (tx, rx) = mpsc::channel();
    app.listen_any("psn-account", move |event| {
        let _ = tx.send(serde_json::from_str::<Value>(event.payload()).unwrap_or(Value::Null));
    });
    rx
}

#[test]
fn psn_navigation_allows_other_pages() {
    let core = FakeCore::default().leak();
    let app = mock(core);
    assert!(on_psn_navigation(app.handle(), REDIRECT, "https://my.account.sony.com/signin"));
    assert!(core.calls().is_empty());
}

#[test]
fn psn_navigation_to_redirect_emits_account_and_closes_window() {
    let core = FakeCore {
        login_url: "https://my.account.sony.com/signin".into(),
        redirect_url: REDIRECT.into(),
        reply: r#"{"accountId":"AAAA"}"#.into(),
        ..Default::default()
    }
    .leak();
    let app = mock(core);
    let events = psn_account_events(&app);
    psn_login(app.handle().clone()).unwrap();
    let url = format!("{REDIRECT}?code=abc");
    assert!(!on_psn_navigation(app.handle(), REDIRECT, &url));
    assert_eq!(events.recv_timeout(Duration::from_secs(5)), Ok(json!({"accountId": "AAAA"})));
    assert_eq!(core.calls(), [format!("psn_account_id {url}")]);
}

#[test]
fn finish_psn_login_emits_error_payload() {
    let app = mock(err_reply());
    let events = psn_account_events(&app);
    finish_psn_login(app.handle(), "u");
    assert_eq!(events.recv_timeout(Duration::from_secs(5)), Ok(json!({"error": "nope"})));
}

#[test]
fn on_stream_event_without_app_is_a_no_op() {
    let json = std::ffi::CString::new(r#"{"type":"connected"}"#).unwrap();
    on_stream_event(json.as_ptr());
}

#[test]
fn ipc_contract_matches_the_ui() {
    let core = FakeCore {
        reply: r#"{"ok":true}"#.into(),
        wakeup_ok: true,
        stats: r#"{"active":false}"#.into(),
        mode: -1,
        ..Default::default()
    }
    .leak();
    let app = mock(core);
    assert_eq!(invoke(&app, "discover", json!({})), Ok(json!({"ok": true})));
    assert_eq!(invoke(&app, "register_console", json!({"request": {"pin": "1"}})), Ok(json!({"ok": true})));
    assert_eq!(invoke(&app, "wakeup", json!({"credentials": {}})), Ok(json!(true)));
    assert_eq!(invoke(&app, "start_stream", json!({"request": {}})), Ok(json!({"ok": true})));
    assert_eq!(invoke(&app, "stop_stream", json!({})), Ok(Value::Null));
    assert_eq!(invoke(&app, "set_login_pin", json!({"pin": "1234"})), Ok(Value::Null));
    assert_eq!(
        invoke(&app, "set_controller", json!({"state": {"buttons": 3, "l2": 0, "r2": 0, "leftX": 0, "leftY": 0, "rightX": 0, "rightY": 0}})),
        Ok(Value::Null)
    );
    assert_eq!(invoke(&app, "set_render_params", json!({"params": {"sharpness": 0.5}})), Ok(Value::Null));
    assert_eq!(
        invoke(&app, "set_render_params", json!({"params": {"upscaler": "fsr"}})),
        Err(json!(r#"invalid picture settings: {"upscaler":"fsr"}"#))
    );
    assert_eq!(
        invoke(&app, "renderer_status", json!({})),
        Ok(json!({
            "metalfxSupported": false, "activeMode": "none", "gpuMs": 0.0, "mlSupported": false, "mlActive": false,
            "smoothSupported": false, "smoothActive": false, "hdrActive": false, "stream": {"active": false}
        }))
    );
}

#[test]
fn ipc_rejects_missing_arguments() {
    let app = mock(FakeCore::default().leak());
    for cmd in ["register_console", "wakeup", "start_stream", "set_login_pin", "set_render_params"] {
        let err = invoke(&app, cmd, json!({})).expect_err(cmd);
        assert!(err.as_str().is_some_and(|e| e.contains("missing required key")), "{cmd}: {err}");
    }
}

#[test]
fn ipc_psn_login_reports_bad_login_url() {
    let app = mock(FakeCore { login_url: "not a url".into(), ..Default::default() }.leak());
    assert_eq!(invoke(&app, "psn_login", json!({})), Err(json!("relative URL without a base")));
}

#[test]
fn ipc_psn_login_reuses_open_window() {
    let app = mock(FakeCore { login_url: "https://my.account.sony.com/signin".into(), ..Default::default() }.leak());
    assert_eq!(invoke(&app, "psn_login", json!({})), Ok(Value::Null));
    assert_eq!(invoke(&app, "psn_login", json!({})), Ok(Value::Null));
    assert!(app.get_webview_window(PSN_WINDOW).is_some());
}
