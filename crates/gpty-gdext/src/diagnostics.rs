//! `log` → Godot bridge.
//!
//! Nothing installed a logger in the GDExtension, so every `log::warn!` /
//! `log::error!` from the gpty crates was dropped: a failed history append, a
//! PTY read error, a poisoned lock, a refused capture — invisible in the GUI,
//! and only visible in the CLI, which installs `env_logger` itself. A probe
//! found this the hard way: the same message printed nothing as `log::warn!`
//! and appeared as `godot_warn!`.
//!
//! Records are forwarded to Godot's own console rather than buffered for
//! GDScript: `godot_warn!` from a background thread is already the pattern in
//! this crate (the IPC handlers run on tokio and warn directly), and Godot's
//! print path takes a lock, so it is safe outside the main thread. Nothing
//! here touches the scene tree.

use std::sync::Once;

/// Forward only what a GUI user can act on.
///
/// Two filters, both deliberate:
/// - **Level**: `warn` and `error`. The gpty crates log progress at
///   `info`/`debug`, which would drown the console.
/// - **Target**: the gpty crates only. The dependency stack
///   (`alacritty_terminal`, `rusqlite`, `portable-pty`) logs its internals at
///   levels that would bury ours, and nothing a user sees can act on them.
fn forward(target: &str, level: log::Level) -> bool {
    level <= log::Level::Warn && target.starts_with("gpty")
}

struct GodotLogger;

impl log::Log for GodotLogger {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        forward(metadata.target(), metadata.level())
    }

    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let message = format!("[{}] {}", record.target(), record.args());
        if record.level() == log::Level::Error {
            godot::global::godot_error!("{}", message);
        } else {
            godot::global::godot_warn!("{}", message);
        }
    }

    fn flush(&self) {}
}

/// Install the bridge (once; `set_logger` refuses a second logger).
pub fn install() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        if log::set_logger(&GodotLogger).is_ok() {
            log::set_max_level(log::LevelFilter::Warn);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_gpty_crates_are_forwarded() {
        assert!(forward("gpty_core::history", log::Level::Warn));
        assert!(forward("gpty_gdext", log::Level::Error));
        assert!(forward("gpty", log::Level::Warn));
        // Dependencies stay quiet.
        assert!(!forward("alacritty_terminal::term", log::Level::Error));
        assert!(!forward("rusqlite", log::Level::Warn));
    }

    #[test]
    fn only_warn_and_above_are_forwarded() {
        assert!(forward("gpty_core", log::Level::Error));
        assert!(forward("gpty_core", log::Level::Warn));
        assert!(!forward("gpty_core", log::Level::Info));
        assert!(!forward("gpty_core", log::Level::Debug));
        assert!(!forward("gpty_core", log::Level::Trace));
    }
}
