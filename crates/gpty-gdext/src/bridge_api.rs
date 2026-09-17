//! Bridge facet of `GptyTerminal`: the IPC/event boundary and the static app metadata.
//!
//! The control socket's request queue, the event-socket fan-out and drain, and the statics
//! a caller reaches before any pane exists (app version, installed plugin profiles).

use crate::GptyTerminal;
use godot::prelude::*;

#[godot_api(secondary)]
impl GptyTerminal {
    /// Fan a JSON event out to event-socket subscribers.
    #[func]
    fn emit_event(event_json: GString) {
        crate::omp_events::emit_event(&event_json.to_string());
    }

    /// Drain pending IPC requests into an Array of Dictionaries.
    /// Returns `[{id: int, method: String, params: String, timeout_ms: int}]`.
    /// `timeout_ms` is the request's remaining fallback deadline (0 once it
    /// has passed) — the deferred-answer dialogs close themselves when it
    /// fires, so a late answer cannot look like consent.
    #[func]
    fn drain_ipc_requests() -> Array<Dictionary<Variant, Variant>> {
        crate::ipc::ensure_server_started();
        let requests = crate::ipc::drain_requests();
        let mut arr = Array::new();
        for req in requests {
            let doc = crate::ipc::request_document(&req);
            let mut dict = Dictionary::new();
            dict.set("id", &Variant::from(doc.id as i64));
            dict.set("method", &Variant::from(doc.method));
            dict.set("params", &Variant::from(doc.params));
            dict.set("timeout_ms", &Variant::from(doc.timeout_ms as i64));
            arr.push(&dict);
        }
        arr
    }

    /// Return the application version baked in at compile time (CARGO_PKG_VERSION).
    ///
    /// This is a static method — call it as `GptyTerminal.get_app_version()` from
    /// GDScript. It never changes at runtime and is safe to call before any
    /// terminal is spawned.
    #[func]
    fn get_app_version() -> GString {
        GString::from(env!("CARGO_PKG_VERSION"))
    }

    /// Profiles declared by the installed plugins, for the GUI's profile list.
    ///
    /// Static, like `get_app_version`: the list is offered before any pane
    /// exists, and it describes the plugin store, not a terminal. The store
    /// (`state_dir()/plugins.json`) is written by `gpty plugin install` and is
    /// user-owned state: a store that is *missing* is the normal state of a
    /// machine with no plugins, so it answers `[]` without a word; anything
    /// else that goes wrong (no state directory, an unreadable or malformed
    /// store) is worth a warn, and still never an error the GUI has to handle
    /// at startup. GDScript sees the warn with its own call stack attached,
    /// which is why the routine case must stay silent.
    ///
    /// JSON array of `{plugin_id, revision, name, tiles}`, one entry per
    /// profile of every **enabled** plugin, in store order; `tiles` are the
    /// manifest's raw tile values, which the GUI sanitizes again for its own
    /// pane type.
    #[func]
    fn installed_plugin_profiles() -> GString {
        let Some(dir) = gpty_ipc::transport::state_dir() else {
            log::warn!("installed_plugin_profiles: no state directory");
            return GString::from("[]");
        };
        let path = dir.join("plugins.json");
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return GString::from("[]"),
            Err(e) => {
                log::warn!("installed_plugin_profiles: {}: {e}", path.display());
                return GString::from("[]");
            }
        };
        GString::from(&crate::profiles_json(&text).unwrap_or_else(|reason| {
            log::warn!("installed_plugin_profiles: {}: {reason}", path.display());
            "[]".to_string()
        }))
    }

    /// Drain semantic events emitted by explicitly installed agent extensions.
    #[func]
    fn drain_agent_events() -> GString {
        crate::omp_events::ensure_server_started();
        let values: Vec<serde_json::Value> = crate::omp_events::drain_events()
            .into_iter()
            .map(|event| {
                serde_json::json!({
                    "terminal_session_id": event.terminal_session_id,
                    "omp_session_id": event.omp_session_id,
                    "seq": event.seq,
                    "event": event.event,
                })
            })
            .collect();
        GString::from(&serde_json::to_string(&values).unwrap_or_else(|_| "[]".into()))
    }

    /// Respond to an IPC request identified by `id`.
    #[func]
    fn respond_ipc(id: i64, success: bool, result_json: String) {
        crate::ipc::complete_response(id as u64, success, result_json);
    }
}
