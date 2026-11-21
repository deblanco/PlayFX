//! In-app updates through GitHub Releases, with Tauri's updater plugin: the app reads `latest.json` from the
//! latest release, and an update is a signed `PlayFX_<version>_aarch64.app.tar.gz` of the notarized app
//! (scripts/release.sh makes both). The plugin checks the minisign signature against the public key in
//! tauri.conf.json before anything is installed. The plugin sits behind [`Updates`], so the commands are tested
//! with a fake; [`PluginUpdates`] is the thin adapter over it.

use std::sync::atomic::{AtomicBool, Ordering};

use serde_json::{Value, json};
use tauri::{AppHandle, Context, Emitter, Manager, Runtime, Url};

use crate::{blocking, core, error_text, on_main};

/// Points the update check somewhere else (a local server, for testing a release): an https URL, or http on
/// this Mac (127.0.0.1, localhost). The update's signature is checked all the same.
pub const ENDPOINT_ENV: &str = "PLAYFX_UPDATE_ENDPOINT";

/// Where the releases are: each one's page is `<RELEASES_URL>/tag/v<version>`.
pub const RELEASES_URL: &str = "https://github.com/deblanco/PlayFX/releases";

/// What the update commands answer while a stream is running: an update never installs or restarts then.
pub const FINISH_PLAYING: &str = "Finish playing to update";

/// The background check (on launch and every 6 hours) runs in release builds only; checking by hand works in
/// every build.
pub const AUTOMATIC_CHECKS: bool = !cfg!(debug_assertions);

/// The progress events' name (`{"percent": 0–100 or null}`).
pub const PROGRESS_EVENT: &str = "update-progress";

/// A newer release the check found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Available {
    pub version: String,
    pub current_version: String,
}

/// The updater, as the commands use it (the plugin in the app, a fake in tests).
pub trait Updates: Send + Sync {
    /// Asks the endpoint (`endpoint`, or tauri.conf.json's) for a newer release, and keeps what it found for
    /// `download`.
    fn check(&self, endpoint: Option<Url>) -> Result<Option<Available>, String>;
    /// Downloads the release the last check found and verifies its signature; `progress` gets the bytes so far
    /// and the size, when the server says it.
    fn download(&self, progress: &mut dyn FnMut(u64, Option<u64>)) -> Result<Vec<u8>, String>;
    /// Verifies the bytes again and puts the new app in place of the running one.
    fn install(&self, bytes: &[u8]) -> Result<(), String>;
    /// Quits (the app's exit steps run, the pads are left quiet) and opens the installed app.
    fn restart(&self);
}

/// The updater the commands use (managed in `attach_updates`, faked in tests), and where it checks: the
/// `PLAYFX_UPDATE_ENDPOINT` override read at launch (`None`: tauri.conf.json's endpoint), or why it's unusable.
pub struct UpdatesHandle {
    pub updates: &'static dyn Updates,
    pub endpoint: Result<Option<Url>, String>,
    /// The UI is playing (`update_set_playing`): from Play until it's back home, including the stretches
    /// where StreamCore holds no session (a PSN token refresh before the start, a retry, a reconnect).
    pub playing: AtomicBool,
}

impl UpdatesHandle {
    pub fn new(updates: &'static dyn Updates, endpoint: Result<Option<Url>, String>) -> Self {
        Self { updates, endpoint, playing: AtomicBool::new(false) }
    }
}

fn updates<R: Runtime>(app: &AppHandle<R>) -> &'static dyn Updates {
    app.state::<UpdatesHandle>().updates
}

/// The endpoint `PLAYFX_UPDATE_ENDPOINT` names, if any: https anywhere, http only on this Mac.
pub fn endpoint_override(value: Option<&str>) -> Result<Option<Url>, String> {
    let Some(text) = value.map(str::trim).filter(|text| !text.is_empty()) else {
        return Ok(None);
    };
    let url: Url = text.parse().map_err(|e| format!("{ENDPOINT_ENV} isn't a URL: {e}"))?;
    match url.scheme() {
        "https" => Ok(Some(url)),
        "http" if is_loopback(&url) => Ok(Some(url)),
        _ => Err(format!("{ENDPOINT_ENV} must be an https URL, or http on this Mac (127.0.0.1)")),
    }
}

fn is_loopback(url: &Url) -> bool {
    match url.host_str() {
        Some("localhost") => true,
        Some(host) => host
            .trim_start_matches('[')
            .trim_end_matches(']')
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_loopback()),
        None => false,
    }
}

/// Lets the plugin talk http to an override on this Mac (release builds refuse http otherwise). Called before
/// the app is built; without an http override the configuration stays as tauri.conf.json has it.
pub fn configure_updater<R: Runtime>(context: &mut Context<R>, endpoint: Option<&str>) {
    if let Ok(Some(url)) = endpoint_override(endpoint)
        && url.scheme() == "http"
        && let Some(Value::Object(updater)) = context.config_mut().plugins.0.get_mut("updater")
    {
        updater.insert("dangerousInsecureTransportProtocol".into(), Value::Bool(true));
    }
}

/// The updater plugin itself (its configuration is tauri.conf.json's `plugins.updater`). Its own commands
/// aren't granted to any window: the UI goes through the commands below.
pub fn updater_plugin<R: Runtime>() -> tauri::plugin::TauriPlugin<R, tauri_plugin_updater::Config> {
    tauri_plugin_updater::Builder::new().build()
}

/// Puts the plugin behind the update commands, checking at `endpoint` (`PLAYFX_UPDATE_ENDPOINT`) when it's
/// set. Called from `main.rs` during setup.
pub fn attach_updates<R: Runtime>(app: &AppHandle<R>, endpoint: Option<&str>) {
    let real: &'static PluginUpdates<R> = Box::leak(Box::new(PluginUpdates::new(app.clone())));
    let endpoint = endpoint_override(endpoint);
    match &endpoint {
        Ok(Some(url)) => log::warn!("Updates are checked at {url} ({ENDPOINT_ENV})"),
        Ok(None) => {}
        Err(error) => log::error!("{error}"),
    }
    app.manage(UpdatesHandle::new(real, endpoint));
}

/// Whether a stream is running or being started: the UI says it's playing, or StreamCore holds a session. A
/// reply that can't be read counts as streaming, so an update never lands on a stream by mistake.
fn streaming<R: Runtime>(app: &AppHandle<R>) -> Result<bool, String> {
    if app.state::<UpdatesHandle>().playing.load(Ordering::SeqCst) {
        return Ok(true);
    }
    let core = core(app);
    let stats = on_main(app, move || core.session_stats())?;
    Ok(serde_json::from_str::<Value>(&stats).map_or(true, |stats| stats.get("active") != Some(&Value::Bool(false))))
}

/// The UI tells whether it's playing (a stream started, starting or reconnecting), so nothing installs or
/// restarts while StreamCore is between sessions.
#[tauri::command]
pub fn update_set_playing<R: Runtime>(app: AppHandle<R>, playing: bool) {
    app.state::<UpdatesHandle>().playing.store(playing, Ordering::SeqCst);
}

/// Checks for a newer release: {"status": "upToDate" | "available" | "off", "currentVersion", "version"?}.
/// `automatic` is the background check, "off" in development builds (no request is made).
#[tauri::command]
pub async fn update_check<R: Runtime>(app: AppHandle<R>, automatic: bool) -> Result<Value, String> {
    let current = app.package_info().version.to_string();
    if automatic && !AUTOMATIC_CHECKS {
        return Ok(json!({"status": "off", "currentVersion": current}));
    }
    let endpoint = app.state::<UpdatesHandle>().endpoint.clone()?;
    let found = blocking(move || updates(&app).check(endpoint)).await?;
    match found {
        Ok(None) => {
            log::info!("Update check: PlayFX {current} is up to date");
            Ok(json!({"status": "upToDate", "currentVersion": current}))
        }
        Ok(Some(Available { version, current_version })) => {
            log::info!("Update check: PlayFX {version} is available (this is {current_version})");
            Ok(json!({"status": "available", "version": version, "currentVersion": current_version}))
        }
        Err(error) => {
            log::warn!("Update check failed: {error}");
            Err(error)
        }
    }
}

/// The whole percentage downloaded, when the size is known.
pub fn percent(downloaded: u64, total: Option<u64>) -> Option<u8> {
    total.filter(|&total| total > 0).map(|total| (downloaded.min(total) * 100 / total) as u8)
}

/// Downloads the release the last check found, verifies it and installs it in place of this app, emitting
/// "update-progress" as the percentage changes. Refused while a stream runs, before the download and again
/// before installing (Play may have been pressed meanwhile). `update_restart` then opens the new version.
#[tauri::command]
pub async fn update_install<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    let refuse_while_streaming = |app: AppHandle<R>| async move {
        if blocking(move || streaming(&app)).await?? {
            log::info!("Update not installed: a stream is running");
            return Err(FINISH_PLAYING.to_string());
        }
        Ok(())
    };
    refuse_while_streaming(app.clone()).await?;
    let updater = updates(&app);
    log::info!("Downloading the update");
    let events = app.clone();
    let bytes = blocking(move || {
        let mut shown: Option<Option<u8>> = None;
        updater.download(&mut |downloaded, total| {
            let now = percent(downloaded, total);
            if shown != Some(now) {
                shown = Some(now);
                let _ = events.emit(PROGRESS_EVENT, json!({"percent": now}));
            }
        })
    })
    .await?
    .inspect_err(|error| log::warn!("Update download failed: {error}"))?;
    log::info!("Downloaded the update ({} bytes), signature verified", bytes.len());
    refuse_while_streaming(app.clone()).await?;
    log::info!("Installing the update");
    blocking(move || updater.install(&bytes)).await?.inspect_err(|error| log::warn!("Update install failed: {error}"))?;
    log::info!("Update installed; it runs after a restart");
    Ok(())
}

/// Restarts into the installed update; refused while a stream runs.
#[tauri::command(async)]
pub fn update_restart<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    if streaming(&app)? {
        return Err(FINISH_PLAYING.to_string());
    }
    log::info!("Restarting into the update");
    updates(&app).restart();
    Ok(())
}

/// A release version as the UI may pass it ("0.2.5", "1.0.0-beta.1"): nothing else goes into the URL.
fn is_version(version: &str) -> bool {
    version.starts_with(|c: char| c.is_ascii_digit())
        && version.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '+'))
}

/// Opens a release's page on GitHub (what's new, and the DMG when updating in the app fails).
#[tauri::command(async)]
pub fn open_release_page(version: String) -> Result<(), String> {
    if !is_version(&version) {
        return Err(format!("{version:?} isn't a release version"));
    }
    crate::open(&format!("{RELEASES_URL}/tag/v{version}"))
}

/// The plugin, as [`Updates`]. Thin: what it does is the plugin's own (tested there); what's ours is
/// tested in src/tests/updates.rs against a local server.
pub struct PluginUpdates<R: Runtime> {
    app: AppHandle<R>,
    /// What the last check found.
    found: std::sync::Mutex<Option<tauri_plugin_updater::Update>>,
    /// What the last download was of, for `install`: a check meanwhile (by hand, or the background one)
    /// replaces `found` but not this.
    downloading: std::sync::Mutex<Option<tauri_plugin_updater::Update>>,
}

impl<R: Runtime> PluginUpdates<R> {
    pub fn new(app: AppHandle<R>) -> Self {
        Self { app, found: std::sync::Mutex::new(None), downloading: std::sync::Mutex::new(None) }
    }

    fn found(&self) -> Result<tauri_plugin_updater::Update, String> {
        self.found.lock().map_err(error_text)?.clone().ok_or_else(|| "No update found: check for updates first".into())
    }

    /// The update the last download was of, which `install` verifies the bytes against.
    pub(crate) fn downloaded(&self) -> Result<tauri_plugin_updater::Update, String> {
        self.downloading.lock().map_err(error_text)?.clone().ok_or_else(|| "No update downloaded: update again".into())
    }
}

impl<R: Runtime> Updates for PluginUpdates<R> {
    fn check(&self, endpoint: Option<Url>) -> Result<Option<Available>, String> {
        use tauri_plugin_updater::UpdaterExt;
        let mut builder = self.app.updater_builder();
        if let Some(url) = endpoint {
            builder = builder.endpoints(vec![url]).map_err(error_text)?;
        }
        let updater = builder.build().map_err(error_text)?;
        let update = tauri::async_runtime::block_on(updater.check()).map_err(error_text)?;
        let available =
            update.as_ref().map(|u| Available { version: u.version.clone(), current_version: u.current_version.clone() });
        *self.found.lock().map_err(error_text)? = update;
        Ok(available)
    }

    fn download(&self, progress: &mut dyn FnMut(u64, Option<u64>)) -> Result<Vec<u8>, String> {
        let update = self.found()?;
        *self.downloading.lock().map_err(error_text)? = Some(update.clone());
        let mut downloaded = 0u64;
        let chunk = |len: usize, total: Option<u64>| {
            downloaded += len as u64;
            progress(downloaded, total);
        };
        tauri::async_runtime::block_on(update.download(chunk, || {})).map_err(error_text)
    }

    fn install(&self, bytes: &[u8]) -> Result<(), String> {
        self.downloaded()?.install(bytes).map_err(error_text)
    }

    fn restart(&self) {
        self.app.request_restart();
    }
}
