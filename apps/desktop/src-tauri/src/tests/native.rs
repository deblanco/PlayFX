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
fn upscale_mode_parses_known_names() {
    assert_eq!(upscale_mode("bilinear"), Ok(0));
    assert_eq!(upscale_mode("metalfx"), Ok(1));
    assert_eq!(upscale_mode("compare"), Ok(2));
    assert_eq!(upscale_mode("fsr"), Err("unknown upscaler: fsr".to_string()));
}

#[test]
fn mode_name_maps_numbers() {
    assert_eq!(mode_name(0), "bilinear");
    assert_eq!(mode_name(1), "metalfx");
    assert_eq!(mode_name(2), "compare");
    assert_eq!(mode_name(-1), "none");
    assert_eq!(mode_name(7), "none");
}

#[test]
fn renderer_status_json_assembles_reply() {
    assert_eq!(
        renderer_status_json(true, 1, r#"{"active":false}"#),
        json!({"metalfxSupported": true, "activeMode": "metalfx", "stream": {"active": false}})
    );
    assert_eq!(
        renderer_status_json(false, -1, "not json"),
        json!({"metalfxSupported": false, "activeMode": "none", "stream": Value::Null})
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
