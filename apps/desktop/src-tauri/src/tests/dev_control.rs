use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

use serde_json::{Value, json};
use tauri::test::{mock_builder, mock_context, noop_assets};
use tauri::{Listener, Manager, WebviewUrl, WebviewWindowBuilder};

use super::fake::FakeCore;
use crate::dev_control::*;
use crate::native::CoreHandle;
use crate::*;

/// Records what the port asked of the app.
#[derive(Default)]
struct FakeHost {
    calls: Mutex<Vec<String>>,
    fail: bool,
}

impl DevHost for FakeHost {
    fn status(&self) -> Result<Value, String> {
        if self.fail { Err("no renderer".into()) } else { Ok(json!({"shownFps": 60.0})) }
    }
    fn press(&self, buttons: u32, ms: u64) -> Result<(), String> {
        self.calls.lock().unwrap().push(format!("press {buttons} {ms}"));
        Ok(())
    }
    fn fullscreen(&self) -> Result<bool, String> {
        Ok(true)
    }
    fn emit(&self, command: Value) -> Result<(), String> {
        self.calls.lock().unwrap().push(command.to_string());
        Ok(())
    }
}

fn request(method: &str, target: &str, body: &str) -> Request {
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    Request { method: method.into(), path: path.into(), query: query.into(), body: body.into() }
}

#[test]
fn port_comes_from_the_env_value() {
    assert_eq!(port(Some("7780")), Some(7780));
    assert_eq!(port(Some(" 7780\n")), Some(7780));
    assert_eq!(port(Some("80")), None); // privileged ports are refused
    assert_eq!(port(Some("yes")), None);
    assert_eq!(port(None), None);
}

#[test]
fn buttons_by_name() {
    assert_eq!(button_bits("options"), Ok(1 << 12));
    assert_eq!(button_bits("Cross, r1"), Ok(1 | 1 << 9));
    assert!(button_bits("jump").unwrap_err().contains("unknown button jump"));
    assert!(button_bits("").is_err());
}

#[test]
fn routes_reach_the_host() {
    let host = FakeHost::default();
    assert_eq!(handle(&host, &request("GET", "/status", "")), (200, json!({"shownFps": 60.0})));
    assert_eq!(handle(&host, &request("POST", "/settings", r#"{"view":"original"}"#)), (200, json!({"ok": true})));
    assert_eq!(handle(&host, &request("POST", "/play", "")).0, 200);
    assert_eq!(handle(&host, &request("POST", "/reconnect", "")).0, 200);
    assert_eq!(handle(&host, &request("POST", "/fullscreen", "")), (200, json!({"fullscreen": true})));
    assert_eq!(handle(&host, &request("POST", "/press?buttons=options&ms=80", "")).0, 200);
    assert_eq!(handle(&host, &request("POST", "/press?buttons=cross&ms=99999", "")).0, 200); // capped
    assert_eq!(*host.calls.lock().unwrap(), [
        r#"{"patch":{"view":"original"},"type":"settings"}"#.to_string(),
        r#"{"type":"play"}"#.into(),
        r#"{"type":"reconnect"}"#.into(),
        "press 4096 80".into(),
        "press 1 5000".into(),
    ]);
}

#[test]
fn bad_requests_say_what_is_wrong() {
    let host = FakeHost::default();
    assert_eq!(handle(&host, &request("GET", "/nope", "")).0, 404);
    assert_eq!(handle(&host, &request("GET", "/play", "")).0, 404); // play is a POST
    assert!(handle(&host, &request("POST", "/settings", "{")).1["error"].as_str().unwrap().contains("not JSON"));
    assert_eq!(handle(&host, &request("POST", "/settings", "[1]")).1, json!({"error": "settings: send a JSON object"}));
    assert_eq!(handle(&host, &request("POST", "/press", "")).0, 400);
    assert_eq!(handle(&FakeHost { fail: true, ..Default::default() }, &request("GET", "/status", "")), (400, json!({"error": "no renderer"})));
}

#[test]
fn reads_http_requests() {
    let raw = "POST /settings?x=1 HTTP/1.1\r\nHost: localhost\r\ncontent-length: 17\r\n\r\n{\"view\":\"split\"}\n";
    assert_eq!(read_request(raw.as_bytes()), Ok(request("POST", "/settings?x=1", "{\"view\":\"split\"}\n")));
    assert_eq!(read_request("GET /status HTTP/1.1\r\n\r\n".as_bytes()), Ok(request("GET", "/status", "")));
    assert_eq!(read_request("GET /status HTTP/1.1\r\n".as_bytes()), Ok(request("GET", "/status", ""))); // no blank line
    assert!(read_request("garbage\r\n\r\n".as_bytes()).is_err());
    assert!(read_request("POST / HTTP/1.1\r\nContent-Length: x\r\n\r\n".as_bytes()).is_err());
    assert!(read_request("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nshort".as_bytes()).is_err());
}

/// Sends a raw HTTP request and returns (status, JSON body).
fn http(address: std::net::SocketAddr, raw: &str) -> (u16, Value) {
    let mut stream = TcpStream::connect(address).expect("connect");
    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    stream.write_all(raw.as_bytes()).unwrap();
    let mut reply = String::new();
    stream.read_to_string(&mut reply).unwrap();
    let status = reply.split_whitespace().nth(1).and_then(|s| s.parse().ok()).unwrap_or(0);
    let body = reply.split_once("\r\n\r\n").map(|(_, b)| b).unwrap_or("");
    (status, serde_json::from_str(body).unwrap_or(Value::Null))
}

#[test]
fn serves_http_on_localhost() {
    let address = start(0, Arc::new(FakeHost::default())).expect("listen");
    assert!(address.ip().is_loopback());
    assert_eq!(http(address, "GET /status HTTP/1.1\r\n\r\n"), (200, json!({"shownFps": 60.0})));
    assert_eq!(http(address, "GET /missing HTTP/1.1\r\n\r\n").0, 404);
    assert_eq!(http(address, "nonsense\r\n\r\n").0, 400);
    // A port that's taken is an error, not a panic.
    assert!(start(address.port(), Arc::new(FakeHost::default())).is_err());
}

#[test]
fn the_app_answers_through_the_port() {
    let core = FakeCore { stats: r#"{"active":false}"#.into(), mode: -1, ..Default::default() }.leak();
    let app = with_commands(mock_builder()).build(mock_context(noop_assets())).expect("mock app");
    app.manage(CoreHandle(core));
    assert_eq!(start_dev_control(app.handle(), None), None); // off unless the env var names a port
    let address = start_dev_control(app.handle(), Some(0)).expect("port");
    assert_eq!(start_dev_control(app.handle(), Some(address.port())), None); // taken: logged, not fatal

    let (status, body) = http(address, "GET /status HTTP/1.1\r\n\r\n");
    assert_eq!((status, &body["shownFps"]), (200, &json!(0.0)));

    assert_eq!(http(address, "POST /press?buttons=options&ms=0 HTTP/1.1\r\n\r\n").0, 200);
    let calls = core.calls();
    assert!(calls.ends_with(&["set_controller 4096".to_string(), "set_controller 0".to_string()]), "{calls:?}");

    let (tx, rx) = mpsc::channel::<Value>();
    app.listen_any("dev-control", move |event| {
        let _ = tx.send(serde_json::from_str(event.payload()).unwrap_or(Value::Null));
    });
    let body = r#"{"frameInterpolation":true}"#;
    let raw = format!("POST /settings HTTP/1.1\r\nContent-Length: {}\r\n\r\n{body}", body.len());
    assert_eq!(http(address, &raw).0, 200);
    let event = rx.recv_timeout(Duration::from_secs(5)).ok();
    assert_eq!(event, Some(json!({"type": "settings", "patch": {"frameInterpolation": true}})));

    assert_eq!(http(address, "POST /fullscreen HTTP/1.1\r\n\r\n").1, json!({"error": "no main window"}));
    WebviewWindowBuilder::new(&app, "main", WebviewUrl::default()).build().expect("webview");
    assert_eq!(http(address, "POST /fullscreen HTTP/1.1\r\n\r\n").0, 200);
}
