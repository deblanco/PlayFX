use std::sync::Mutex;

use crate::native::NativeCore;

/// A scripted `NativeCore` that records every call.
#[derive(Default)]
pub struct FakeCore {
    /// Returned by discover / register / psn_account_id / session_start.
    pub reply: String,
    pub login_url: String,
    pub redirect_url: String,
    pub wakeup_ok: bool,
    pub metalfx: bool,
    pub mode: i32,
    pub stats: String,
    pub calls: Mutex<Vec<String>>,
}

impl FakeCore {
    pub fn leak(self) -> &'static FakeCore {
        Box::leak(Box::new(self))
    }

    pub fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }

    fn log(&self, call: String) {
        self.calls.lock().unwrap().push(call);
    }
}

impl NativeCore for FakeCore {
    fn discover(&self, timeout_ms: i32) -> String {
        self.log(format!("discover {timeout_ms}"));
        self.reply.clone()
    }
    fn register(&self, request: &str) -> String {
        self.log(format!("register {request}"));
        self.reply.clone()
    }
    fn wakeup(&self, credentials: &str) -> bool {
        self.log(format!("wakeup {credentials}"));
        self.wakeup_ok
    }
    fn psn_login_url(&self) -> String {
        self.login_url.clone()
    }
    fn psn_redirect_url(&self) -> String {
        self.redirect_url.clone()
    }
    fn psn_account_id(&self, redirect: &str) -> String {
        self.log(format!("psn_account_id {redirect}"));
        self.reply.clone()
    }
    fn session_start(&self, request: &str) -> String {
        self.log(format!("session_start {request}"));
        self.reply.clone()
    }
    fn session_stop(&self) {
        self.log("session_stop".into());
    }
    fn set_login_pin(&self, pin: &str) {
        self.log(format!("set_login_pin {pin}"));
    }
    fn set_controller(&self, state: crate::native::ControllerState) {
        self.log(format!("set_controller {}", state.buttons));
    }
    fn set_render_params(&self, params: &str) -> bool {
        self.log(format!("set_render_params {params}"));
        !params.contains("fsr")
    }
    fn metalfx_supported(&self) -> bool {
        self.metalfx
    }
    fn active_mode(&self) -> i32 {
        self.mode
    }
    fn session_stats(&self) -> String {
        self.stats.clone()
    }
}
