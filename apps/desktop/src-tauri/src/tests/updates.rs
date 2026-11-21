use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Mutex, mpsc};
use std::time::Duration;

use serde_json::{Value, json};
use tauri::test::{MockRuntime, mock_builder, mock_context, noop_assets};
use tauri::{App, Listener, Manager};

use super::commands::{mock, run};
use super::fake::{FakeCore, FakeUpdates};
use crate::native::CoreHandle;
use crate::updates::*;

const IDLE: &str = r#"{"active":false}"#;
const STREAMING: &str = r#"{"active":true,"framesDecoded":1}"#;

/// A mock app with `updates` behind the commands and StreamCore reporting `stats`.
fn app_with(updates: &'static FakeUpdates, stats: &str) -> App<MockRuntime> {
    let app = mock(FakeCore { stats: stats.into(), ..Default::default() }.leak());
    app.manage(UpdatesHandle { updates, endpoint: Ok(None) });
    app
}

fn version(app: &App<MockRuntime>) -> String {
    app.package_info().version.to_string()
}

#[test]
fn check_says_up_to_date_or_names_the_new_version() {
    let none = FakeUpdates::default().leak();
    let app = app_with(none, IDLE);
    assert_eq!(
        run(update_check(app.handle().clone(), false)),
        Ok(json!({"status": "upToDate", "currentVersion": version(&app)}))
    );
    assert_eq!(none.calls(), ["check default"]);
    let some = FakeUpdates::available("0.9.0").leak();
    assert_eq!(
        run(update_check(app_with(some, IDLE).handle().clone(), false)),
        Ok(json!({"status": "available", "version": "0.9.0", "currentVersion": "0.1.0"}))
    );
    // Checking is harmless during a stream: only installing waits.
    assert_eq!(run(update_check(app_with(some, STREAMING).handle().clone(), false)).map(|r| r["status"].clone()), Ok(json!("available")));
}

#[test]
fn a_failed_check_says_why() {
    let failing = FakeUpdates { check_error: Some("error sending request".into()), ..Default::default() }.leak();
    assert_eq!(run(update_check(app_with(failing, IDLE).handle().clone(), false)), Err("error sending request".into()));
}

#[test]
fn the_automatic_check_only_runs_in_release_builds() {
    let updates = FakeUpdates::available("0.9.0").leak();
    let app = app_with(updates, IDLE);
    let reply = run(update_check(app.handle().clone(), true)).expect("reply");
    assert_eq!(reply["status"], json!(if AUTOMATIC_CHECKS { "available" } else { "off" }));
    assert_eq!(updates.calls().is_empty(), !AUTOMATIC_CHECKS);
    // By hand it always asks.
    assert_eq!(run(update_check(app.handle().clone(), false)).expect("reply")["status"], json!("available"));
}

#[test]
fn the_endpoint_override_is_where_it_checks() {
    let updates = FakeUpdates::default().leak();
    let app = mock(FakeCore::default().leak());
    app.manage(UpdatesHandle { updates, endpoint: endpoint_override(Some("http://127.0.0.1:9/latest.json")) });
    assert!(run(update_check(app.handle().clone(), false)).is_ok());
    assert_eq!(updates.calls(), ["check http://127.0.0.1:9/latest.json"]);
    // An unusable one: the check says so, without asking anywhere.
    let unused = FakeUpdates::default().leak();
    let app = mock(FakeCore::default().leak());
    app.manage(UpdatesHandle { updates: unused, endpoint: endpoint_override(Some("http://example.com/latest.json")) });
    let error = run(update_check(app.handle().clone(), false)).expect_err("refused");
    assert!(error.contains("must be an https URL"), "{error}");
    assert!(unused.calls().is_empty());
}

#[test]
fn endpoint_overrides_are_https_or_on_this_mac() {
    assert_eq!(endpoint_override(None), Ok(None));
    assert_eq!(endpoint_override(Some("  ")), Ok(None));
    for good in [
        "https://example.com/latest.json",
        "http://127.0.0.1:8000/latest.json",
        "http://localhost:8000/latest.json",
        "http://[::1]:8000/latest.json",
    ] {
        assert_eq!(endpoint_override(Some(good)).map(|url| url.map(|u| u.to_string())), Ok(Some(good.to_string())), "{good}");
    }
    for bad in ["http://example.com/latest.json", "http://192.168.1.2/latest.json", "ftp://127.0.0.1/latest.json", "file:///tmp/latest.json"] {
        assert!(endpoint_override(Some(bad)).is_err(), "{bad}");
    }
    assert!(endpoint_override(Some("latest.json")).is_err_and(|e| e.contains("isn't a URL")));
}

#[test]
fn configure_updater_allows_http_only_for_a_local_override() {
    let flag = |endpoint: Option<&str>| {
        let mut context: tauri::Context<MockRuntime> = mock_context(noop_assets());
        context.config_mut().plugins.0.insert("updater".into(), json!({"pubkey": "key"}));
        configure_updater(&mut context, endpoint);
        context.config().plugins.0["updater"].get("dangerousInsecureTransportProtocol").cloned()
    };
    assert_eq!(flag(None), None);
    assert_eq!(flag(Some("https://example.com/latest.json")), None);
    assert_eq!(flag(Some("http://example.com/latest.json")), None);
    assert_eq!(flag(Some("http://127.0.0.1:8000/latest.json")), Some(json!(true)));
    // No updater configuration: nothing to change.
    let mut bare: tauri::Context<MockRuntime> = mock_context(noop_assets());
    configure_updater(&mut bare, Some("http://127.0.0.1:8000/latest.json"));
    assert!(!bare.config().plugins.0.contains_key("updater"));
}

#[test]
fn attach_updates_keeps_the_override_or_why_it_is_unusable() {
    let endpoint = |value: Option<&str>| {
        let app = mock(FakeCore::default().leak());
        attach_updates(app.handle(), value);
        app.state::<UpdatesHandle>().endpoint.clone().map(|url| url.map(|u| u.to_string()))
    };
    assert_eq!(endpoint(None), Ok(None));
    assert_eq!(endpoint(Some("http://127.0.0.1:8000/latest.json")), Ok(Some("http://127.0.0.1:8000/latest.json".into())));
    assert!(endpoint(Some("http://example.com/latest.json")).is_err());
}

/// The "update-progress" payloads, as they arrive.
fn progress_events(app: &App<MockRuntime>) -> mpsc::Receiver<Value> {
    let (tx, rx) = mpsc::channel();
    app.listen_any(PROGRESS_EVENT, move |event| {
        let _ = tx.send(serde_json::from_str::<Value>(event.payload()).unwrap_or(Value::Null));
    });
    rx
}

#[test]
fn install_downloads_then_installs_reporting_each_percent_once() {
    let updates = FakeUpdates::available("0.9.0").leak();
    let app = app_with(updates, IDLE);
    let events = progress_events(&app);
    assert_eq!(run(update_install(app.handle().clone())), Ok(()));
    assert_eq!(updates.calls(), ["download", "install update"]);
    let percents: Vec<Value> =
        (0..10).map(|_| events.recv_timeout(Duration::from_secs(5)).expect("progress")["percent"].clone()).collect();
    assert_eq!(percents, (1..=10).map(|n| json!(n * 10)).collect::<Vec<_>>());
    // 100% came twice from the download, and is sent once.
    assert!(events.recv_timeout(Duration::from_millis(200)).is_err());
}

#[test]
fn nothing_installs_or_restarts_during_a_stream() {
    let updates = FakeUpdates::available("0.9.0").leak();
    // A running stream, or a reply that can't be read (counted as one).
    for stats in [STREAMING, "not json", r#"{"frames":1}"#] {
        let app = app_with(updates, stats);
        assert_eq!(run(update_install(app.handle().clone())), Err(FINISH_PLAYING.into()), "{stats}");
        assert_eq!(update_restart(app.handle().clone()), Err(FINISH_PLAYING.into()), "{stats}");
    }
    assert!(updates.calls().is_empty());
    // A stream started while it downloaded: downloaded, never installed.
    let late = FakeUpdates::available("0.9.0").leak();
    let core = FakeCore { stats: STREAMING.into(), stats_first: Mutex::new([IDLE.to_string()].into()), ..Default::default() };
    let app = mock(core.leak());
    app.manage(UpdatesHandle { updates: late, endpoint: Ok(None) });
    assert_eq!(run(update_install(app.handle().clone())), Err(FINISH_PLAYING.into()));
    assert_eq!(late.calls(), ["download"]);
}

#[test]
fn failed_downloads_and_installs_say_why() {
    let download = FakeUpdates { download_error: Some("Download request failed with status: 404".into()), ..FakeUpdates::available("0.9.0") }.leak();
    assert_eq!(
        run(update_install(app_with(download, IDLE).handle().clone())),
        Err("Download request failed with status: 404".into())
    );
    assert_eq!(download.calls(), ["download"]);
    let install = FakeUpdates { install_error: Some("Permission denied (os error 13)".into()), ..FakeUpdates::available("0.9.0") }.leak();
    assert_eq!(run(update_install(app_with(install, IDLE).handle().clone())), Err("Permission denied (os error 13)".into()));
    assert_eq!(install.calls(), ["download", "install update"]);
}

#[test]
fn restart_opens_the_new_version_when_no_stream_runs() {
    let updates = FakeUpdates::available("0.9.0").leak();
    assert_eq!(update_restart(app_with(updates, IDLE).handle().clone()), Ok(()));
    assert_eq!(updates.calls(), ["restart"]);
}

#[test]
fn release_pages_open_on_github_for_versions_only() {
    for good in ["0.2.5", "1.0.0-beta.1"] {
        assert_eq!(open_release_page(good.into()), Ok(()));
        let url = format!("https://github.com/deblanco/PlayFX/releases/tag/v{good}");
        assert!(super::OPENED.lock().expect("opened").contains(&url), "{url}");
    }
    for bad in ["", "v0.2.5", "0.2.5/../../evil", "0.2.5?x=1", "../0.2.5", " 0.2.5", "0.2.5 && open"] {
        assert!(open_release_page(bad.into()).is_err(), "{bad}");
    }
}

#[test]
fn percent_of_a_known_size() {
    assert_eq!(percent(0, Some(200)), Some(0));
    assert_eq!(percent(50, Some(200)), Some(25));
    assert_eq!(percent(199, Some(200)), Some(99));
    assert_eq!(percent(200, Some(200)), Some(100));
    assert_eq!(percent(300, Some(200)), Some(100));
    assert_eq!(percent(5, None), None);
    assert_eq!(percent(5, Some(0)), None);
}

// The real plugin against a local server, with an update made by release.sh's own `make_update` (fixtures/: a
// PlayFX.app holding Contents/marker, as 9.9.9) and signed with a throwaway key from `tauri signer generate`, whose
// private half isn't kept anywhere. Checks and downloads only: installing would replace the test binary's folder.

const TEST_PUBKEY: &str = include_str!("fixtures/updater-test.pub");
const UPDATE: &[u8] = include_bytes!("fixtures/update.app.tar.gz");
const SIGNATURE: &str = include_str!("fixtures/update.app.tar.gz.sig");

/// A listener on 127.0.0.1 and its base URL.
fn server() -> (TcpListener, String) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let base = format!("http://{}", listener.local_addr().expect("address"));
    (listener, base)
}

/// Serves `routes` (path → body) until the test process ends; any other path is a 404.
fn serve(listener: TcpListener, routes: Vec<(&'static str, Vec<u8>)>) {
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            respond(stream, &routes);
        }
    });
}

fn respond(mut stream: TcpStream, routes: &[(&'static str, Vec<u8>)]) {
    let mut request = Vec::new();
    let mut buffer = [0u8; 1024];
    while !request.windows(4).any(|w| w == b"\r\n\r\n") {
        match stream.read(&mut buffer) {
            Ok(0) | Err(_) => return,
            Ok(n) => request.extend_from_slice(&buffer[..n]),
        }
    }
    let text = String::from_utf8_lossy(&request);
    let path = text.split_whitespace().nth(1).unwrap_or_default();
    let (status, body) = routes.iter().find(|(p, _)| *p == path).map_or(("404 Not Found", &[][..]), |(_, b)| ("200 OK", b));
    let head = format!("HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
    let _ = stream.write_all(head.as_bytes()).and_then(|()| stream.write_all(body));
}

/// latest.json as release.sh writes it.
fn manifest(base: &str, version: &str, signature: &str) -> Vec<u8> {
    json!({
        "version": version,
        "notes": format!("See https://github.com/deblanco/PlayFX/releases/tag/v{version}"),
        "pub_date": "2026-11-21T12:00:00Z",
        "platforms": {"darwin-aarch64": {"signature": signature.trim(), "url": format!("{base}/PlayFX_{version}_aarch64.app.tar.gz")}},
    })
    .to_string()
    .into_bytes()
}

/// A mock app with the real updater plugin, configured like tauri.conf.json but with the test key.
fn plugin_app(endpoint: &str) -> App<MockRuntime> {
    let mut context = mock_context(noop_assets());
    context.config_mut().plugins.0.insert(
        "updater".into(),
        json!({"pubkey": TEST_PUBKEY.trim(), "endpoints": [endpoint], "requireSignedVersion": true}),
    );
    mock_builder().plugin(updater_plugin()).build(context).expect("app with the updater")
}

#[test]
fn the_plugin_finds_downloads_and_verifies_a_signed_release() {
    let (listener, base) = server();
    serve(listener, vec![("/latest.json", manifest(&base, "9.9.9", SIGNATURE)), ("/PlayFX_9.9.9_aarch64.app.tar.gz", UPDATE.to_vec())]);
    let app = plugin_app(&format!("{base}/latest.json"));
    let updates = PluginUpdates::new(app.handle().clone());
    assert_eq!(updates.download(&mut |_, _| {}), Err("No update found: check for updates first".into()));
    assert_eq!(updates.check(None), Ok(Some(Available { version: "9.9.9".into(), current_version: version(&app) })));
    let mut seen = Vec::new();
    assert_eq!(updates.download(&mut |done, total| seen.push((done, total))).as_deref(), Ok(UPDATE));
    let size = UPDATE.len() as u64;
    assert_eq!(seen.last(), Some(&(size, Some(size))));
    // Through the command too (the plugin's async calls then run on the blocking pool).
    let real: &'static PluginUpdates<MockRuntime> = Box::leak(Box::new(PluginUpdates::new(app.handle().clone())));
    app.manage(UpdatesHandle { updates: real, endpoint: Ok(None) });
    app.manage(CoreHandle(FakeCore { stats: IDLE.into(), ..Default::default() }.leak()));
    assert_eq!(run(update_check(app.handle().clone(), false)).map(|r| r["version"].clone()), Ok(json!("9.9.9")));
}

#[test]
fn the_plugin_rejects_a_tampered_update_or_a_relabelled_one() {
    let (listener, base) = server();
    let mut tampered = UPDATE.to_vec();
    if let Some(last) = tampered.last_mut() {
        *last ^= 1;
    }
    serve(
        listener,
        vec![
            ("/tampered.json", manifest(&base, "9.9.9", SIGNATURE)),
            ("/PlayFX_9.9.9_aarch64.app.tar.gz", tampered),
            // 9.9.9's genuine update announced as 9.9.10: the signature names the version it was made for.
            ("/relabelled.json", manifest(&base, "9.9.10", SIGNATURE)),
            ("/PlayFX_9.9.10_aarch64.app.tar.gz", UPDATE.to_vec()),
        ],
    );
    let app = plugin_app(&format!("{base}/tampered.json"));
    let updates = PluginUpdates::new(app.handle().clone());
    assert!(updates.check(None).is_ok_and(|found| found.is_some()));
    let error = updates.download(&mut |_, _| {}).expect_err("tampered");
    assert!(error.to_lowercase().contains("signature"), "{error}");
    let relabelled: tauri::Url = format!("{base}/relabelled.json").parse().expect("url");
    assert!(updates.check(Some(relabelled)).is_ok_and(|found| found.is_some_and(|f| f.version == "9.9.10")));
    let error = updates.download(&mut |_, _| {}).expect_err("relabelled");
    assert!(error.contains("signed for version 9.9.9"), "{error}");
}

#[test]
fn the_plugin_says_up_to_date_or_why_it_could_not_check() {
    let (listener, base) = server();
    serve(listener, vec![("/old.json", manifest(&base, "0.0.1", SIGNATURE))]);
    let app = plugin_app(&format!("{base}/old.json"));
    let updates = PluginUpdates::new(app.handle().clone());
    assert_eq!(updates.check(None), Ok(None));
    // The override replaces the configured endpoint: here one with no manifest.
    let missing: tauri::Url = format!("{base}/missing.json").parse().expect("url");
    assert!(updates.check(Some(missing)).is_err());
}

#[test]
fn the_shipped_configuration_checks_github_with_the_release_key() {
    let real: tauri::Context<MockRuntime> = tauri::generate_context!(test = true);
    let updater = &real.config().plugins.0["updater"];
    assert_eq!(updater["endpoints"], json!(["https://github.com/deblanco/PlayFX/releases/latest/download/latest.json"]));
    assert_eq!(updater["requireSignedVersion"], json!(true));
    assert!(updater.get("dangerousInsecureTransportProtocol").is_none());
    // The public half of the key in the owner's keychain (a minisign public key, base64 like the .pub file).
    assert!(updater["pubkey"].as_str().is_some_and(|key| key.starts_with("dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IERDNDE")));
    // The plugin takes it as it is.
    let mut context = mock_context(noop_assets());
    context.config_mut().plugins = real.config().plugins.clone();
    let app = mock_builder().plugin(updater_plugin()).build(context).expect("app with the shipped configuration");
    use tauri_plugin_updater::UpdaterExt;
    assert!(app.updater().is_ok());
}
