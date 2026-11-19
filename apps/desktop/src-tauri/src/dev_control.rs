//! Dev-only control port, for automation such as benchmarks and end-to-end runs: a debug build started
//! with `PLAYFX_DEV_CONTROL=<port>` answers plain HTTP on 127.0.0.1. It reads the renderer's status,
//! presses controller buttons, toggles full screen, and hands settings / play / reconnect requests to the
//! web UI, which applies them exactly as its own controls would. Never compiled into release builds.
//! The API is documented in docs/dev-control.md.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::Arc;

use serde_json::{Value, json};

/// The env var that turns the port on, and the port it names.
pub const ENV: &str = "PLAYFX_DEV_CONTROL";

/// What the port needs from the running app (the real one, or a fake in tests).
pub trait DevHost: Send + Sync {
    /// The renderer's status, as the UI's `renderer_status` command returns it.
    fn status(&self) -> Result<Value, String>;
    /// Holds `buttons` (PlayStation button bits) for `ms`, then releases them.
    fn press(&self, buttons: u32, ms: u64) -> Result<(), String>;
    /// Toggles native full screen; the new state.
    fn fullscreen(&self) -> Result<bool, String>;
    /// Hands a command to the web UI (the `dev-control` event).
    fn emit(&self, command: Value) -> Result<(), String>;
}

/// One HTTP request, as much of it as the port uses.
#[derive(Debug, PartialEq, Eq)]
pub struct Request {
    pub method: String,
    pub path: String,
    pub query: String,
    pub body: String,
    /// Sent with `X-PlayFX-Dev: 1` and a Host naming this machine. A web page can reach 127.0.0.1 too (a
    /// form post, DNS rebinding), but can't add a custom header without a CORS preflight, which this port
    /// never answers; a rebound name shows in the Host.
    pub trusted: bool,
}

/// The port from the env var's value: a number from 1024 up, or nothing.
pub fn port(value: Option<&str>) -> Option<u16> {
    value.and_then(|v| v.trim().parse::<u16>().ok()).filter(|p| *p >= 1024)
}

/// PlayStation button bits for comma-separated names, as in psrp.h.
pub fn button_bits(names: &str) -> Result<u32, String> {
    const BUTTONS: [(&str, u32); 16] = [
        ("cross", 1 << 0), ("circle", 1 << 1), ("square", 1 << 2), ("triangle", 1 << 3),
        ("left", 1 << 4), ("right", 1 << 5), ("up", 1 << 6), ("down", 1 << 7),
        ("l1", 1 << 8), ("r1", 1 << 9), ("l3", 1 << 10), ("r3", 1 << 11),
        ("options", 1 << 12), ("share", 1 << 13), ("touchpad", 1 << 14), ("ps", 1 << 15),
    ];
    let mut bits = 0;
    for name in names.split(',').map(|n| n.trim().to_ascii_lowercase()).filter(|n| !n.is_empty()) {
        let (_, bit) = BUTTONS
            .iter()
            .find(|(known, _)| *known == name)
            .ok_or_else(|| format!("unknown button {name}; buttons: {}", BUTTONS.map(|(n, _)| n).join(", ")))?;
        bits |= bit;
    }
    if bits == 0 { Err("press: name at least one button, e.g. ?buttons=options".into()) } else { Ok(bits) }
}

/// A query parameter's value (`a=1&b=2`; no percent-decoding, values are plain words and numbers).
fn param<'a>(query: &'a str, key: &str) -> Option<&'a str> {
    query.split('&').filter_map(|pair| pair.split_once('=')).find(|(k, _)| *k == key).map(|(_, v)| v)
}

/// Answers one request: (HTTP status, JSON body).
pub fn handle(host: &dyn DevHost, request: &Request) -> (u16, Value) {
    let ok = || json!({"ok": true});
    let result = match (request.method.as_str(), request.path.as_str()) {
        ("GET", "/status") => host.status(),
        ("POST", "/settings") => serde_json::from_str::<Value>(&request.body)
            .map_err(|e| format!("settings: not JSON ({e})"))
            .and_then(|patch| if patch.is_object() { Ok(patch) } else { Err("settings: send a JSON object".into()) })
            .and_then(|patch| host.emit(json!({"type": "settings", "patch": patch})).map(|()| ok())),
        ("POST", "/play") => host.emit(json!({"type": "play"})).map(|()| ok()),
        ("POST", "/reconnect") => host.emit(json!({"type": "reconnect"})).map(|()| ok()),
        ("POST", "/fullscreen") => host.fullscreen().map(|on| json!({"fullscreen": on})),
        ("POST", "/press") => button_bits(param(&request.query, "buttons").unwrap_or("")).and_then(|bits| {
            let ms = param(&request.query, "ms").and_then(|v| v.parse().ok()).unwrap_or(150).min(5_000);
            host.press(bits, ms).map(|()| ok())
        }),
        (method, path) => return (404, json!({"error": format!("no route {method} {path}; see docs/dev-control.md")})),
    };
    match result {
        Ok(body) => (200, body),
        Err(error) => (400, json!({"error": error})),
    }
}

/// Reads one HTTP/1.x request: the request line, headers up to the blank line, and a `Content-Length` body.
pub fn read_request(stream: impl Read) -> Result<Request, String> {
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line).map_err(|e| e.to_string())?;
    let mut parts = line.split_whitespace();
    let (method, target) = match (parts.next(), parts.next()) {
        (Some(m), Some(t)) => (m.to_string(), t.to_string()),
        _ => return Err("malformed request line".into()),
    };
    let mut length = 0usize;
    let (mut dev_header, mut local_host) = (false, false);
    loop {
        let mut header = String::new();
        if reader.read_line(&mut header).map_err(|e| e.to_string())? == 0 || header.trim().is_empty() {
            break;
        }
        let Some((name, value)) = header.split_once(':') else { continue };
        let (name, value) = (name.trim(), value.trim());
        if name.eq_ignore_ascii_case("content-length") {
            length = value.parse().map_err(|_| "bad Content-Length".to_string())?;
        } else if name.eq_ignore_ascii_case("x-playfx-dev") {
            dev_header = value == "1";
        } else if name.eq_ignore_ascii_case("host") {
            let host_name = value.rsplit_once(':').map_or(value, |(name, _)| name);
            local_host = matches!(host_name, "127.0.0.1" | "localhost");
        }
    }
    let mut body = vec![0; length.min(1 << 20)];
    reader.read_exact(&mut body).map_err(|e| e.to_string())?;
    let (path, query) = target.split_once('?').unwrap_or((&target, ""));
    Ok(Request {
        method,
        path: path.to_string(),
        query: query.to_string(),
        body: String::from_utf8_lossy(&body).into(),
        trusted: dev_header && local_host,
    })
}

fn respond(mut stream: TcpStream, host: &dyn DevHost) {
    // A client that connects and sends nothing doesn't hold its thread forever.
    let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(5)));
    let (status, body) = match stream.try_clone().map_err(|e| e.to_string()).and_then(read_request) {
        Ok(request) if !request.trusted => {
            (403, json!({"error": "send X-PlayFX-Dev: 1 to 127.0.0.1 or localhost; see docs/dev-control.md"}))
        }
        Ok(request) => handle(host, &request),
        Err(error) => (400, json!({"error": error})),
    };
    let text = body.to_string();
    let reason = match status { 200 => "OK", 403 => "Forbidden", 404 => "Not Found", _ => "Bad Request" };
    let _ = write!(
        stream,
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{text}",
        text.len()
    );
}

/// Listens on 127.0.0.1:`port` (0 = any free port) and answers each connection on its own thread.
pub fn start(port: u16, host: Arc<dyn DevHost>) -> Result<SocketAddr, String> {
    let listener = TcpListener::bind(("127.0.0.1", port)).map_err(|e| format!("dev control port {port}: {e}"))?;
    let address = listener.local_addr().map_err(|e| e.to_string())?;
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let host = Arc::clone(&host);
            std::thread::spawn(move || respond(stream, host.as_ref()));
        }
    });
    Ok(address)
}
