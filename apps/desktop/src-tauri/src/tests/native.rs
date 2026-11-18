use serde_json::{Value, json};

use super::fake::FakeCore;
use crate::native::*;

#[test]
fn reply_passes_values_through() {
    assert_eq!(reply(r#"{"ok":true}"#), Ok(json!({"ok": true})));
    assert_eq!(reply("[1,2]"), Ok(json!([1, 2])));
}

#[test]
fn reply_maps_error_field_to_err() {
    assert_eq!(reply(r#"{"error":"boom"}"#), Err("boom".to_string()));
}

#[test]
fn reply_ignores_non_string_error_field() {
    assert_eq!(reply(r#"{"error":true}"#), Ok(json!({"error": true})));
}

#[test]
fn reply_rejects_invalid_json() {
    let err = reply("").unwrap_err();
    assert!(err.starts_with("bad reply from core: "), "{err}");
}

#[test]
fn with_psn_token_adds_the_token_only_for_internet_play() {
    let core = FakeCore { psn_token: r#"{"token":"tok"}"#.into(), ..Default::default() }.leak();
    let lan = json!({"credentials": {}, "options": {}});
    assert_eq!(with_psn_token(core, lan.clone()), Ok(lan));
    assert_eq!(
        with_psn_token(core, json!({"credentials": {}, "remote": {"duid": "ab"}})),
        Ok(json!({"credentials": {}, "remote": {"duid": "ab", "token": "tok"}}))
    );
    let expired = FakeCore { psn_token: r#"{"error":"Sign in again"}"#.into(), ..Default::default() }.leak();
    assert_eq!(with_psn_token(expired, json!({"remote": {"duid": "ab"}})), Err("Sign in again".into()));
    let odd = FakeCore { psn_token: "{}".into(), ..Default::default() }.leak();
    assert_eq!(with_psn_token(odd, json!({"remote": {"duid": "ab"}})), Err("no PSN token in reply".into()));
}

#[test]
fn tail_keeps_the_last_lines() {
    assert_eq!(tail_lines("a\nb\nc\n", 2), "b\nc");
    assert_eq!(tail_lines("only", 5), "only");
    assert_eq!(tail_lines("", 3), "");
}

#[test]
fn native_levels_map_to_log_levels() {
    assert_eq!(native_level(0), log::Level::Debug);
    assert_eq!(native_level(1), log::Level::Info);
    assert_eq!(native_level(2), log::Level::Warn);
    assert_eq!(native_level(3), log::Level::Error);
    assert_eq!(native_level(9), log::Level::Error);
}

#[test]
fn mode_name_maps_numbers() {
    assert_eq!(mode_name(0), "bilinear");
    assert_eq!(mode_name(1), "metalfx");
    assert_eq!(mode_name(2), "none");
    assert_eq!(mode_name(-1), "none");
    assert_eq!(mode_name(7), "none");
}

#[test]
fn renderer_status_json_assembles_reply() {
    assert_eq!(
        renderer_status_json(
            &RendererState { metalfx_supported: true, active_mode: 1, gpu_ms: 1.23456, ml: (true, false), smooth: (true, true), hdr: true },
            r#"{"active":false}"#
        ),
        json!({"metalfxSupported": true, "activeMode": "metalfx", "gpuMs": 1.23, "mlSupported": true, "mlActive": false, "smoothSupported": true, "smoothActive": true, "hdrActive": true, "stream": {"active": false}})
    );
    assert_eq!(
        renderer_status_json(
            &RendererState { metalfx_supported: false, active_mode: -1, gpu_ms: 0.0, ml: (false, false), smooth: (false, false), hdr: false },
            "not json"
        ),
        json!({"metalfxSupported": false, "activeMode": "none", "gpuMs": 0.0, "mlSupported": false, "mlActive": false, "smoothSupported": false, "smoothActive": false, "hdrActive": false, "stream": Value::Null})
    );
}

#[test]
fn is_psn_redirect_matches_prefix() {
    let redirect = "https://remoteplay.dl.playstation.net/remoteplay/redirect";
    assert!(is_psn_redirect(&format!("{redirect}?code=abc"), redirect));
    assert!(!is_psn_redirect("https://my.account.sony.com/signin", redirect));
}

#[test]
fn parse_event_accepts_only_json() {
    assert_eq!(parse_event(r#"{"type":"connected"}"#), Some(json!({"type": "connected"})));
    assert_eq!(parse_event("nope"), None);
}

#[test]
fn psn_account_returns_account_or_error_payload() {
    let ok = FakeCore { reply: r#"{"accountId":"AAAA"}"#.into(), ..Default::default() };
    assert_eq!(psn_account(&ok, "u?code=1"), json!({"accountId": "AAAA"}));
    assert_eq!(ok.calls(), ["psn_account_id u?code=1"]);

    let failed = FakeCore { reply: r#"{"error":"No sign-in code in URL"}"#.into(), ..Default::default() };
    assert_eq!(psn_account(&failed, "u"), json!({"error": "No sign-in code in URL"}));

    let garbage = FakeCore::default();
    let err = psn_account(&garbage, "u");
    assert!(err["error"].as_str().unwrap().starts_with("bad reply from core"));
}
