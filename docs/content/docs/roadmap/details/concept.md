---
title: "Roadmap details - CONCEPT"
weight: 900
build:
  list: never
---

Every CONCEPT row, by ID and in allocation order. The queue and its priority live on the release chain pages; this page is the evidence behind each row.

## CONCEPT-1

**Concept engine** - regex-based trigger/action matching with label routing. Every line of PTY
output is tested against registered concept patterns. Matching lines broadcast events on a pub-sub
channel; panes with matching labels execute the associated action. (Command execution removed in
v0.5.3 - concepts are capture-and-route only.)

Commits: d17bac7

## CONCEPT-2

**SingleLine capture mode** - each matching line triggers an event on the pub-sub channel. Receiving
panes inject the action's command template into their PTY stdin, enabling cross-pane automation.
(The mode and its injection path were removed in v0.5.3; it never delivered an action before then -
labels were always empty and every pane shared id 1.)

Commits: d17bac7

## CONCEPT-3

**Concept engine reliability** - startup registration race fixed (`ClassDB.instantiate` on first
frame), `UntilStop` capture triggers from PTY output, capture-only concepts with empty `cmd`
supported (the `cmd` field itself was removed in v0.5.3)

Commits: d17bac7

## CONCEPT-4

**Concept management via CLI and MCP** - `gpty concept list` / `gpty concept toggle` plus matching
`concept-list`/`concept-toggle` MCP tools

Commits: d17bac7

## CONCEPT-5

**A notify-only match must not shadow a capture** - `concept::match_line` returned the first match
and `apply_match` starts nothing for `SingleLine`, so a broad notify-only concept placed ahead of a
capture concept silently suppresses that capture. Precedence is now explicit: capture outranks
notify, first match wins within a class.

Commits: d17bac7

## CONCEPT-6

**Finalize an in-flight capture when a pane is dropped** - `SpawnedTerminal::drop` called
`task.abort()`, so the documented finalize-on-close path never ran: closing, swapping, or resetting
a pane mid-capture silently lost the capture instead of routing it (and a capture the task had
already finalized was stranded, because nothing polls a dead pane's queue). The capture state
machine is now shared (`Arc<Mutex<..>>` behind the same `CaptureSession` API) so `Drop` can finalize
what the task still held, and both it and any finalized-but-undrained event go to an engine-level
orphan queue that GDScript drains each frame and routes through
`ConceptRouter.route_orphaned_capture` (delivery only - the source terminal, its grid, and its
raw-byte store are gone). The dead `spawn_pty_terminal` path is removed with it.

Commits: d17bac7

## CONCEPT-7

**Post-resize suppression while capturing** - the post-SIGWINCH window was consulted only in the
non-capturing branch, so redraw bytes were buffered into the capture, routed as output, and consumed
the 4 MiB budget. An active capture now drops bytes printed inside the window (feeding the frozen
grid instead would paint the repaint onto content it never had); output after the window is captured
normally. `post_resize_window_is_not_buffered_into_a_capture` pins both sides of the boundary.

Commits: d17bac7

## CONCEPT-8

**Visual Concept Graph** - a full-window GraphEdit overlay (Settings → Concepts → "Open Visual
Editor") authors rules as chains: trigger → condition* → action (capture & route, or notify only);
ports hold one wire, so a rule cannot fork or merge. New vocabulary: `conditions: [regex, …]` -
ANDed with the trigger on the same line, capped at 8 × 1024 bytes, and a malformed condition rejects
the whole concept (dropping one would widen matching); `GptyTerminal.validate_regex()` exposes the
engine dialect so the editor cannot author a regex GDScript's PCRE2 accepts but the Rust engine
silently discards. `ConceptGraphModel` (pure, unit-tested) builds the canvas from merged concepts,
compiles it back, writes a rule equal to its shipped default as *no* user entry (defaults keep
tracking updates), tombstones a deleted shipped rule exactly like the manual dialog, and keeps
content-invalid rules as drafts with an error instead of compiling them. The `graph` sibling key in
`user://concepts.json` holds the canvas's own state only (sanitized positions + draft nodes, plus
the rule order the rule-priority item below added), so `concepts` stays the single content store and
a manual-dialog edit cannot drift; the compiled key set is closed (`entry_for_path`), so a node
cannot smuggle a legacy `cmd` back in. Verified: 9 new engine condition tests, 23 model unit tests
(canvas/validation/compile/tombstones/drafts/layout), 394/394 GUT, full `ci-check`; live smoke
against the real GUI + GDExtension (open → splice a condition through the connection handlers → save
→ only the edited rule written → engine readback holds the condition; 4/4 edges rendered as
connections, zero auto-layout overlaps, screenshot inspected). Two defects found and fixed by that
live pass: rebuilding the canvas removed GraphEdit's internal children
(`connections_layer is missing`), and auto-layout spacing let the action overlap a condition.

Commits: d17bac7

## CONCEPT-9

**Concept matching under flood** - measured first, and the answer was *not* a cap. The cost is lines
× concepts × regex, and the per-concept loop paid each regex's own prologue on every line (~20 ns
per concept), so a 128-concept library spent 2.7 µs on a line that matched nothing. The new probe
(`cargo run --release -p gpty-core --example concept_probe`, kept, with its results recorded in the
header) flooded a real pane: ~1 KiB lines ran at 79.9 MB/s with no concepts, 79.7 with the shipped
set, 53.0 with 128 typical triggers and **5.8** at the parser's ceiling (128 concepts × 1024-byte
trigger × 8 × 1024-byte conditions); 30-byte lines ran at 47.3 MB/s with no concepts and 8.6 with
128 typical triggers - a flooded pane lost up to 90 % of its throughput to matching. Fix:
`ConceptMatcher` puts **one combined `RegexSet` pass** in front of the per-concept loop, so the
common case (nothing matches) never pays the per-concept multiplier and only a gate hit runs the
ordered loop that decides capture-vs-notify - conditions and precedence unchanged, and
`matcher_agrees_with_match_line_on_every_pair` pins the equivalence across condition-fails,
disabled, notify and capture cases (a gate built from triggers alone is exactly where a verdict
could have changed). After: 81.1 MB/s with the default set, 73.9 with 128 typical triggers, **73.3**
at the ceiling (12.6×), and 44.9 on 30-byte lines with 128 typical triggers (5.2×) - the worst case
is now within ~10 % of no concepts at all. No match-rate cap: dropping matches under load would
silently break the feature's contract, the parse caps already bound the per-line work, and matching
runs inside the pane's own task (one core, never the UI thread). Per line the gate is 44× cheaper at
30 B/128 concepts and 128× at the ceiling's worst case; a single-concept set pays ~2 ns more per
short line for the combined pass (17 → 19 ns) and compiling the gate costs 0.2/3.6/27 ms for the
shipped/typical-128/ceiling sets at `set_concepts`. Two adjacent fixes in the same path: the engine
takes the concept read lock once per output batch instead of once per line, and a poisoned `RwLock`
now follows the `Mutex` policy (skip the work, report the first occurrence) via
`lock::read_or_warn`/`write_or_warn` instead of panicking the pane's task.

Commits: d17bac7

## CONCEPT-10

**Rule priority in the visual editor** - the canvas order *is* the precedence order now, and the
canvas says so. `ConceptGraphModel.rule_order` derives it from the rules' trigger positions
(top-to-bottom, then left-to-right, then by name; a rule with no stored position keeps its compiled
place and sorts after the arranged ones) and `layout()` writes it as the graph block's `order` -
rule names, no content, so `concepts` stays the single content store.
`ConceptManager._merge_concepts` puts the rules `order` names first, in that order, and everything
the canvas does not name after them: a newly shipped default can never quietly outrank an
arrangement the user made (it shows up unranked on the next canvas), and a store without an `order`
key keeps exactly the shipped merge order (defaults first, then user entries in file order), so
nothing changes for anyone who never opened the editor. The sanitizer (`_sanitize_order`: strings
only, non-empty, ≤256 chars, deduplicated, capped at 256) and the omit-empty guard both know the
key, so a manual dialog edit (`save_concepts` → read-modify-write) cannot drop it. Each trigger's
title shows its rank (`1. Trigger - name`), refreshed on rebuild, on revalidate and *during* a drag
(`position_offset_changed` → `_refresh_ranks`/`_rewrite_titles`, only when the order actually
changed), and the editor's "Fit" button re-rows with `tidy_positions` instead of Godot's
`arrange_nodes()` - which laid nodes out by connection shape and would have silently reshuffled
precedence; the hint line names the gesture. The one derivation accepts both position shapes it sees
(`Vector2` on the canvas, `[x, y]` from the file) - the first CI run of the new test caught exactly
that mismatch: every rule read as unarranged and the saved order silently reverted to the file
order. Verified: `godot/tests/integration/test_concept_graph_editor.gd` (new, 4 cases driven through
the editor's real API - `open`, `position_offset`, `_save`, `_arrange`) reads ranks off the titles
rather than hard-coding them, because the shipped defaults are loaded too;
`test_concept_graph_model.gd` covers the derivation, the unarranged-rule fallback, the row
tie-break, the rename (order follows the new name) and `tidy_positions`; `test_concept_manager.gd`
covers the sanitizer, both caps, the merge order, the untouched-store case and the order surviving a
manual edit. (The leak the new test surfaced - `ClassDB.instantiate("GptyTerminal")` in
`_push_to_rust` never freed - is queued in v0.5.5.)

Commits: d17bac7

## CONCEPT-11

**Windows concept matching was dead until the ConPTY parser fix** - ConPTY renders line breaks as
cursor moves (no LF), so the discard-only line parser never committed real command output on
Windows; only CRLF-terminated input echoes matched. The parser fix (row-advancing CSI commits)
repaired it, but nothing in windows-smoke proves the fixed path: the smoke drives pane-wait
(recent_lines) but no concept fires from Windows *output*. Add a smoke step that registers an
UntilStop concept triggered by an output marker (not by the injected line's echo - build the marker
at runtime like the wait markers) and asserts the routed capture event, so a parser regression on
Windows fails the smoke instead of shipping. **Closed:** `scripts/smoke_pane_api.py` seeds one
concept into the user store before launch (`seed_concepts` - the only registration route that
exists, since `concept toggle` flips a shipped rule rather than adding one; the store is backed up
and restored in teardown, which matters on Windows where `user://` is the real per-user directory
that APPDATA does not redirect) and the trigger `SMOKE_CONCEPT_8K3[0-9]` demands the digit the shell
appends at runtime, so the injected line's echo cannot match it. The step asserts the seeded concept
is loaded and enabled, opens a `code_viewer` receiver so the capture routes for real, injects the
runtime-built printer, and polls the event subscription for the routed
`{type: concept, name, target: code_viewer}` event - which is only emitted after a committed
*output* line reached the matcher, exactly the commit a ConPTY regression removes. Evidence: the
step passes live here, twice, inside `./scripts/ci-check` (Linux), exercising
concept→capture→route→event end to end; the platform it is aimed at runs the same file in the
`windows-smoke` CI job, whose next run is the regression signal (not observable locally - the ConPTY
commit path it guards is Windows-only).

Commits: d17bac7

## CONCEPT-12

**Concept push leaks a `GptyTerminal` per push** - `ConceptManager._push_to_rust` does
`ClassDB.instantiate("GptyTerminal")` and calls `set_global_concepts` on it without ever freeing the
instance: the FFI method is `&self` only because it writes the engine's global store, so the object
is a vehicle for the call and nothing keeps or releases it. Every concept save, toggle and editor
save adds an ObjectDB entry that is never released - GUT names them as orphans (4 instances for the
new editor test's 4 saves; the full run reports them among its 276), and a session that edits
concepts repeatedly accumulates them. Fix: `free()` the instance after the call (or make the call
static so there is nothing to own) and pin it with an assertion on the orphan list - the instance
count per push is the observable. Surfaced while writing the rule-priority tests. **Closed:**
`set_global_concepts`/`get_global_concepts` are static now (they read/write the process-wide engine
store, so the instance was pure ceremony), `ConceptManager._push_to_rust` calls the accessor
directly behind a `ClassDB.class_exists` guard, and the duplicate
`workspace.gd._push_concepts_to_engine` - which scanned tiles only to borrow a terminal's instance
as the vehicle, and silently skipped the push when no terminal was open - is deleted, with both the
`concepts_changed` subscription and the deferred fallback pointing at the one entry point. The
subscription also had to move: connected from `workspace.gd` the same bound callable was
re-connected by every `Workspace` instance and Godot rejects that (55 cascading GUT failures caught
it mid-implementation). Pinned by `test_a_push_owns_no_ffi_instance` (`assert_no_new_orphans` after
three pushes - GUT counts orphan *nodes*, which is what the leaked object was); the run's orphan
listing no longer names `test_concept_manager.gd` at all (it listed two `GptyTerminal`s before) and
the suite went 486/486. `scripts/check-ffi-surface` grew the coverage the move would otherwise have
cost: static calls on a GDExtension class name were invisible to it, so
`GptyTerminal.get_app_version()` and 29 other static calls went unchecked - the class name is now a
handle and `new` is an allowlisted member, taking the checked surface from 61 calls to 91 with no
mismatches. `crates/gpty-gdext/README.md` marks the three concept-engine accessors static
(`validate_regex` was one too, undocumented as such).

Commits: d17bac7

## CONCEPT-13

**Reactive Environments** - closed 2026-11-21 (build 0.8.6):
`Settings → Appearance → Effects → Reactive effects` is the mapping table - one row per concept,
each with Off / Tint (red) / Pulse (accent) / Particles (green), eight rules maximum, no rules by
default. `UiEffects.REACTIVE` is the closed cue vocabulary and owns each cue's tone
(`DANGER`/`ACCENT`/`SUCCESS`, read from the active palette at draw time), and `cfg_reactive_effects`
is sanitized on load (concept-name cap, unknown effect ids dropped). The trigger is the existing
concept drain: `_poll_concept_events_for` calls `_flash_concept` for a routed capture and for a
notify-only notice, which resolves the concept name and asks the source pane to cue - display only,
nothing acknowledged, flushed or published back into the engine. `PaneEffects.flash` enforces the
per-pane `FLASH_MIN_INTERVAL_MS` of 334 ms (at most three starts in any second; a trigger inside the
window is dropped, not queued) and skips a hidden pane, so an off-screen workspace pays no GPU work;
no cue is full-screen (the pane is the flash surface). Tint is a 16 %-peak wash over its pane (80 ms
in, 240 ms hold, 400 ms out), pulse a 2 px border at 0.9 fading over 500 ms, and particles a
48-particle `CPUParticles2D` burst whose pool is allocated once and re-emitted with `restart()` (no
per-frame allocation; normal blend - no additive pass ships, so nothing here is the "light adds"
case). Tests: `test_ui_effects.gd`
(`test_sanitize_reactive_keeps_known_effects_and_refuses_the_rest`,
`test_sanitize_reactive_caps_the_table`, `test_reactive_for_reads_the_stored_mapping`),
`test_pane_effects.gd` (`test_a_cue_is_rate_limited_to_three_a_second`,
`test_a_hidden_pane_never_cues`, `test_a_tint_cue_uses_the_danger_tone`,
`test_pinning_a_cue_draws_its_final_frame`, `test_particles_are_a_fixed_preallocated_burst`),
`test_settings_panel.gd` (`test_adding_a_reactive_rule_stores_and_renders_it`,
`test_removing_a_reactive_rule_clears_it`, `test_off_clears_a_reactive_rule`,
`test_the_reactive_table_hides_add_at_the_cap`) and `test_settings_manager.gd`
(`test_reactive_rules_drop_unknown_effects_on_load`). Screenshot
([captures](../v0.8.md#screenshots)): *A pinned Tint cue on its source pane, and the Effects
section's mapping rows.*

Commits: d17bac7, 6cecfd6, 46b68e9, a287210

## CONCEPT-14

**Shared graph nodes (free DAG)** - the visual editor's rules are chains because a compiled entry's
identity is the trigger's name: one trigger = one rule, and a shared condition or action would
compile two entries under one name. Fan-in/fan-out needs OR'd triggers (`triggers: [regex…]`) and a
rule id independent of the trigger name in the vocabulary. Deferred from v0.5.4 - revisit with
demand evidence, not before.
