//! Unit tests (kept out of the coverage report: they measure the code under test, not themselves).

mod commands;
mod dev_control;
mod fake;
#[cfg(target_os = "macos")]
mod ffi;
mod native;
