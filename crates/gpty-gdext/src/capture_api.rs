//! Concept-capture facet of `GptyTerminal`: the engine-global concept set and this pane's captures.
//!
//! The concept set is process-wide (the static setter takes the whole array at once);
//! captures are per-pane and the GUI drains them each frame. Concepts capture and display -
//! no method here writes to a PTY.

use crate::{ENGINE, GptyTerminal};
use godot::prelude::*;

#[godot_api(secondary)]
impl GptyTerminal {
    /// Replace all concepts in the global engine.
    ///
    /// Static because the store it writes is process-wide: an instance would
    /// only be a vehicle for the call, and the GDScript side used to allocate
    /// one per push and leak it (`ConceptManager._push_to_rust` — one ObjectDB
    /// entry per save, toggle and editor save).
    ///
    /// `concepts_json` is a JSON Array of objects, each with:
    ///   "name": String, "trigger": String (regex),
    ///   "enabled": bool, "capture_mode": String,
    ///   "stop_timeout_ms": int, "stop_on_input": bool,
    ///   "conditions": Array[String] (regexes ANDed with the trigger on the
    ///   same line; a concept with an unparseable condition is dropped),
    ///   "actions": Array[{"target":String}]
    /// Call `validate_regex()` on user-authored patterns before writing them:
    /// the engine's dialect is narrower than GDScript's PCRE2.
    /// Parsing and caps (count, lengths, timeout clamp) live in
    /// `gpty_core::concept::concepts_from_json`.
    #[func]
    fn set_global_concepts(concepts_json: GString) {
        let concepts = gpty_core::concept::concepts_from_json(&concepts_json.to_string());
        ENGINE.set_concepts(concepts);
    }
    /// Get all concepts as an Array of Dictionaries.
    ///
    /// Static for the same reason as `set_global_concepts`: it reads the
    /// process-wide store, so there is nothing for an instance to own.
    ///
    /// Every dictionary carries `conditions` (PackedStringArray, possibly
    /// empty) alongside `name`, `trigger`, `enabled`, `capture_mode`,
    /// `stop_timeout_ms`/`stop_on_input` (until_stop only) and `actions`.
    #[func]
    fn get_global_concepts() -> Array<Variant> {
        use gpty_core::types::CaptureMode;
        let concepts = ENGINE.get_concepts();
        let mut arr = Array::<Variant>::new();
        for c in &concepts {
            let mut obj = Dictionary::<Variant, Variant>::new();
            obj.set("name", &Variant::from(c.name.clone()));
            obj.set("trigger", &Variant::from(c.trigger_regex.as_str()));
            obj.set("enabled", &Variant::from(c.enabled));
            let mut conds = PackedStringArray::new();
            for re in &c.conditions {
                conds.push(&GString::from(re.as_str()));
            }
            obj.set("conditions", &Variant::from(conds));
            match c.capture_mode {
                CaptureMode::SingleLine => {
                    obj.set("capture_mode", &Variant::from("single_line"));
                }
                CaptureMode::UntilStop {
                    stop_timeout_ms,
                    stop_on_input,
                } => {
                    obj.set("capture_mode", &Variant::from("until_stop"));
                    obj.set("stop_timeout_ms", &Variant::from(stop_timeout_ms as i64));
                    obj.set("stop_on_input", &Variant::from(stop_on_input));
                }
            }
            let mut acts = Array::<Variant>::new();
            for a in &c.destinations {
                let mut ad = Dictionary::<Variant, Variant>::new();
                ad.set("target", &Variant::from(a.target_label.clone()));
                acts.push(&Variant::from(ad));
            }
            obj.set("actions", &Variant::from(acts));
            arr.push(&Variant::from(obj));
        }
        arr
    }

    /// Drain all completed capture events from this terminal's queue.
    ///
    /// Returns an Array of Dictionaries with keys:
    /// - `id` (int): capture ID for acknowledge/flush
    /// - `concept_name` (String)
    /// - `lines` (PackedStringArray): captured output lines
    /// - `target_pane_type` (String)
    #[func]
    fn drain_concept_events(&self) -> Array<Variant> {
        let mut arr = Array::<Variant>::new();
        if let Some(queue) = &self.capture_queue
            && let Ok(mut events) = queue.lock()
        {
            for ev in events.drain(..) {
                arr.push(&crate::capture_event_dict(&ev));
            }
        }
        arr
    }

    /// Drain captures whose source pane was torn down while they were still
    /// in flight (closed, swapped, or the layout reset).
    ///
    /// The events are complete — there is nothing to acknowledge or flush,
    /// because the pane, its grid, and its raw-byte store died with it. The
    /// caller routes them like any other capture and reports a missed route
    /// without replaying bytes. Returns the same Dictionaries as
    /// `drain_concept_events`.
    #[func]
    fn drain_orphaned_captures() -> Array<Variant> {
        let mut arr = Array::<Variant>::new();
        for ev in ENGINE.drain_orphaned_captures() {
            arr.push(&crate::capture_event_dict(&ev));
        }
        arr
    }

    /// Drain notify-only concept matches (`CaptureMode::SingleLine`).
    ///
    /// Returns an Array of Dictionaries with keys:
    /// - `concept_name` (String)
    ///
    /// Metadata only: the matched line is never included, so the event
    /// channel carries facts about the workspace, not what was printed.
    #[func]
    fn drain_concept_notices(&self) -> Array<Variant> {
        let mut arr = Array::<Variant>::new();
        if let Some(ref spawned) = self.spawned
            && let Ok(mut notices) = spawned.notice_queue.lock()
        {
            for notice in notices.drain(..) {
                let mut obj = Dictionary::<Variant, Variant>::new();
                obj.set("concept_name", &Variant::from(notice.concept_name));
                arr.push(&Variant::from(obj));
            }
        }
        arr
    }

    /// Acknowledge that GDScript routed a capture to a receiver.
    ///
    /// Discards the buffered raw bytes — they will NOT appear on the terminal.
    #[func]
    fn acknowledge_capture(&self, event_id: i64) {
        if let Some(ref spawned) = self.spawned {
            spawned.handle.acknowledge_capture(event_id as u64);
        }
    }

    /// Flush a capture's buffered bytes to the terminal grid.
    ///
    /// Called when no receiver pane was available — the output
    /// appears normally on the terminal.
    #[func]
    fn flush_capture(&self, event_id: i64) {
        if let Some(ref spawned) = self.spawned {
            spawned.handle.flush_capture(event_id as u64);
        }
    }

    /// Validate a pattern against the engine's regex dialect.
    ///
    /// Returns an empty String when `gpty_core::concept::validate_pattern`
    /// accepts the pattern, otherwise its error message for display.
    ///
    /// GDScript's `RegEx` is PCRE2 and accepts look-around and backreferences
    /// that the Rust `regex` crate rejects; `concepts_from_json` silently drops
    /// a concept carrying such a pattern. The concept editor must therefore
    /// validate each user-authored trigger and condition through this call —
    /// it is the only authority on what the engine will actually load.
    ///
    /// This is a static method — call it as `GptyTerminal.validate_regex("{p}")`
    /// from GDScript.
    #[func]
    fn validate_regex(pattern: GString) -> GString {
        match gpty_core::concept::validate_pattern(&pattern.to_string()) {
            Ok(()) => GString::new(),
            Err(err) => GString::from(&err),
        }
    }
}
