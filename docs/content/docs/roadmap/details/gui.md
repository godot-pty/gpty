---
title: "Roadmap details - GUI"
weight: 900
build:
  list: never
---

Every GUI row, by ID and in allocation order. The queue and its priority live on the release chain pages; this page is the evidence behind each row.

## GUI-1

**Tiling grid layout** - split panes horizontally or vertically, resize by dragging splitter
handles. Built on a Rust tile layout engine that enforces minimum pane dimensions and redistributes
space when panes are added or removed.

Commits: d17bac7

## GUI-2

**Settings persistence** - font size, cursor shape, window mode, and other preferences saved to
`user://settings.json`. Settings auto-load on startup and auto-save on change via a debounced save
timer.

Commits: d17bac7

## GUI-3

**Phosphor icon set** - 100+ icons for toolbar, sidebar, and pane action buttons. Unicode PUA
codepoints rendered via the bundled Phosphor Regular font. Icons are exposed as `const` strings in
`icons.gd`.

Commits: d17bac7

## GUI-4

**Sidebar with pane list** - collapsible left panel showing all tiles with focus, kill, minimize,
and swap buttons per pane. Also exposes window mode toggle and per-pane-type spawn buttons.

Commits: d17bac7

## GUI-5

**Full-screen mode** - three window modes: OS-decorated, borderless, and fullscreen. Custom-drawn
titlebar with minimize, maximize/restore, and close buttons. Toggle via sidebar or keyboard
shortcut.

Commits: d17bac7

## GUI-6

**Pane position and type swapping** - swap panes between grid positions or change a pane's type
(terminal ↔ code viewer) via sidebar buttons and popup menus.

Commits: d17bac7

## GUI-7

**Drag-to-resize tile edges** - drag the splitter handles between panes to resize grid columns and
rows. Built on Godot `HSplitContainer`/`VSplitContainer` with a Rust tile layout engine enforcing
minimum sizes.

Commits: d17bac7

## GUI-8

**Session auto-save** - layout and pane state persist across application restarts. PTY sessions are
recreated with fresh shells on relaunch (process state and scrollback are not restored - see the
v0.4.0 SQLite history item).

Commits: d17bac7

## GUI-9

**Workspace switching** - switch between independent pane sets within the same window (sidebar
Workspaces section, keep-alive PTYs). Each workspace has its own layout, profile, and scrollback.
Deferred from v0.3.0; prerequisite for the daemon-era workspace model.

Commits: d17bac7

## GUI-10

**Titlebar state badges** - Phosphor status badges on pane titlebars in `terminal_pane.gd` (pulsing
amber = NeedsAttention, spinner = Working, check = Completed, warning = Failed). Display only; badge
state never feeds decisions.

Commits: d17bac7

## GUI-11

**In-app update checker** - checks GitHub releases on startup and toasts when an update is
available. Fixed the placeholder repo owner, sourced the current version from
`GptyTerminal.get_app_version()`, gated on `OS.has_feature("editor")` (headless/test-safe), added
the `check_updates` setting, and covered `_is_newer` with GUT tests. (Deferred from v0.5.0.)

Commits: d17bac7

## GUI-12

**Position-swap popup re-resolves its targets** - `show_position_swap_popup` captured tile indices
when it opened, so a pane killed meanwhile (IPC `killPane`) swapped the wrong pair or indexed past
the end with no indication. Rows now carry the pane itself and are resolved by identity against the
current tile list at click time; a pane that is gone cancels the swap with a toast. `_tile_index_of`
replaces the three duplicated index lookups, and 2 GUT cases cover the shifted pair and the closed
target.

Commits: d17bac7

## GUI-13

**Pixel-smooth divider drag** - shipped the pixel-geometry approach, not the finer-grid one (which
still relayouts every step and still snaps the *content* per step): while a divider is dragged, the
tiles on the line move their wrappers by the raw pixel delta (the far side grows, the near side
shifts) with no tile mutation and no `tiles_resized` per motion, so nothing reflows until the
release. The press snapshots the line's tiles, their committed offsets, one unit in pixels, and the
unit travel limits, so `MIN_TILE` and the grid edges are enforced mid-drag in pixels and the preview
can never show a position the commit refuses; the release rounds the previewed travel to whole
units, applies it to the tile model, relayouts once, and the pane's own `RESIZE_DEBOUNCE` settles
the terminal content. The preview is absolute from the press (backtracking restores the layout), and
an edge with no tile on its far side - the window border - no longer starts a phantom drag.
Verified: 16 GUT drag tests including the new invariants (motion leaves the tile model untouched,
exactly one `tiles_resized` per drag, the preview clamps at `MIN_TILE`, backtracking commits
nothing, border edges are inert); full `ci-check`; live run at 29 px/unit - a 40 px drag previewed
the divider to 910 px (31.38 units, deliberately off a boundary) with the model untouched, then
committed span 30→31 at 899 px (11 px snap, within half a unit); mid-drag screenshot inspected for
gaps/overlap.

Commits: d17bac7

## GUI-14

**Pane file sinks** - the code viewer now reads through a type gate and a cap.
`FileAccess.file_exists` is Godot's regular-file check (measured: false for directories,
`/dev/zero`, FIFOs and even symlinks to FIFOs; true for regular files and symlinks to them) and
`get_size` is -1 for anything non-regular, so non-regular paths are refused before `open` - the
"never-EOF device hang" the first pass asserted is not reachable through this sink (a FIFO `open`
returns null without blocking); the real hazard was the unbounded read, now capped at
`MAX_FILE_BYTES` (1 MiB) with a visible truncation notice and a hand-rolled UTF-8 cut so a sequence
torn by the cap is dropped instead of rendered as U+FFFD. The file tree asks for confirmation before
`OS.shell_open`, showing the exact path, and refuses non-absolute and non-regular paths (scheme
allowlist: only an absolute local path becomes the `file://` URI the sink constructs itself - a
downloaded `.desktop` file would otherwise be *run* by the mime handler). Bonus defect found while
testing: `CodeEdit.add_comment_string` does not exist on Godot 4 - the call raised a script error
that aborted `load_file` before `_refresh_view()` for `.rs/.gd/.py/.c` files, leaving the pane on
the previous file's view; now `add_comment_delimiter` (with a regression assertion on the view
toggle). Verified: 7 new GUT tests (full/truncated/torn-UTF-8 loads, directory refusal, tree
confirmation, directory expansion without a dialog, non-absolute refusal), full `ci-check`; live run
- a 5 MiB file rendered 1,048,632 chars with the notice, a FIFO path returned in 3 ms and left the
pane empty, and the tree's confirmation dialog was screenshot-verified. (Deferred from v0.5.3.)

Commits: d17bac7

## GUI-15

**Core diagnostics are invisible in the GUI** - nothing installed a `log` logger in the GDExtension,
so every `log::warn!`/`log::error!` from the gpty crates (a failed history append, a PTY read error,
a poisoned lock, a refused capture) was dropped; only the CLI saw them, because it installs
`env_logger` itself. `diagnostics.rs` now installs a bridge at `InitStage::Core` forwarding `warn`+
records whose target starts with `gpty` to `godot_warn!`/`godot_error!`, so the message lands in
Godot's console where a user or a bug report can reach it; dependency targets (`alacritty_terminal`,
`rusqlite`, `portable-pty`) and `info`/`debug` stay out, which is what keeps the console readable.
Verified live with a probe: the same `log::warn!` that printed nothing before now shows up as
`WARNING: [gpty_gdext] …`, and a paired `log::info!` did not appear. The AGENTS pitfall that said
core warnings go nowhere is rewritten (it was written to be rewritten when this landed), and the
live-smoke skill's "grep for `godot_warn!` instead" gotcha is corrected with it.

Commits: d17bac7

## GUI-16

**`cli_view` pane** - runs a command and streams stdout into a pane body: plugin UI v1 without a
Godot SDK. Native third-party GDScript/Rust pane plugins still deferred to a future SDK
(`PaneTypes.ALL` is the layout-trust anchor; see AGENTS.md). **Closed:** argv-only by construction -
the pane's `command` + `shell_args` are the same keys the Workspace Trust gate already reads, so a
profile or manifest tile that names a program keeps asking for consent,
`gpty_core::cli::CliProcess::spawn` re-validates the program with `pty::validate_program` (a name
resolving into the working directory is refused), and `STRIPPED_INHERITED_ENV_KEYS` is removed from
the child, which is a third-party CLI. Rust owns the process: stdout+stderr piped and merged into
one bounded line queue (512 lines - backpressure, never dropped; CRLF stripped; a trailing partial
line flushed at EOF; a line past 16 KiB split, never buffered unboundedly) with `Drop` killing the
child's process group. `GptyCliView` (`crates/gpty-gdext/src/cli_view.rs`) is the `#[func]` edge -
`start` (caps: command ≤1024, ≤32 args ≤4096 each, U+FFFD refused), `poll_lines`, `status_json`,
`stop` - plus `cli::idle_status_json()` so a never-started pane parses the same shape. `CliViewPane`
keeps a 4000-line ring in a read-only `CodeEdit` (Restart/Stop, Program/Arguments rows, the
inspector's untouched-field argv rule, never auto-restarts on a debounced settings edit, stops the
child in `_exit_tree`), registered in `PaneTypes.ALL` + `TerminalManager._PaneScripts` so the
palette, sidebar, swap menu and label prefixes pick it up. The pane API reaches it:
`gpty new-pane --type cli_view --command <program> --arg <a>` (new optional `args` IPC field;
`--arg` takes hyphen values so `--arg -c` parses) and `pane-read` serves its body text; plugin
manifests accept `cli_view` tiles (`PANE_TYPES`). Evidence: 13 new `gpty-core` tests (line-assembly
boundaries plus real children - stdout, stderr merge, reaped exit code, process-group kill, refused
program), 3 FFI cap tests, `test_cli_view.gd` 7/7 (streamed stdout reaches the ring *and the visible
view*, Stop kills the child, empty command idles, sanitization, layout-state round-trip, widgets
fill the pane, display-sink role), `test_palette`/`test_pane_spawning`/`test_pane_hardening` updated
(six types; the trust gate covers a cli_view tile), manifest mirror test, and the live smoke's
`cli_view` step (`new-pane --arg` → `pane-read`). `./scripts/ci-check` green: fmt/clippy/workspace
tests/`check-ffi-surface` (61 calls), 458 GUT tests, live smoke PASS. Post-push follow-up (the first
`windows-smoke` run): the GUT tests gave the pane the fixture's *cmd.exe* command line as argv, so
`cmd.exe /c` re-parsed it - `\"` is not cmd syntax, PowerShell received the script as a quoted
*string* and printed it, and the pane showed the code with no marker (the pane never echoes its
plan, so the failure was the child's own output). The tests now spawn through the new
`ShellFixtures.print_text_argv()` - PowerShell named directly on Windows, the shell running `printf`
on POSIX - with a 20 s budget, because the child is an interpreter starting cold on a CI runner.

Commits: d17bac7

## GUI-17

**Pane contract extension** - `on_agent_state_changed(state)` in `PaneBody` for custom panes.
**Closed:** the contract is a pair of `PaneBody` methods - `agent_state_source_id()` names the
terminal a pane observes by stable `attachment_id` (a terminal returns its own id: the tiered
tracker it reads *is* that terminal's state; empty = observes nothing, the base default) and
`on_agent_state_changed(state)` receives that terminal's state (idle / working / needs-attention /
completed / failed). `workspace.gd` is the only dispatcher: `TerminalPane.agent_state_changed`,
emitted from the slow poll on a real transition, calls `_dispatch_agent_state`, and a per-frame
`_prime_new_pane_observers` scan delivers the current state once to each new observer - any
pane-entry route (spawn, restore, swap, a future pane SDK), a follower whose terminal attaches later
(retried until it does), and a pane re-pointed at a different source (the scan stores the source it
primed for, not a boolean). Panes are found through the `panes` group, so hidden workspaces keep
observing. The titlebar badge became the first implementation instead of a parallel path -
`TerminalPane.on_agent_state_changed` applies it - so the tracker→display chain *is* the contract
and the existing badge tests cover it end to end. Display-only rule unchanged (Tier 2 declarations
are spoofable, Tier 3 is heuristic; a hook may never feed a decision, action, capture, or IPC).
Evidence: `test_agent_state_contract.gd` 5/5 (terminal observes itself and lights its badge through
the hook; follower primed then told every change with values held to the published vocabulary; a
pane with no source is never called; follower attached before its terminal is primed when it
appears; re-pointed follower is primed for the new source), `test_pane_body.gd` pins the base
default, `test_agent_badges.gd` 6/6 still green through the new path (real child-printed OSC
declarations), `./scripts/ci-check` green.

Commits: d17bac7

## GUI-18

**Open supported files in a code-viewer pane instead of the system application** - the file tree's
only open path is `_confirm_open` → `OS.shell_open(file://…)`, so double-clicking a `.md`, a source
file, or a log leaves gPTY for whatever desktop handler owns the type - even though a read-only
`code_viewer` is already in the pane set and already renders Markdown. The system path is also the
sharper sink (a downloaded `.desktop` is *run* by the handler), so the in-app route is both more
useful and safer for the types it covers. **Design:** (1) one closed, unit-tested table - a new pure
`ViewableFiles` module beside `pane_types.gd` - maps a path to its viewer: a curated extension set
(source, config, docs, `md`/`markdown`, `txt`/`log`/`diff`/`patch`) plus a small exact-name set for
extensionless text files (`Makefile`, `Dockerfile`, `LICENSE`, `Justfile`). Everything it does not
list stays on the existing confirm-then-system path, so binaries, images and `.desktop` files behave
exactly as they do now; a text *sniff* is explicitly not v1 (an allowlist is predictable and
testable, and the external route is the fallback). (2) A tree activation on a supported file asks
the workspace for a **new `code_viewer` pane** carrying `file_path`; if a viewer in the active
workspace already shows that exact path it is focused instead of duplicated - a viewer's scroll,
selection and rendered/source mode belong to its document, so silently repointing an existing viewer
at another file is rejected, while side-by-side is the reason the grid exists. A deliberate second
view of one file is not a use case v1 serves; the same-path focus keeps the layout bounded and makes
a double-click idempotent. (3) The viewer gains a small **Reload** action, because "open" focuses an
existing same-path pane without re-reading it - without the button a file changed on disk could
never be refreshed in place. (4) Panes still never spawn panes: the request is a new
`PaneBody.request_pane(type, settings)` signal, connected where every body is attached
(`Workspace._attach_pane_into`) and handled by the workspace through `_spawn_pane` (the only
spawner, which already refuses a full grid) followed by `activate_pane`, so layout, activation and
the grid ceiling stay in one place. (5) Configuration is per file-tree pane -
`Open files: [Viewer pane \| System application]`, default **Viewer**, persisted in
`_get_layout_state` like `root_path` - not a global setting: the tree is the origin of the action,
several trees may want different behavior, and a global default can wait for a second origin
(CLI/IPC). Opening Markdown here is **read-only** (the existing rendered toggle; editing stays the
wiki pane's job on a known vault - "Edit this note" from a viewer whose path is inside a configured
vault is a later item). Security: the path is user-clicked, not restored; the read is
`TextRead.read_prefix` (absolute, regular-file gate, 1 MiB cap); no handler runs; the
unsupported-file confirmation is unchanged. Acceptance: a GUT unit test for the table
(case-insensitive extensions, exact names, unsupported); a file-tree test that a supported
activation emits the request and never calls `OS.shell_open` while an unsupported one still
confirms; a workspace test that the request spawns a `code_viewer` with `file_path` and focuses a
same-path viewer; a code-viewer test for Reload; and the pane-settings round trip for `open_in`.
**Closed (2026-10-18):** the closed table is `godot/scenes/panes/viewable_files.gd`
(`ViewableFiles.viewer_for`: a lowercased extension set for source/config/docs, exact extensionless
names, no content sniff), and the file tree routes an absolute activation through it - a named type
emits `PaneBody.request_pane("code_viewer", {"file_path": …})`, while anything else (or any file
when the tile's `open_in` is `system`) keeps the confirm-then-`file://` path behind the
`open_external` seam. The request is connected once in `Workspace._attach_pane_into`, the route
every spawn, restore and swap takes, so panes still never spawn panes: `_request_pane_into` holds
the type to `PaneTypes.ALL`, spawns through `_spawn_pane_into`, activates the body, and focuses an
existing viewer with the same `file_path` instead of duplicating it. `open_in` is per-tree state
saved in the tile like `root_path` (closed vocabulary `viewer`/`system`, default `viewer`, an
unknown stored value falls back), and the code viewer gained **Reload** (re-read through
`load_file`'s gate, scroll and caret preserved) because a same-path open focuses rather than
re-reads; a routed capture now clears `file_path`, so a pane showing capture text can no longer be
focused as that file's viewer. Tests: `test_viewable_files.gd` (5 - extensions, case folding, exact
names, unsupported types, nameless paths), `test_pane_file_sinks.gd` (supported activation requests
a viewer and never reaches the system handler, unsupported still confirms, `system` mode confirms a
supported file, Reload re-reads, a capture drops the file identity), `test_pane_open_request.gd` (4
- spawn+activate, same-path focus with no second tile, a second file gets its own viewer, an unknown
type is refused), and `test_pane_settings.gd` (the settings UI gathers `open_in`, the tile state
round-trips, an unknown mode falls back). Full suite green: 56 scripts, 710 tests.

Commits: d17bac7

## GUI-19

**First terminal is focused at launch** - no pane had `last_body`/focus, so
`echo typed_without_click` produced nothing until the pane was clicked (the control run typed the
same text at the prompt), and `gpty list-panes` reported `FOCUS false`.
`_apply_active_workspace_view` only activates `_tm.last_body`, which startup never sets. the view
refresh - the one path shared by launch, workspace switching and profile activation - resolves a
fallback when no remembered pane is valid: the workspace's first terminal, else its first pane,
activated through `activate_pane` (so the sidebar accent, status bar and `focusPane`-visible state
agree, and a read-only workspace still records an active row). The same hole covered a restored
workspace that was never visited and a profile rebuild, so those entries are fixed by the same rule
rather than a launch-only special case; a blank workspace still releases focus (Grid hidden → Godot
drops the owner, measured), so keys cannot flow into a hidden pane.
`godot/tests/integration/test_startup_focus.gd` pins both halves: launch leaves the first terminal
as `last_body` and the viewport's focus owner, and a line dispatched through
`Input.parse_input_event` is echoed and executed by the shell without a click (the audit's exact
observable); a second test switches to a workspace built in the background and asserts its first
terminal takes the keyboard. AGENTS.md (Pane activation) and the 0.7.0 CHANGELOG carry the rule.

Commits: d17bac7

## GUI-20

**Reset or closing a pane asks before killing running work** - verified (Reset) and code
(close/quit): a terminal with a foreground `sleep 600` was removed by one click on Reset with no
dialog, and `PaneBody.request_close` is implemented only by the Wiki pane; the sidebar's destructive
red Reset sat directly under Settings and `Ctrl+Shift+R` fired it. a terminal now reports
`has_running_work()` from the status document's new `foreground_job` sample - `tcgetpgrp` on the PTY
master vs. the spawned child, refreshed by the existing 200 ms child poll, exact on Unix (a
background `cmd &` never took the terminal and does not count; a pane whose configured program *is*
the child reports none) and `null` on Windows/ConPTY, which has no equivalent and is treated
conservatively while the shell runs. The close contract gains a second, action-level phase:
`_ask_close_then(bodies, next, declined, ask_running)` calls `_ask_running_then` first, which raises
**one** dialog naming every busy pane (capped at 8 names + a count) before any per-pane
`request_close` - a workspace close, quit, reset or profile activation asks once, not once per
terminal. `_kill` and `_swap_pane` route through the same walk, so the titlebar X, `Ctrl+Shift+W`,
the palette, a type swap and IPC-adjacent GUI paths all ask; the base `PaneBody.has_running_work()`
is false, so the wiki's Save/Discard question is unchanged and only a terminal can add the running
question. IPC callers cannot answer a dialog and must not raise one: `killPane` uses the `_kill_now`
primitive (an explicit kill is consent to stop the process; unsaved work still refuses), and
`layoutLoad` activates with `ask_running: false` for the same reason. The sidebar action is renamed
**Close all panes** with the trash glyph (it shared the counter-clockwise arrow with “change pane
type”) and the palette command is `close all panes`; `godot/README.md` follows. Tests:
`test_pane_close_guard.gd` pins the single aggregate dialog (one ask, busy panes named, idle one
not, cancel before any per-pane question, confirm then walks), a live Unix foreground command asking
and cancelling/confirming around a real `sleep 600`, an idle shell closing with no dialog, and the
Windows conservative branch; `crates/gpty-core` pins `foreground_job` at a prompt (`Some(false)`),
for a typed command (`Some(true)`) and for a background descendant (`Some(false)`). The Windows gap
(every close/quit of a live shell asks) is queued in Future rather than left implicit.

Commits: d17bac7

## GUI-21

**A profile accent leaks across workspaces** - reported: activate P1 in W1, create W2, and P1 stays
highlighted although W2 never activated it. `_active_profile` was one app-level string, set on
activation and cleared only by reset/delete; workspace switching never re-derived it. Each workspace
now records its own `profile` name (session state; restored tabs start with none), and
`_apply_active_workspace_view` re-derives the accent from the active workspace on every switch,
creation, close and restore - a new workspace starts with none, switching back restores that tab's
own, delete/rename clear or rename the name in every workspace, and reset clears it for its own tab
only. Test: `test_profile_accent_follows_the_active_workspace` (W1->P1, new W2 has none, W2->P2,
switching restores each, W2's reset leaves W1's accent).

Commits: 43cfc7a

## GUI-22

**A terminal renamed in Pane Settings leaves its Reasoning companion on the old id** - found
2026-10-28 while fixing **Agent events and agent state cross workspace boundaries**: the
pane-settings `settings_applied` handler (`workspace.gd:59-75`) migrates `PaneEnvStore` to the new
id but nothing rewrites a companion's `source_attachment_id`, so renaming a terminal (`omp-terminal`
to `agent`) leaves the Reasoning pane beside it subscribed to an id that no longer exists - events
carry the new id, `ReasoningPane.receive_agent_event` drops them, and the pane stays silent with no
error. Fix: on `settings_applied`, when a terminal's id changed, rewrite
`source_attachment_id == previous_id` to the new id for panes in that terminal's own workspace only
(a display link, not an IPC id; another workspace's companion keeps its own logical id). Tests:
rename a terminal with a companion beside it - the companion follows and receives events; the same
logical companion in another workspace is untouched. **Fixed 2026-10-28:** the rename branch now
calls `_retarget_companions(body, previous_id)`, which resolves the renamed pane's workspace
(`_workspace_for_body`) and calls `retarget_source(new_id)` on each pane there that names
`previous_id` - the follower opts in by implementing it, so a second companion type needs no
workspace change. `ReasoningPane.retarget_source` rewrites the link and keeps the bound OMP session
and its turns (the terminal never restarted), refreshes the idle status only when nothing is bound,
and leaves `apply_settings` as the path for a *different* source, which still resets. Tests:
`test_agent_event_routing.gd::test_a_pane_settings_rename_moves_the_companion_but_not_its_session`
drives the panel's real apply→emit contract, asserts the companion follows, the `session.bound`
session survives, `_get_layout_state` carries the new id (so a save cannot persist the dead one) and
a later `agent.started` is accepted; `::test_a_rename_never_reaches_another_workspace_s_companion`
hand-links a companion in another workspace to `agent-terminal` and asserts it keeps it. Both fail
without the fix (804/806, exactly the two) and `./scripts/gut-check` is 806/806 with it. Docs:
`inspector-reasoning-omp.md`, `gdscript.md` (attachment-id rule), wiki `panes/reasoning.md`.

Commits: 6740a98, 11f5274

## GUI-23

**The plugin catalog row disappears once a plugin profile is installed** - reported: after
installing gpty-lazygit, the row that led to the plugin catalog was gone, so there was no in-app way
back to discover another plugin. `update_profile_list` appended the hint only when no plugin profile
was present. It is now always the last row of the Profiles section (plugin profiles above it) and
still counts toward the section's height cap. Tests:
`test_catalog_hint_row_is_last_with_and_without_plugin_profiles`; the plugin-row test also asserts
the hint follows it.

Commits: 43cfc7a

## GUI-24

**An Inspector's prompt and auto-send choices do not survive a restart** - closed 2026-10-31 by a
user-owned store, without reopening the injection channel. `PaneInspectorStore`
(`user://pane_inspector.json`, a `PaneEnvStore` sibling) holds one record per pane id -
`system_prompt`, `auto_run`, `accept_concept_captures` - with the same loader boundary as every
store (id-pattern keys, strict field types, a 64 KiB prompt cap, 128 entries, one bad entry costs
itself, an all-default record reads as absent). The pane settings panel's `settings_applied` path is
its only writer; `PaneBody.apply_user_state` (a base no-op) is called from
`Workspace._attach_pane_into` after `_ensure_unique_attachment_id`, so `InspectorPane` overlays the
record for the id the pane actually carries on every entry route - spawn, restore, type swap - and a
file still cannot set the trio (the settings table's `file: false` drops it before the pane sees
it). A user rename moves the record and a duplicate-id collision copies it, like env; an explicit
pane close removes it (`_kill_now`, the only path that discards a single pane - restart, profile
activation, close-all, workspace close and layout restore reset the manager directly, so the aim
still survives those), and a later pane that reuses the id starts from the defaults.
`_get_layout_state` still carries no trio, so a layout or profile never writes keys the restore path
refuses. Tests: `test_pane_inspector_store.gd` (roundtrip, switch-only record, id pattern, prompt
cap on write and load, bad-shape/wrong-type/default records, entry cap, copy keeps the old record
and never overwrites, move follows the id) and `test_inspector_state.gd` (a panel-set prompt and
switches survive a rebuild; clearing removes the record; a crafted tile cannot override the user's
own record and does not rewrite it; a rename moves it; a collision copies it; closing the pane
removes it and a reused id starts from the defaults). The agent guide, SECURITY.md and the wiki now
name the store.

Commits: 9a5d540, 9e65746, ad405ad

## GUI-25

**`--split` is accepted by `new-pane` and does nothing** - closed 2026-10-31.
`TerminalManager._split_for(w, side)` now takes the side (`PaneTypes.SPLIT_SIDES`: `left`, `right`,
`top`, `bottom`) and prefers it: the target keeps the span the aspect split gives it
(`floor(span / 2)`) and the new tile takes the rest, so `right`/`bottom` are the old geometry and
`left`/`top` move the target instead. An axis that cannot hold two `MIN_TILE` tiles falls back to
the aspect choice; false - the grid-full refusal - is returned only when neither axis can.
`spawn_pane` passes `opts["split"]` through, and the `newPane` handler validates the value before
spawning (an unknown side is `-32602`, refused before a pane exists) and forwards it in the spawn
options. Tests: `test_split_honours_each_side` (the target and new tile rects for all four sides,
plus the directionless aspect case), `test_an_impossible_side_falls_back_to_the_aspect_choice`, and
`test_new_pane_split_reaches_the_tile_rect` (the real `handle(ws, "newPane", {"split": "top"})` path
to the tile rect, and an unknown side refused as bad params). The live smoke's
`new-pane --split top` step asserts the placed rect from `listPanes`. `split` is gone from
`wire.rs`'s `INERT_ARGUMENTS`, which is now empty

Commits: 6d297b5, 69f1db3

## GUI-26

**A terminal whose I/O task died keeps its child alive, so the close guard sees idle work and kills it without asking** - closed
with a second liveness field rather than by widening `running`. `running`
(`exit_code.is_none() && task_alive`, `crates/gpty-core/src/engine.rs`) stays false in this state on
purpose: it answers "is an exit code still to come", and flipping it true would rebuild the v0.5.5
bug where every waiter hung on a pane whose task had died. The status document now carries
`child_alive` (`TermStatus`, `term.rs`): the task's last `try_wait` answer, true from the moment the
child is spawned and false when a poll reaps it or the exit path's final poll returns a code, so a
`task_ended` pane whose `sleep` outlived the task says a process exists.
`TerminalPane.has_running_work()` no longer reads the document inline:
`running_work_from_status(status)` is the pure decision (a live task asks `foreground_job` as
before; a dead task falls back to `child_alive`, so the close asks before teardown SIGKILLs the
surviving process group). Tests: the existing engine test that already ended a task under a
surviving `sleep 30` now asserts `child_alive: true` beside `running: false`, the live and exited
cases assert true/false, `godot/tests/unit/test_terminal_running_work.gd` pins the document states
and their precedence (a stale `foreground_job` cannot outvote a reap), and
`test_pane_close_guard.gd`'s new `test_closing_a_terminal_whose_task_died_asks_first` spawns a real
pane whose child closes its pty (`exec 0<&- 1>&- 2>&-; sleep 30`), waits for
`exit_reason: task_ended`, and drives the actual close path: Cancel keeps the pane, confirm frees
it. GUT 910 passed, `cargo test -p gpty-core --lib` 287 passed, fmt and the gate clippy clean. Docs:
`agents/gdscript.md`'s close contract (which had called this a known gap), the gdext and IPC
`paneStatus` tables, and the exit-detection bullet in `agents/pitfalls.md`.

Commits: e158f5f, 9630fb5

## GUI-27

**A profile opens in its own workspace from its sidebar row** - reported from daily use: clicking a
profile always replaced the active workspace's layout, so keeping two profiles side by side meant
creating an empty workspace first and then re-finding the profile. The row now names both
destinations: the label still activates in the active workspace (and still asks before replacing
panes), and a trailing arrow-square-out glyph opens the profile in a new workspace. The new tab is
named after the profile and a second one gets " 2" (`WorkspaceStore.unique_name`, suffix applied
*after* the 32-character cap so the loop cannot stall on a full-length name); it inherits the active
workspace's cwd, is switched to before the restore so the reset/restore run against that tab, and is
refused at `MAX_WORKSPACES` (8) *before* the trust prompt so nobody approves a profile that cannot
open. No replace confirmation on that branch (nothing live is lost), and the Workspace Trust dialog
carries `open_in_new` through, so an approval cannot redirect the click to the other destination.
The two sidebar signals (`request_profile`, `request_profile_in_new_workspace`) stay separate: one
click never fires both. Tests: `test_profile_row_offers_both_destinations_as_separate_actions`,
`test_plugin_profile_row_shows_provenance_without_delete` (plugin rows keep the glyph, still no
delete), `test_profile_opened_in_a_new_workspace_leaves_the_current_one_alone` (tiles, cwd, accent,
grid visibility, duplicate naming), `test_profile_opened_at_the_workspace_cap_is_refused`,
`test_unique_name_suffixes_keep_the_length_cap`. Smoke: the real main scene driven headless through
the sidebar buttons - the glyph adds exactly one workspace named after the profile with its three
tiles while workspace 1 keeps its pane, a second click yields "Agent Workspace 2", and the label
still raises the replace confirmation.

Commits: 429f21d, 6cecfd6

## GUI-28

**A wiki pane reopens the note and graph it was showing** - the pane's saved state held only the
vault and the view mode, so every restart, layout load and workspace switch dropped the user back at
the note list. The layout now also carries `open_note` (a vault-relative path, opened through the
same gate as any other open) and `graph`; both are replayed once, at spawn, and ignored by the
settings panel's re-apply, so editing a font size never navigates; a note that was deleted leaves
the list, not a broken view. Unsaved text is not saved (the recovery copy covers a crash). Tests:
layout state, spawn-time restore, re-apply is inert, missing/oversized/mistyped values. It also lets
the demo recordings seed a wiki pane without a click.

Commits: 3a01570, 6cecfd6

## GUI-29

**A GUT run can wedge in a pane-spawning test and burn the whole deadline** - measured 2026-11-02
while verifying **`gut-check` hung on a GDScript parse error instead of failing fast**:
`./scripts/gut-check` with `GUT_TIMEOUT=300` was still alive after seven minutes, headless Godot
asleep with two `/bin/bash` pane children, and the log's last started test was
`test_a_collision_rename_copies_the_env_to_the_new_id` in
`godot/tests/integration/test_pane_env_restore.gd` (restores one tile into two workspaces, so two
panes exist). `timeout 300` could not end it - it had sent SIGTERM and Godot was still there - so
the run only ended when the outer session was killed; a healthy run immediately after passed (72
scripts, 913 tests, 134 s), so it is not deterministic and the parse-error probe was a coincidence,
not the trigger. Not established: which await blocks (the test spawns two panes and frees the
workspace in `after_each`), or whether CI load reproduces it. Fix direction: run that file alone in
a loop under the gate's deadline, instrument the spawn and teardown awaits (a bounded await with a
timeout instead of a bare `process_frame` chain), and fail the test rather than the gate - the gate
now bounds the wait (SIGTERM→SIGKILL), not the cause. Closed 2026-11-02 by running that method; the
wedge did not reproduce, so what ships is the attribution the next occurrence needs. **The named
file alone passed 20/20 runs** (~5 s each) under the gate's sandbox with a 120 s deadline, and **the
full suite passed 12/12 runs** under a 300 s deadline (each ~134 s, the healthy figure), with a
thread-stack dump armed for a hang that never fired - so which await blocks, and whether CI load
matters, remain unestablished. `gut-check` now watches progress as well as the clock: a run that
writes no output for `GUT_STALL_TIMEOUT` (default 120 s, `0` disables) is a hang, not a slow test -
the suite starts a test every ~0.15 s and its longest test waits 2.1 s - so it stops the run there
and the FAIL names the last `* test` GUT started, the `.gd` file it is in, the `-gselect` command
that re-runs that file alone, and the last eight log lines (`godot exited 143` and the
missing-Run-Summary sentence are suppressed once the run has been explained). Verified by forcing
the threshold: `GUT_STALL_TIMEOUT=3 ./scripts/gut-check` fails in 20.8 s naming
`test_declaration_lights_badge_and_swaps_glyph` in `res://tests/integration/test_agent_badges.gd`,
and `=1` fails in 1.3 s during startup (the conservative edge: a machine that takes 120 s to start
Godot is itself failing); the default window passed a real 134.5 s run (72 scripts, 913 tests) with
no false positive. SIGTERM still does not stop Godot while a script waits - SIGKILL does, and the
600 s deadline stays the backstop for a run that keeps printing without finishing. The suite's 31
fixed 2.1 s waits (65 s of its 134 s) are queued as their own v0.9.4 row.

Commits: 5b7e74e, 81809dc, 6cecfd6

## GUI-30

**Re-baseline the audit on the 0.7.2 build** - re-ran the October 2026 report's method on a fresh
build of this tree (app version 0.7.2, commit `41d6957`): a private sandbox with a fresh first-run
state, the real main scene/autoloads/Rust extension, synthetic clicks and keys through
`Input.parse_input_event`, and captures of the app's own viewport at 1920×1080 plus 800×500 in an
embedded `SubViewport` (method: AGENTS.md, "UI/UX assessment method"). All nine findings the report
carried are still open, none was closed by the 0.7.x work, and one is narrowed: the Pane Settings
Environment field is now 60 px tall instead of one line. The two closed v0.7.0 behaviours held: the
first terminal is focused at launch (`first_focused: true`), and Close All over a pane running
`sleep 30` raised "Stop running processes? … Close anyway?" with Cancel leaving the pane alive. The
report's "what worked well" list held too: crisp glyphs, the Phosphor set with one accent blue,
ellipsized sidebar names (`Agent Worksp…`), the status bar's active-pane label, profile-activation
feedback, the Wiki/Media empty states and tooltips on every icon-only button. The design-system
counts moved but not to a scale: 73 `add_theme_*_override` calls (was 160), 37 hard-coded
`Color(...)` literals (was 41), 57 of 71 literal font sizes still at 11–12 px, status-bar right text
4.15:1 and Close All red 3.50:1 (both below 4.5:1), no `Theme` resource, no UI-scale setting and no
light theme. The pass also found a defect no capture keyed: with an overlay open the keyboard still
belongs to the terminal behind it - typing `x` with Settings open reached the shell, and Escape
closed neither Settings nor Pane Settings nor the palette - queued below as **An open overlay
neither takes keyboard focus nor blocks the terminal behind it**. The ten captures are the
`issue-v0.7.2-*` images under Screenshots at the bottom of the [v0.8 page](../v0.8.md#screenshots);
the run again needed a scratch driver (`godot/tmp_capture.gd`, deleted after the pass), which is
what the capture-harness row below removes.

Commits: eb79bc4

## GUI-31

**The UI audit has a committed capture harness** - landed 2026-11-03:
`godot/tests/bench/ui_capture.gd` stages named states - the original nine (first launch, 4-pane
sidebar, settings, pane settings, palette, empty workspace, 1280×760 workspace, 800×500, 560×340)
and the five added by **Extend the assessment to the surfaces it did not cover** (wiki vault, wiki
graph, concept editor, plugin review, workspace trust) - through the real main scene and autoloads
and writes `<out>/<state>.png` from the app's own viewport. Pane sets are seeded through
`WorkspaceStore` (the restore path); interactions are synthetic - a click on the sidebar Settings
button, a click on the pane title bar's settings button, Ctrl+Shift+P, and Close All plus its
confirmation's OK button - and a click that stops opening its overlay fails the run instead of
capturing a wrong state. Determinism is in the driver: cursor blink off, the status bar's clock and
FPS pinned (new `StatusBar.freeze_readouts()`), the pointer parked, and the capture waits for every
grid generation, pane title and the toast queue to settle; all nine states measured pixel-identical
across two runs in separate sandboxes. `scripts/ui-capture` owns the sandbox (`scripts/ui-sandbox`)
plus `--list`/`--compare`; `scripts/ui-capture-check` asserts the two-run identity and that
`--perturb settings` changes exactly that one image; `scripts/screenshot-gpty --state <name>` stages
the same states for desktop captures and waits for the harness's ready file. Docs: testing.md's
method, `skill://gpty-ui-review`, `skill://release`, and pitfalls (`-s` scripts compile before
autoload identifiers exist). Found 2026-10-30 while deciding whether a UI skill could pay for
itself: the procedure is what needs committing, not a description of it.

Commits: 1e27fc5, eb79bc4, 113afd7, ffa9cac

## GUI-32

**Extend the assessment to the surfaces it did not cover** - extended 2026-11-03 on the 0.7.2 build
with five committed states (`wiki-vault`, `wiki-graph`, `concept-editor`, `plugin-review`,
`workspace-trust`) in `godot/tests/bench/ui_capture.gd`, and with
`scripts/ui-capture --audit-focus <state>` printing what keyboard traversal can reach (the focus
owner, the visible dialog's own focus owner, whether Escape closes the surface, every visible
`FOCUS_NONE` button, and the Tab order). Measured: the Wiki pane's toolbar and link rows (52
`FOCUS_NONE` buttons on the index note), every pane title bar (five buttons per pane) and the link
graph's three controls plus its canvas are mouse-only; a keyboard user who opens a note from the
list loses the list and the search and cannot go back; the concept editor's canvas is translucent
over the Settings panel and the sidebar; the graph draws overlapping note titles at 52 notes / 267
links; the agent-state badge tells failed from needs-attention by colour alone. The trust surfaces
themselves held: both dialogs take keyboard focus (Plugin Install Review on Install, Workspace Trust
on Restore) and close on Escape. The platform/display half (real OS resizing, 4K/HiDPI,
Windows/macOS window behaviour) cannot be staged in the committed harness and is carried to the
v0.8.6 recapture. Findings queued as **The keyboard cannot drive pane chrome or the Wiki pane**,
**The vault link graph is mouse-only**, **The vault graph's labels overlap at the bundled vault's
density** and **The agent-state badge distinguishes failed from needs-attention by colour alone**;
the pane-padding, opaque-overlay, dialog and accessibility rows absorbed the rest. Screenshots
([captures](../v0.8.md#screenshots)): *Wiki pane with the bundled vault*, *Vault link graph*,
*Concept graph editor*, *Plugin Install Review*, *Workspace Trust*.

Commits: d17bac7, 6cecfd6, 547df56, 8dc74eb, 8c58684

## GUI-33

**An open overlay neither takes keyboard focus nor blocks the terminal behind it** - measured
2026-11-03 on 0.7.2: with Settings open and a terminal focused, typing `x` reached the shell and
Escape closed neither Settings, Pane Settings nor the command palette, because a focused pane
consumes every key in `_gui_input` (`accept_event()` on its fall-through path) after writing the raw
ESC to the child, so each overlay's `_unhandled_input` Escape handler never ran; the palette's field
also focused nothing (`find_child("*")` returned the palette's `VBoxContainer`). The concept editor
was the exception (it grabbed focus and Escape closed it). Fixed 2026-11-04: the four overlays
(Settings, Pane Settings, the palette, the concept editor) extend `OverlayPanel` and take the
keyboard on open - `open()` remembers the focus owner and focuses a control inside
(`_initial_focus()`, else the first reachable descendant), so a typed character goes to the overlay;
Escape is handled in `Workspace._input`, before GUI input, with `_keyboard_overlay()` naming the
topmost visible overlay; `close()` emits `keyboard_released` only when the overlay still owned the
keyboard (a click that already moved focus is never overridden), and the workspace then focuses the
overlay underneath (the concept editor returns to Settings) or the active pane; a click behind an
open overlay no longer activates a pane. The palette moved to `ui/command_palette.gd`, which fixes
its focus target. Measured 2026-11-04 with `scripts/ui-capture --audit-focus`: settings,
pane-settings and palette now report the focus owner inside the overlay and `escape ... closed=true`
(before: `focus-owner=.../Body` and `closed=false` for pane settings and the palette). Tests:
`godot/tests/integration/test_overlay_focus.gd` (a real shell per run: typing never reaches the PTY,
Escape leaves the grid unchanged and the next typed command still runs, focus returns to the
terminal, the editor returns to Settings, a palette spawn keeps the new pane, a click behind an
overlay activates nothing) and `godot/tests/unit/test_overlay_panel.gd`; `scripts/ui-capture-check`
is still pixel-identical on the four states. Rule: `docs/content/docs/agents/gdscript.md` ("Overlay
keyboard ownership").

Commits: eb79bc4, 547df56, c7699bc

## GUI-34

**The keyboard cannot drive pane chrome or the Wiki pane** - measured 2026-11-03 on 0.7.2 with
`--audit-focus`: every pane title bar's five buttons were `FOCUS_NONE` (20 mouse-only buttons in the
four-pane state) and the Wiki pane's Back, New, Graph, Edit/Split/Preview, Rename, Delete, Save and
every link row likewise (52 on the index note), and opening a note with Enter hid the list and the
search while nothing handled Escape - the editor consumes Tab for indentation, so a note was a hard
keyboard trap. Fixed 2026-11-04: the five title-bar buttons are `FOCUS_ALL` with an explicit
`focus_next`/`focus_previous` ring (`TerminalManager._wire_chrome_keyboard`), the body's own
traversal continues into its first button, `Ctrl+Shift+E` (`Workspace._focus_active_pane_chrome`) is
the way in from a terminal (which consumes Tab for its child; it does nothing while an overlay owns
the keyboard), Escape hands the keyboard back to the pane (a terminal takes it itself; a read-only
pane's first reachable control takes it, `KeyboardFocus.first_reachable`)
(`Workspace._escape_pane_chrome`), and a chrome action that leaves the pane on screen returns focus
to it. The Wiki pane's controls and link rows are ordinary tab stops, opening a note focuses the
buffer (or Back for a note past the 1 MiB cap), leaving focuses the list, and Escape is Back behind
the existing Save/Discard/Cancel guard. Measured 2026-11-04: `--audit-focus sidebar` reports
`focus-none-buttons=0` (was 20) and a tab-order that enters
`TitleBarButtons/{Minimize,SwapPosition,ChangeType,PaneSettings,ClosePane}` and wraps;
`--audit-focus wiki-vault` reports `focus-none-buttons=0` (was 52). Godot finding: `_gui_input` is
delivered to the focused control only and does not bubble to ancestors on 4.7.2 (measured), so both
Escape paths read the input stage and scope themselves with the focus owner. Tests:
`test_title_bar_keyboard.gd` (ring, entry, Escape back, overlay guard, restore returns the
keyboard), `test_wiki_pane.gd` (Escape from a clean note writes nothing and focuses the list, Escape
on a dirty note asks and Cancel keeps it, no visible wiki action is mouse-only), `test_keyboard.gd`
(Escape still reaches the child as ESC). Docs: the keyboard-shortcuts wiki page, the GDScript page
(pane chrome is a keyboard toolbar) and the pitfalls page (the bubbling trap).

Commits: 547df56, b699d07

## GUI-35

**The agent-state badge distinguishes failed from needs-attention by colour alone** - `failed` and
`needs-attention` both rendered `Icons.WARNING_CIRCLE` and differed only by `BADGE_FAILED_COLOR`
(red) and `BADGE_ATTENTION_COLOR` (amber), and the 12 px glyph `Label` carried no text, tooltip or
accessible name, so a protan/deutan user could not reliably tell a failed turn from one that wants
attention and a screen reader got nothing. Fixed 2026-11-04: `TerminalPane.BADGE_STATES` is the one
table per state (`glyph`, `color`, `label`), `failed` is an X-circle and `needs-attention` the
warning triangle (`Icons.X_CIRCLE` = U+E4F8, `Icons.WARNING` = U+E4E0 - both codepoints resolved by
rendering the bundled Phosphor font, because it has no glyph names), the `label` is at once the
hover tooltip and `accessibility_name` (the badge is `MOUSE_FILTER_PASS` because Godot only resolves
a tooltip for the control under the pointer - measured on the headed build, a pointer motion over
the badge makes `gui_get_hovered_control()` the badge and `get_tooltip()` return `Failed`; headless
Godot tracks no pointer at all, even over a plain `Button`, so the suite asserts the hover target
and the string rather than the popup; the title bar has no click or drag handler, so no gesture
changed), and `accessibility_live` is polite so a change reaches a connected screen reader without
focus; idle hides the badge and clears both strings. Tests: `test_every_state_has_its_own_glyph`
(four states map to four distinct glyphs, each present in the bundled font - a wrong codepoint
renders tofu that no colour difference rescues),
`test_badge_carries_text_for_pointer_and_screen_reader` (a Tier 1 `needs-attention` state shows the
triangle with tooltip and name; runs on Windows too, unlike the OSC path) and
`test_failed_declaration_shows_the_x_circle`. The new `agent-badges` capture state stages all four
at once (1280x420, four tiles) and repeats pixel-identically
(`scripts/ui-capture-check --perturb agent-badges agent-badges`), which required pinning the badge
animation: the spinner cycles at 8 fps and the attention pulse at 1.2 Hz, so the state pins
`_badge_anim` to 0 and stops the pane's per-frame work after the poll paints it - later superseded
by *The `working` badge is a thin arc that reads as a dim dot at 12 px*: the table moved to
`AgentBadge.STATES` in `ui/agent_badge.gd` and the harness freezes the badge's own clock instead.
The graph's other signals held: a ghost is a double ring plus an "N missing" count, and the open
note is named in the status line. Screenshot ([captures](../v0.8.md#screenshots)): *Agent-state
badges*.

Commits: 547df56, 3754288, 6686ba4

## GUI-36

**Shared theme, type scale, colour tokens and UI scale** - closed 2026-11-04.
`godot/scenes/ui/ui_tokens.gd` is the one token module (13 chrome colours, a 7-step type scale
11/12/13/14/16/18/36 with 12 the body size, a 7-step spacing scale, one corner radius) carrying
`CONTRAST_PAIRS` and `contrast_ratio()`; `ui/ui_theme.gd` builds the one `Theme` from it (`Window`,
`AcceptDialog` with `ConfirmationDialog` by class fallback, `GraphEdit`/`GraphNode`, tabs, popups,
inputs, lists, scrollbars, tooltips, separators) and `Workspace._ready()` applies it on the scene
root, which every pane, overlay, popup and dialog inherits - verified on 4.7.2: an `AcceptDialog`
child resolves the themed panel, and `OptionButton`/`MenuButton` resolve `Button`'s items through
the class chain. Migrated, not layered: `add_theme_*` overrides 163 -> 109, and the 54 gone are the
ones that only restated a theme default; every surviving font-size and spacing call reads a token,
so no numeric font-size literal and only two deliberate `0` separations remain, and `Color(...)`
literals outside the token module 47 -> 0 (a lighter red is required under 4.5:1 on these
backgrounds, so pure red is asserted to *fail* the table). Two measured contrast failures fixed: the
status bar's right-hand text 4.15:1 -> 6.35:1 (`TEXT_MUTED`), Close All 3.49:1 -> 6.75:1 (`DANGER`).
UI scale: `SettingsManager.cfg_ui_scale` (presets 100/110/125/150/175/200 %, clamped 100-200 on
load) drives `get_window().content_scale_factor` - the mechanism that also scales hard-coded
`custom_minimum_size` and margins, which a font multiplier cannot - applied on load and on every
settings change, with a picker in the Appearance tab; the terminal's own font size stays a separate
setting. Tests: `test_ui_tokens.gd` (the 16-pair table, the WCAG reference points, a deliberately
failing pair), `test_ui_theme.gd` (opaque surfaces, the type scale, class fallbacks, the checkbox
regression, the embedded title bar), `test_ui_scale.gd` (factor, window scale, loader clamp, the
workspace applying both). Screenshot ([captures](../v0.8.md#screenshots)): *UI scale at 125 %* and
*First launch on the design system*.

Commits: d17bac7, eb79bc4, 4ae2c65

## GUI-37

**The app chrome has a light theme, and it follows the system** - closed 2026-11-05.
`godot/scenes/ui/ui_palette.gd` is the colour owner: two complete sets (`DARK`, `LIGHT`, 18 tokens
each) with the five terminal-facing entries equal in both, because they are drawn over the
terminal's own scheme; `UiTokens` keeps the type scale, spacing, radius and `contrast_ratio()`.
Every read site is `UiPalette.active()` at draw time (the old `const`s are gone, so a cached copy
cannot compile), and 14 token-carrying `add_theme_color_override` sites became four `Theme` type
variations (`MutedLabel`, `DangerLabel`, `WarningLabel`, `AccentButton`) plus a palette-read
status-bar surface - the sidebar's `Color.WHITE` tint, which is invisible on a light sidebar, went
with them. `SettingsManager.cfg_appearance_mode` (`Dark` / `Light` / `Follow system`, a picker at
the top of Settings → Appearance) resolves through `system_is_dark`, a seam over
`DisplayServer.is_dark_mode()`; `Follow system` registers
`DisplayServer.set_system_theme_change_callback` (dispatched deferred, so the switch runs on the
main thread) and a platform without the query answers dark. `appearance_changed` fires only when the
answer moves; the workspace rebuilds the `Theme`, resets the clear colour, re-pushes the chrome
colours and the terminals' overlay colours, and carries every uncustomised chrome colour to the new
set (a value equal to either set's default has never been chosen, so it follows instead of pinning).
Measured: `LIGHT.TEXT` on `LIGHT.SURFACE` is 16.70:1 and the tightest light pair is `WARNING` on
`SURFACE_RAISED` at 4.80:1, so both sets pass every pair (dark is unchanged: 13.07:1 and 8.40:1).
Capture states `light-workspace` and `light-settings` are committed for the v0.8.6 recapture. Tests:
`test_ui_palette.gd` (set parity, declared-field reflection, both sets through every contrast pair),
`test_settings_manager.gd` (round-trip, clamp, the seam, idempotence, carry-vs-override),
`test_ui_theme.gd` (a light `Theme`, the role variations), `test_settings_panel.gd` (the picker,
reset), `test_workspace_settings.gd` (a live switch moves the panel, clear colour, wrapper, sidebar
and status bar). The terminal's own light/dark scheme pair stays with the v0.8.4 row, which consumes
the same signal.

Commits: 6cecfd6, 017e1cb, 8dc74eb, 8c58684

## GUI-38

**Settings and Pane Settings are opaque and readable** - closed 2026-11-04: `Panel`,
`PanelContainer`, `PopupPanel`, `AcceptDialog` and the concept editor's `GraphEdit` take an opaque
`UiTokens.SURFACE` (`#202128`) with a 1 px `BORDER`, so no pane content, tab or Add Pane grid shows
through the Settings cards, the Pane Settings card or the graph canvas (the stock stylebox was
`(0.1, 0.1, 0.1, 0.6)` - `1a1a1a99`, the row's 60 %), and `Tree`/`ItemList` take an opaque content
background. The panel's `Attachment ID` field gained the sentence that was missing ("The id IPC, MCP
and agent commands address this pane by"), and every label and hint in both panels is on the token
type scale. Verified by `test_ui_theme.gd` (`bg_color.a == 1.0` for each type, `== UiTokens.SURFACE`
for the chrome ones) Screenshots ([captures](../v0.8.md#screenshots)): *Settings, opaque* and *Pane
Settings, opaque and explained*.

Commits: d17bac7, eb79bc4, 547df56, 4ae2c65

## GUI-39

**Dialogs and profile forms match the app** - closed 2026-11-04: one builder,
`godot/scenes/ui/app_dialog.gd` (`AppDialog.confirm`/`alert`/`set_body`/`body_of`/`group_buttons`),
constructs and parents all 19 `ConfirmationDialog`/`AcceptDialog` sites; the four `FileDialog`s
inherit the same theme. Buttons group at the right edge: `about_to_popup` collapses Godot's
per-button `SIZE_EXPAND_FILL` spacers except the leading one - Restore to Cancel measured ~290 px
apart in a 1046 px dialog before, 8 px (the row's own separation) after. Text the user must read and
may need to copy moved to a read-only `TextEdit` body (workspace cwd trust, restore trust, profile
trust, plugin review, the open-file and open-external-link confirms): the pinned revision and the
spawn plan are selectable, and a path containing `[b]` cannot be read as markup. Save Profile: each
command field gets a 220 px minimum (was 69 px against `/bin/bash`'s 75), the command scroll area
300 -> 340 px, the name field 320 px, so the path no longer clips to `/bin/ba`; the dialog follows
its content's minimum. Tests: `test_app_dialog.gd` (grouping geometry, the leading spacer, a button
added after construction, the selectable body, the fallback accessor); `test_workspace_cwd_trust.gd`
and `test_pane_file_sinks.gd` read a dialog's text through `AppDialog.body_of`, same assertions.
Screenshots ([captures](../v0.8.md#screenshots)): *Save Profile* and *Workspace Trust*.

Commits: d17bac7, 6cecfd6, eb79bc4, 547df56, 4ae2c65

## GUI-40

**An empty workspace has an intentional empty state** - closed 2026-11-04: `Workspace._ready()` sets
the viewport clear colour to `UiTokens.BG` (`#1a1a1a`, was Godot's default `rgb(76,76,76)`), and a
mouse-transparent `EmptyState` centre container shows "No panes" and "Ctrl+Shift+N opens a terminal"
- the second line formats `PaneTypes.ALL["terminal"]["shortcut"]`, so the hint cannot drift from the
binding it names. It is visible exactly when the active workspace has no tiles (`_apply_layout` is
the one sync point every create and kill path already reaches) and leaves on the next spawn; the
sidebar's `Panes:` heading hides with its list. Tests: `test_workspace_settings.gd` (guide shows
after Close All, hides on spawn) and `test_sidebar.gd` (heading follows the list). Screenshot
([captures](../v0.8.md#screenshots)): *Empty workspace after Close All* (the post-fix capture).

Commits: d17bac7, eb79bc4, 4ae2c65

## GUI-41

**A UI scale above 100 % can push the layout under its own minimum** - reproduced 2026-11-05 on the
development build by adding the `ui-scale-125-800x500` capture state: an 800×500 window at a 125 %
request lays the interface out in `800 / 1.25` = 640×400, under the Settings card's 540×560. Fixed
by capping the applied scale, not by reflowing: `UiTokens.MIN_LAYOUT` (540×560, the same constant
the card sizes itself to) and `UiTokens.ui_scale_ceiling()` (the largest whole percent whose layout
fits; -1 when the window cannot be measured), applied through
`SettingsManager.capped_ui_scale_percent()` / `applied_ui_scale_percent()`. `apply_ui_scale()`
writes the applied factor - guarded by `is_equal_approx` against the `size_changed` its own
assignment emits - and `_on_window_resized()` re-applies it, so dragging the window smaller steps
the scale down and growing it back restores the request; `cfg_ui_scale` and `ui_scale_factor()` keep
meaning "what the user asked for". The floor is 100 %: a window already under 540×560 keeps the
clipped 100 % layout instead of a sub-100 % interface, which is the v0.8.2 small-window row's work.
The Appearance tab's scale row appends `shown at N %` (the tooltip carries the 540×560 reason) while
the picker keeps the request. Verified: `test_ui_scale.gd` (ceiling table 89 / 192 / 135 / -1, cap
table, applied factor at 800×500, the resize hook both directions) and `test_settings_panel.gd`
(hint text, tooltip, `MUTED_LABEL` variation, hover target); the capture logs read
`window=1920x1080 ui_scale requested=125% applied=125%` and
`window=800x500 ui_scale requested=125% applied=100%`, both states pass `scripts/ui-capture-check`
(pixel-identical reruns, perturb local), and the constrained PNG is 800×500 at the 100 % layout (180
px sidebar, one full tile).

Commits: 4ae2c65, 611b8f0

## GUI-42

**Window controls never swap maximize/restore** - fixed 2026-11-06: the glyph is the shared
icon-button treatment (`Icons.icon_button(btn, glyph, name)`, the codepoint in a child `Label`), so
`WindowChrome` keeps its maximize control in `_max_btn` and `_sync_max_button()` reads
`cfg_window_mode` instead of comparing a `Button.text` that is now always empty - fullscreen shows
`Icons.RESTORE_WIN` and "Restore window", every other mode `Icons.MAXIMIZE_WIN` and "Maximize
window", with the name moving first so `Icons.set_glyph` mirrors it onto the Label (a node's exposed
name is still a creation snapshot, see **Element values do not reach the AT-SPI adapter**). It is
driven from `apply_mode()`, so `toggle_fullscreen`, `on_window_mode_selected` and the restore path
all reach it; `test_window_chrome.gd` asserts the glyph and the name in modes 0/1/2, one assertion
through `apply_mode()`, and that all three controls draw their codepoint in a Label with
`text == ""` while keeping the bar's 36 px target.

Commits: 8cb09fd, 6918477

## GUI-43

**Global shortcuts stay live while an overlay owns the keyboard** - fixed 2026-11-05: the registry
split lives in `ShortcutManager` - `register(..., survives_overlay)` and one injected predicate,
`ShortcutManager.overlay_owns_keyboard`, which `Workspace` sets from `_keyboard_overlay()` and
resets to `false` in `_exit_tree()` - so the decision is made once instead of by a guard in each
callback. Exactly four window actions survive: `app:toggle_palette`, `app:toggle_sidebar`,
`app:toggle_fullscreen` and `app:toggle_fullscreen_alt`. Every other chord (the per-type spawns,
close, pane-chrome and note-toolbar focus, reset, next/previous workspace, `FocusManager`'s
`focus:*`) is refused and the event consumed with `set_input_as_handled()`, so it neither spawns
behind the panel nor reaches the terminal (`terminal_pane.gd` already drops a registered chord
before sending bytes). Escape is unchanged - `Workspace._input` owns it before GUI. Tests:
`test_overlay_focus.gd` shows `Ctrl+Shift+N` while Settings is open spawns nothing and leaves the
panel focused, and `Ctrl+Shift+P` still opens the palette over it.

Commits: c7699bc, 611b8f0

## GUI-44

**A FileDialog still wears Godot's stock grey frame** - closed 2026-11-06:
`AppDialog.picker(parent, title, file_mode, access)` is the one builder - borderless, the engine
label hidden, and a header of its own (a title Label and an `Icons.CLOSE` button wired to the
engine's cancel button, so `canceled` and a site's `queue_free` behave exactly like Cancel) inserted
at index 0 of the picker's own internal `VBoxContainer`. Measured on 4.7.2: that column is not
rebuilt by `file_mode`, `access`, a filter add or a re-popup, and `min_size.y` grows by the header's
height so the strip sits above the path bar instead of over it. All four sites migrated (workspace
directory, terminal font and scheme, Settings font); `test_app_dialog.gd` pins the shape, the
close's cancel path and one header across a popup. Escape re-checked:
`scripts/ui-capture --audit-focus file-dialog` reports `dialog=Working directory for Workspace 1`, a
picker control as its focus owner and `escape overlay=… closed=true`. Screenshot
([captures](../v0.8.md#screenshots)): *File picker frame*.

Commits: d85c3ca, 6918477

## GUI-45

**Pane chrome: one icon-button treatment, signed off by the owner** - closed 2026-11-06 with the
owner's choice (2026-11-05): the glyph alone at rest on `StyleBoxEmpty`, an `ACCENT`-tinted
hover/pressed, the 1 px accent focus ring, one `UiTokens.BUTTON_MIN_WIDTH`/`BUTTON_MIN_HEIGHT`
target shared with the sidebar, and text buttons keeping the theme's filled base. It is one
mechanism rather than a sweep with per-site choices:
`Icons.icon_button(btn, glyph, name, variation)` applies `UiTheme.ICON_BUTTON`, floors the width and
draws the codepoint in a child `Label` (`Icons.glyph`/`Icons.set_glyph` read and swap it), which
also stops the engine composing `"<name>: <codepoint>"` into the exposed name; all 21 call sites
moved, `WindowChrome._make_titlebar_button`'s hand-built Label was deleted in its favour, and the
sidebar's set-directory glyph takes `UiTheme.ACCENT_LABEL` (a Button's own font colours cannot reach
the child). `test_icons.gd`, `test_ui_theme.gd` (the variation's five styleboxes plus
`ACCENT_LABEL`) and the accessibility audit (`glyph-buttons=46 unnamed=0` on the sidebar state) pin
it. Screenshot ([captures](../v0.8.md#screenshots)): *Icon buttons*.

Commits: 9a65141, 8cb09fd, 6918477

## GUI-46

**Pane chrome: distinct icons, a compact action menu, padding and consistent empty states** - closed
2026-11-08: the title bar is three controls - **Pane settings**, **More actions**, **Close** - so
the type list no longer costs a button; the bar reserves 74 px, was 122.
`TerminalManager.show_pane_actions_popup` is the one menu: minimize/restore (the label follows the
pane's state), swap position (disabled while one tile has nothing to swap with), and the eight types
as radio-check items with the current one marked; the sidebar's pane row opens the same builder, so
the two surfaces cannot drift, and choosing the current type is a no-op rather than a same-type
rebuild (`swap_pane` does allow one, which a test pins). The overflow glyph is U+E204
`dots-three-outline`, resolved by rasterising the bundled font -
`godot/assets/fonts/Phosphor-Regular.ttf` has unnamed `uniXXXX` glyphs at 1024 units/em, and the
solid `dots-three` U+E1FE is 96 units tall, three ~1.5 px specks at 16 px - and `Icons.RESET` now
means only "reset a value to its default". `PaneBody.CONTENT_INSET` (6 px, via `_fill_content`)
insets the five text panes (Inspector, Reasoning, Code Viewer, CLI View, Wiki); the terminal grid,
the media surface and the File Tree list keep their own bounds. `PaneBody.empty_state` is the one
"nothing to show" surface: Media migrated onto it, and the Code Viewer gained **"No file open"**
with "Open a file from the File Tree, or set a path in pane settings." where it used to be a
disabled Reload over a blank editor (a routed capture still counts as content, so it is not empty).
Three claims in this row were already closed and are recorded here instead of re-fixed: the CLI View
copy has used a comma since 0.7.2, Close All has carried `Icons.DELETE` since the UX-02 fix, and the
button floors are 22x18 in a 26 px bar. Tests: `test_pane_actions_menu.gd` (type marking, item
order, the no-op current type, a real swap, minimize/restore), `test_code_viewer_empty_state.gd`
(the empty state, a file replacing it, a capture without a file, the four insets),
`test_title_bar_keyboard.gd` and `test_sidebar.gd` updated to three controls. Capture state
`pane-empty-states` in `godot/tests/bench/ui_capture.gd`. Screenshots
([captures](../v0.8.md#screenshots)): *Pane padding and empty states*.

Commits: d17bac7, 6cecfd6, eb79bc4, 547df56, 6e579f8

## GUI-47

**The File Tree shows an empty list when its root cannot be listed, and says nothing** - fixed
2026-11-08: the pane now renders its shared `PaneBody.empty_state` surface (the type's own `/>`
glyph) instead of an empty `Tree` whenever the root cannot be listed, one sentence per state - **No
folder open** (an empty `root_path`, or one that is not an absolute path; the message repeats the
value), **Not a folder** (the path names a file), **Folder not found** (nothing at that path on this
machine), **Cannot list this folder** (the path exists but the open fails) - and a folder that
really is empty keeps its own sentence, which also says hidden entries are not listed. Every hint
names the resolved path and where the fix is, because a profile or a saved layout can carry a path
this machine does not have. One gate, `open_for_listing(path, opener) -> {dir, problem}`, returns
`dir` null exactly when `problem` explains why, and the five `*_problem(path)` builders are the same
functions the test reads; `open_dir` is the test seam (a Callable the test replaces), so the
open-failure state is reached without depending on the suite's privileges. A subfolder that cannot
be listed on first expand toasts the same title and hint instead of staying silently blank; an empty
subfolder still just has nothing to expand. `test_file_tree.gd` pins all five messages, the
rows-visible state, and the recovery path (`apply_settings` with a fixed root swaps the sentence for
the rows). Screenshot ([captures](../v0.8.md#screenshots)): *File Tree, missing root*.

Commits: 6e579f8, ac1ff06, 333f03a

## GUI-48

**Every scrollable surface has a 0 px scrollbar** - closed 2026-11-08: the affordance was never
styled - `ScrollBar/scroll` and `scroll_focus` were `StyleBoxEmpty` and the grabber boxes were
margin-less `StyleBoxFlat`s, and Godot 4.7.2 takes a bar's thickness from the track stylebox's
content margins plus `VScrollBar.padding_left/right` and `HScrollBar.padding_top/bottom`
(`ScrollBar::get_minimum_size`; the grabber's own margins only set the thumb's minimum length), so
every `ScrollContainer` reserved a 0 px column with nothing drawn and nothing to drag - a wheel was
the only way to learn that a tab continues. `UiTokens` now owns the geometry (`SCROLLBAR_THICKNESS`
8, `SCROLLBAR_INSET` 1, `SCROLLBAR_MIN_THUMB` 24) and `UiTheme.build` derives the rest from it: a
`SURFACE_RAISED` track whose content margins are the 6 px thumb width, an accent-bordered
`scroll_focus`, a `TEXT_MUTED` 0.75 thumb inset 1 px inside the track with a 24 px minimum length
(3.57:1 against the track in dark, 3.34:1 in light - above WCAG 1.4.11's 3:1 for a UI control), and
`ACCENT_HOVER`/`ACCENT` for highlight and pressed. Measured 2026-11-08 on the fix build: the bar's
own minimum is (8, 30) vertically and 8 px thick horizontally; Settings → Terminal's bar is (8, 441)
where it was (0, 441), page 441 over max 503 - the audit's 62 px overflow - so its thumb is 384 px
of the 441 px track (87 %), and the card stays `UiTokens.MIN_LAYOUT` (540×560). Tests:
`test_a_scrollbar_reserves_a_column`, `test_the_scrollbar_track_and_thumb_are_visible_controls`,
`test_an_overflowing_scroll_container_gets_a_real_bar` (`test_ui_theme.gd`) and
`test_the_terminal_tab_shows_a_scrollbar_column` (`test_settings_panel.gd`); the `settings-terminal`
and `settings-terminal-150` capture states cover the 100 % and 150 % views. Staging the 150 % view
forced a harness fix: `Input.parse_input_event` takes window coordinates while a Control's rect is
in layout space, so a synthetic click under a content scale landed 2/3 of the way to its target and
the panel never opened - the capture driver now maps a click through the root viewport's final
transform (identity at 100 %, where every committed capture came out byte-identical before and
after). Screenshot ([captures](../v0.8.md#screenshots)): *Settings → Terminal's scrollbar*.

Commits: e81de90, 07a8539

## GUI-49

**Command palette: population, selection and honest entries** - closed 2026-11-08: opening
`Ctrl+Shift+P` lists all 14 entries at once (one "new …" per `PaneTypes.ALL` entry, then the 6
actions; the `Save Command…` entry added with the saved-commands row makes it 15 today) in a 560x480
card centred on the workspace - (320,160) in a 1200x800 workspace, where the old 320x160 panel put
its top-left corner on (600,400); at the 560x340 layout floor the card clamps to 528x308 instead of
hanging outside its host. Every row shows words rather than the command id, the registry's own glyph
(`>_ {} /> @ ? $_ [] \|>`) and the chord it answers, read from the binding registry
(`ShortcutManager.chord(action)`) instead of a repeated literal: 6 of the 14 rows carry one
(`Ctrl+Shift+N/D/T/O`, `Ctrl+Shift+W`, `Ctrl+Shift+R`). Up/Down move a `UiTheme.SELECTED_ROW` cursor
- an accent wash plus a 2 px accent leading edge, so the row Enter would run is identifiable without
colour alone - clamped at both ends, and Enter runs the cursor instead of the first match; rows are
`FOCUS_NONE` on purpose, because the field is the palette's one keyboard surface and Tab must not
park a user on a row that cannot also type the filter. The developer-only `spawn 16 terminals`
command is deleted rather than hidden, with its only callers (`Workspace._spawn_bulk`,
`TerminalManager.spawn_bulk`), and `save`/`load` are renamed
`Save Workspaces`/`Reload Saved Workspaces` - the last two destructive rows (`Close All Panes`,
`Reload Saved Workspaces`) wear `DANGER_LABEL`, because reloading destroys the open panes. A miss
says `No matching command` instead of showing a blank card. The list is pure data now
(`ui/palette_model.gd`: `entries()`, `commands()`, `filter()` with three stable tiers - label
prefix, label substring, command/keyword substring - returning copies, so a caller cannot mutate the
const), which is the extension point **Saved commands** below appends to. Tests:
`test_palette_model.gd`, `test_shortcut_manager.gd` (the round trip
`format_chord(_parse_bind(s)) == s`), `test_palette.gd` (populated on open, row name/glyph/chord, no
developer command, arrows + Enter + clamp, the empty state, the card at 560x480 and 528x308) and
`test_ui_theme.gd`'s `SELECTED_ROW` case; a live smoke drove `Input.parse_input_event` through the
real main scene (Ctrl+Shift+P, typed `new `, Down twice, Enter spawned the selected file-tree pane,
Escape closed it with no command). Audits: `--audit-accessibility palette` lists all 14 rows by
name, `unnamed=0`; `--audit-focus palette` - the field is the focus owner, Escape closes the
overlay, `components=3 rings=1 reached=31` (the rows are `FOCUS_NONE` by design and reached with the
arrow cursor, not Tab; the count grew from 30 when the sidebar's Help button joined its ring), and
the `palette` capture repeats pixel-identically (`ui-capture-check palette` PASS). Screenshot
([captures](../v0.8.md#screenshots)): *Command palette on open*.

Commits: c7699bc, 0ef6d8c, e5b9cb0, 2145039

## GUI-50

**Saved commands: insert or run a frequently used command from the palette** - closed 2026-11-09:
`godot/scenes/autoloads/saved_command_store.gd` (`SavedCommandStore`, `user://commands.json`,
`{commands: [{name, command, run}]}`) is the one place a saved command lives - at most 200 entries,
a 64-character name and a 1024-character command, LF/CR/TAB folded to one space with every other
control dropped (a Godot `String` cannot hold a NUL at all: measured, both a literal and
`String.chr(0)` read back as U+FFFD), names compared case-insensitively with the first of a
duplicate keeping its row on load, and `add`/`update`/`remove`/`move` the only writers, so a
profile, layout, plugin or IPC call has no path in. The seventh Settings tab (**Commands**, between
Concepts and About) is the authoring surface: an `ItemList` of `Name  (Insert\|Run)` rows with the
command as tooltip, `Add…`/`Edit…` through an `AppDialog` that does **not** hide on OK
(`dialog_hide_on_ok = false`, so a refusal keeps what was typed), `Delete`, `Up`/`Down`, an
empty-state sentence, and no reset footer because a reset would delete the one thing the tab holds;
`open_commands(add_now)` is the palette's entry. The palette lists them under one **Saved commands**
heading after the fixed rows, in store order, each hinting `Insert` or `Run`, and `Save Command…`
(after `Open Settings`) opens that tab with the form already up. Delivery is one function: `run`
goes through `_send_line_to_term` (the line path carries Enter), an insert through `_send_to_term`
(raw bytes), then `_snap_to_bottom` - only to the **active terminal pane**, and `run` is off on a
new entry. `Workspace._saved_command_refusal()` returns one sentence for the three no-target cases
(no pane, the active pane is not a terminal, it is minimized); the palette uses it as the refused
rows' tooltip and accessible description (rows `disabled`, cursor steps over them, Enter does
nothing) and the dispatcher toasts the same sentence, so a hint and the behaviour cannot disagree.
The seventh tab needed room: measured on this tree the seven tabs want 520 px of the card's 500 px
bar at the theme default (12 px text, 8 px tab padding), and Godot hides the overflow behind a
dropdown (a hidden tab's `get_tab_rect` comes back zero-based, which is why the guard reads the
rects as one contiguous row and sums them). `UiTheme` now sets `font_size` for `TabBar` **and**
`TabContainer` at `FS_CAPTION` (11) - the container's item is the one the engine copies into the bar
it creates, so the `TabBar` entry alone left the live bar at the theme default - with 6 px tab
padding: 490 px of 500, all seven tabs on the bar. Tests: `test_saved_command_store.gd` (round trip,
`run` default off, sanitizing, the 1024 cap, case-insensitive duplicate, the 200 cap, a
junk/duplicate/oversize file, move/no-op bounds, copies handed out), `test_palette_model.gd` (saved
rows after the fixed list, exact entry shape, heading, filtering by name), `test_palette.gd` (one
heading, refused rows with the reason, a recording pane proving the exact bytes and the
insert-vs-line split, a real shell proving an insert does not run and a run does - judged by a file
the command would create, since a redrawing shell can echo a pending line more than once - a deleted
name writing nothing, `save command` opening the tab and the form), `test_settings_panel.gd` (list
text and tooltip, add with `run` off, duplicate keeping the dialog, edit in place, delete, reorder
keeping the selection, button enablement, empty state, the seven tabs contiguous and inside the bar)
and `test_ui_theme.gd` (both tab font items). GUI-local: no IPC method, CLI verb or MCP tool, no
plugin-supplied entries, no variable expansion, nothing at spawn (startup commands stay the `launch`
key). Docs: wiki `settings.md` and `keyboard-shortcuts.md`, the `AGENTS.md` autoload tree, and two
capture states (`commands` for the tab, `palette-commands` for the section) for the release
screenshot.

Commits: 9347f39, 4ad9a77, 0ef6d8c, 45cfed3

## GUI-51

**Discoverability: pane names, shortcuts and the window-mode control** - closed 2026-11-09: the Add
Pane grid stays glyph-only and names itself three ways instead. Its header names the tile under the
pointer (`Add a Terminal Pane`), falling back to the tile the keyboard cursor is on and reverting to
`Add Pane:` when both leave; the same header carries the section's **Help** button (tooltip and
accessible name `Help`, `Icons.QUESTION` U+E3E8), whose press opens an `AppDialog` table of **glyph
/ action / chord** for all eight pane types. The affordance is one generic module,
`godot/scenes/ui/section_help.gd` (`SectionHelp.attach(header, host, title, intro, rows_of)`), so
the workspace, profile and pane headers can adopt it without a second implementation; `host` is the
sidebar's unclipped background rect, and the rows provider is called at press time because a chord
only exists once the workspace has registered it. The window-mode dropdown reads `System Frame` /
`Borderless` / `Fullscreen` (it was `OS` / `Windowed` / `Windowless`), the label is unchanged in
`user://settings.json` because the stored value is the index, and both dropdowns (sidebar and
Settings → System) carry `Window Mode` as their accessible name and
`SettingsManager.WINDOW_MODE_HINT` as their tooltip: one sentence per mode saying what it draws.
Settings → About gained a **Keyboard Shortcuts** table grouped Workspace, New Panes, Panes, Keyboard
Focus and Terminal, rebuilt from `ShortcutManager.chord(action)` on every show (never literals),
with the new palette row `Keyboard Shortcuts` landing on that tab through the `shortcuts` dispatch
arm and `SettingsPanel.open_about()`. The bindings got one owner to make that possible:
`ShortcutManager.declare(action, bind)` binds an action with no workspace callback,
`term:search`/`term:copy`/`term:paste` are declared in `_ready()`, `TerminalPane` matches them with
`InputEvent.is_action(…, true)` instead of keycode+modifier tests (so a declared chord can never
become a workspace action and still costs the pane its key first), and the workspace's
`register(...)` block moved above `_build_sidebar()` - it used to run after it, so every chord the
sidebar printed was empty. The two hardcoded sidebar tooltips (`Ctrl+Shift+F`, `Ctrl+Shift+R`) are
registry reads now. Tests: `test_shortcut_catalog.gd` and `test_section_help.gd` (new),
`test_shortcut_manager.gd` (declared ≠ registered), `test_sidebar.gd` (heading hover/focus, Help
table), `test_settings_panel.gd` (`open_about` tab, registry spelling, rebuild not append,
caption/rows structure), `test_keyboard.gd` (each `term:*` event derived from
`ShortcutManager._parse_bind(chord(action))` still copies/pastes/searches), and
`test_discoverability.gd` (a real workspace: sidebar tooltips, Help chords, both window-mode
dropdowns, the palette row's About list). Screenshots ([captures](../v0.8.md#screenshots)): *Add
Pane, named*, *Add Pane help* and *Keyboard shortcuts*.

Commits: d17bac7, 0ef6d8c, e5b9cb0

## GUI-52

**Search, toasts and appearance swatches** - closed 2026-11-09: the search strip is one
`PanelContainer` (`UiTheme.RAISED_PANEL`: opaque `SURFACE_RAISED`, 1 px border, 4 px inset) anchored
to the pane's **top** edge - 6 px inset, 36 px tall, field `SIZE_EXPAND_FILL` - so it no longer
covers the prompt or the live rows; the two rows it does cover are the oldest visible output, and
the scrollback indicator moves to row 2.5 while it is open instead of drawing underneath. Its
right-hand end reads `n/m` (`SearchCount`: `0/m` before the first jump, `Invalid pattern` in
`DANGER_LABEL` with the engine's own sentence in the tooltip - the old `_search_error` was set and
never shown), and `SearchPrev`/`SearchNext` are `Icons.COLLAPSE`/`Icons.EXPAND` icon buttons
(`FOCUS_NONE`, tooltips naming the keys) that hand focus back to the field; Shift+Enter steps back
while Enter stays the LineEdit's submit. `_refresh_search_count` is the one derivation, called from
both search paths, both jumps, the scope toggle and the strip's open/close, and the History scope's
results panel hangs below the strip on the same surface. A toast is now a `PanelContainer` per
message, not a bare `Label`: `TOAST_PANEL`/`TOAST_WARN_PANEL`/`TOAST_ERROR_PANEL` give it an opaque
`SURFACE_RAISED` card with 6 px padding, and the level is a 3 px leading edge as well as the label's
ink, so severity never rests on colour alone; one 0.2 s fade-in replaces the pair that flashed alpha
1 for a frame, the text autowraps, and the message is both the accessible name and
`accessibility_live = LIVE_POLITE`. `ToastManager.info("%s spawned")`, `"Pane closed"` and
`"Swapped to …"` are deleted (with the dead `_add_body_to_grid` wrapper), and the rule - a toast
reports a result the user cannot otherwise see - is stated in `toast_manager.gd`'s header; the
refusals, clipboard copy, restore warnings and profile/workspace messages stay.
`godot/scenes/ui/color_swatch.gd` (`ColorSwatch.describe`/`label_text`/`tooltip`/`attach`/`sync`) is
the one owner of the swatch reading: Settings → Appearance now says `Focus (30%)` and
`Selection (40%)`, Pane Settings says `Cursor color (70%)` and `(unset)` for a fully transparent
colour a layout or profile carried in, and the tooltip names the checkerboard instead of leaving it
unexplained. Tests: `tests/unit/test_color_swatch.gd`, `tests/unit/test_toast_overlay.gd`,
`test_settings_panel.gd::test_swatch_label_follows_a_pick_and_the_reset` (plus the reworked
uniform-width test), and
`test_workspace_settings.gd::test_search_bar_is_a_compact_strip_at_the_pane_top`,
`::test_search_shows_the_match_count_and_steps_both_ways` (`0/m` → `1/m` → `m/m` →
`Invalid pattern`) and `::test_spawn_swap_and_close_do_not_toast` (the kept "Cannot close the last
workspace" refusal is its positive control). The `search` capture state stitches the strip over a
pane with three matches. Screenshot ([captures](../v0.8.md#screenshots)): *Search bar, fixed*.

Commits: d17bac7, eb79bc4, 9fab4cf

## GUI-53

**The history search results are mouse-only** - closed 2026-11-09: the History scope is
keyboard-operable end to end. `_rebuild_history_panel` builds each hit as a `FOCUS_ALL` toggle
Button with the palette's `SELECTED_ROW` treatment and an index-bound `pressed`, so
`_history_cursor` names the same row whether the keyboard walked to it, Tab focused it or it was
clicked; `Up`/`Down` from the field move that cursor (`KeyboardFocus.next_index`, clamped) and are
consumed by the strip - they used to reach `_handle_keyboard`, which sent an arrow sequence to the
child and snapped the view to the bottom; `Enter` in the History scope copies the cursor's line
through the one `_on_history_result_clicked(index)` path, so the toast always names the row the
cursor shows; `Escape` closes and returns the keyboard to the pane. The scope toggle is a tab stop
again and `_on_scope_toggled` hands the field the keyboard back, so the scope needs no pointer; the
two step buttons stay `FOCUS_NONE` and now declare their keyboard path
(`KeyboardFocus.declare_mouse_only`). `_clear_history_list` removes children before freeing them, so
a same-frame cursor move cannot count a row on its way out. Tests: five in `test_history_search.gd`
driven through `Input.parse_input_event` (rows are tab stops, the arrows move the cursor and stop at
the ends, Enter copies with a toast, Escape closes and restores focus, a focused row walks focus,
and the arrows never reach the child - pinned by the view offset, whose sentinel first waits for the
child to stop printing, because a scrolled-back pane anchors its view to late output;
`windows-smoke` measured the offset doubling from 44 to 88 when a line landed between the scroll and
the key), plus the new `search-history` capture state. Measured: `--audit-focus search` prints
`focus-none-buttons=2 declared=2 unaccounted=0`; `--audit-focus search-history` prints
`focus-none-buttons=0 unaccounted=0` - the two step buttons are hidden in the History scope
(`_refresh_search_count` shows them only for live matches), so the only buttons there are the
focusable result rows: `focusable=36` against the Live scope's 33.

Commits: 9fab4cf, d0c745b, ac5fd0a, c937afb

## GUI-54

**The sidebar offers a feedback path that opens a prefilled GitHub issue** - closed 2026-11-09:
**Feedback** is the fourth footer action, directly below **Close All** (`sidebar.gd`,
`_make_icon_text_button(Icons.FEEDBACK, "Feedback")`, U+E16C chat-circle-dots - a new glyph, because
the plugin-catalogue hint already owns arrow-square-out), and it opens
`https://github.com/godot-pty/gpty/issues/new?title=…&body=…` through an `open_external` Callable
seam (`OS.shell_open` by default). The text is one pure module, `godot/scenes/ui/feedback_text.gd`
(`FeedbackText`, statics, no scene tree): three prompts - what happened, what I expected, steps to
reproduce - then an "About this build" block carrying `GptyTerminal.get_app_version()`,
`OS.get_name()` + `OS.get_version()` and `SettingsManager.window_mode_label()` (the new getter that
reads the same `WINDOW_MODE_LABELS` table the dropdown fills from), and nothing else - `body()`
takes four strings, so no pane output, command, selection, path, environment value or log can reach
the form. Every field is control-character-folded onto one line and capped at 96 characters, so an
odd OS version cannot forge a block line; `MAX_URL = 8000` guards the URL (GitHub answers 414 past
its limit) and a body that would exceed it is cut by bisection with the build block kept whole and
`[truncated by gPTY]` appended. No `labels=`, `assignees=`, `template=` or `projects=`: the first
two are dropped for users without write access, and `template=` would route into a YAML issue form,
which ignores the generic `body=` parameter - and the repo's `bug_report.yml`/`feature_request.yml`
do exist (they prefill only their own field ids), so this row's "no issue templates exist today" is
corrected here instead of being kept. A failed `shell_open` (offline, headless, no handler) copies
the same text through the `copy_text` seam and raises a WARN toast, so the report is one paste away
and the app still submits nothing and holds no token. Tests:
`godot/tests/unit/test_feedback_text.gd` (the exact template, placeholder fields, newline folding,
URL parameter set, a 20 000-character field capped with the block intact, an over-cap trim with its
marker) and three `test_sidebar.gd` cases (the row sits directly below Close All with its own glyph,
the prefilled open asserted through the seam, a failed open → clipboard + WARN toast).
`--audit-accessibility sidebar` reports `unnamed=0` with the fourth row, and the
`window-chrome-borderless` capture shows it in place.

Commits: 02343a4, e66c020

## GUI-55

**A failed external link is silent at the app's other three link sites** - closed 2026-11-10: one
helper, `godot/scenes/ui/external_link.gd` (`ExternalLink`), is now the only path from an in-app URL
to the OS. `open(url, fallback_text, message, source)` returns `OS.shell_open`'s `Error`; on
anything but `OK` it copies the fallback text (the URL by default) and raises a WARN toast for 6 s
whose sentence names the URL - "Couldn't open a browser - copied <url>" - with the URL shortened to
120 characters for the one-line toast only (`shown`), while the clipboard always gets it whole.
`open_external`/`copy_text` are the replaceable seams, asked by `test_external_link.gd`'s four
cases: a reachable link opens once and copies nothing, a refused one copies the exact URL and warns,
a custom fallback/message/source replace the defaults (the Feedback row pastes a whole issue body,
not the URL), and a 400-character URL stays whole on the clipboard and under 200 characters in the
toast. The catalogue hint (`Sidebar._make_catalog_hint_row`), `MarkdownView._confirm_link`'s
confirmed branch and the Settings About tab all go through it; the About line is now a flat
`ACCENT_BUTTON` `Button` (`RepoUrl`, tooltip "Open the gPTY repository in your browser") instead of
a `Label`, and the feedback row's own `open_external`/`copy_text` pair moved out of `Sidebar` into
the helper, its wording and body unchanged. `test_sidebar.gd` injects `ERR_CANT_OPEN` and pins the
catalogue row's fallback: the URL is copied and one WARN toast names it. The file tree's own
file-opener seam was the last `OS.shell_open` site, closed by the row below.

Commits: e66c020, d6a67a7, 333f03a

## GUI-56

**A confirmed file open fails silently in the File Tree** - closed 2026-11-10: the system-handler
route is the last outbound sink to go through `ExternalLink`. `FileTreePane._confirm_open`
(`godot/scenes/panes/file_tree.gd`) still gates on an absolute path and still confirms with the
exact path in the body, then calls
`ExternalLink.open(uri, "", ExternalLink.refused_file_message(uri), "File Tree")` instead of the
pane's own `OS.shell_open` seam: a handler that refuses the `file://` URI now copies that exact URI
to the clipboard and raises one 6 s WARN toast reading "Couldn't open this file - copied <uri>" (the
toast's copy shortened to 120 characters, the clipboard's whole), where before the `Error` was
dropped by a seam typed to return nothing and the press looked dead. The pane's `open_external` seam
is deleted; the helper's own `open_external`/`copy_text` are the one seam, so the in-app
viewer/media route is asserted against the same recorder and still never reaches the helper or the
clipboard. Tests: `test_pane_file_sinks.gd` - `test_a_refused_system_open_copies_the_uri_and_warns`
(one WARN toast with source "File Tree" carrying the file sentence, the clipboard holding the whole
URI) and the three activation cases pinning `_opened`/`_copied` empty on the viewer and media
routes. `docs/content/docs/agents/gdscript.md` and `security.md` name the new path.

Commits: d6a67a7, 333f03a

## GUI-57

**The `working` badge is a thin arc that reads as a dim dot at 12 px** - found 2026-11-06 while
taking the release images: in the `agent-badges` state (`godot/tests/bench/ui_capture.gd`)
`completed` (a filled check circle), `failed` (X-circle) and `needs-attention` (warning triangle)
all read as solid silhouettes, while `working` is `Icons.SPINNER_GAP` (`terminal_pane.gd:708`) - one
thin arc of a ring - so the fourth state is the one a reader has to hunt for, in a surface whose
whole point is that the four are distinguishable. In `docs/static/images/v0.8.0_6.png` the arc's
stroke is mostly partial coverage (`#344B62`-`#6186BE` against the `#2E2E33` title bar, 1.50:1 to
3.64:1) although `ACCENT` itself (`#7fb4ff`) is 6.35:1 on that surface, so the defect is stroke
weight, not colour. Fixed 2026-11-10, both remedies at once: `working` is a filled silhouette *and*
the badge is raised to the icon-button floor. The badge is now its own control, `ui/agent_badge.gd`
(`AgentBadge`), which owns the state table, the tint role, the tooltip, the accessible name and its
own animation clock; `working` is painted rather than drawn - a 1.75 px band on a 6 px radius with a
1.75 rad notch that turns once per 0.9 s, so the notch carries the motion and the band is the
silhouette - while the other three states stay Phosphor glyphs, all four drawn at
`UiTokens.FS_HEADING` (16 px) in the `BUTTON_MIN_WIDTH` x `BUTTON_MIN_HEIGHT` box. `TerminalPane`
now only hands the badge a state (`_apply_badge` calls `AgentBadge.show_state`), and `BADGE_STATES`,
`BADGE_SPINNER_FRAMES`, `_animate_badge`, `_badge_label` and the
`SPINNER`/`SPINNER_GAP`/`CIRCLE_NOTCH` codepoints are deleted. Measured with the same projection on
the same four tiles of the same `agent-badges` state (1280x420): `working` went from 11.7 to 58.3
ink px, and at full opacity the four read 58.3 / 48.2 / 51.4 / 48.4 (working / completed / failed /
needs-attention) - a 21 % spread where the gap was 2.1-2.3x. The capture's `needs-attention` tile
measures 26.6 because that state pulses and the harness freezes it at its 0.55 alpha frame (the
pre-existing pulse; at full opacity it is 48.4). The 2 px band the mock used measured 67 px - bolder
than its siblings rather than equal - which is why the shipped stroke is 1.75. In greyscale the four
are a notched ring, a ring with a check, a ring with a cross and a triangle with an exclamation
point. Tests: `test_the_working_ring_is_a_closed_band_with_one_notch`,
`test_the_notch_advances_with_the_animation_phase`, `test_only_the_two_animated_states_tick` and
`test_a_state_names_itself_for_the_pointer_and_the_reader` (new,
`godot/tests/unit/test_agent_badge.gd`), plus `test_every_state_has_its_own_silhouette` and the
state-swap assertions in `godot/tests/integration/test_agent_badges.gd`; the harness stops the
badge's own clock, which `scripts/ui-capture-check agent-badges` proves by two pixel-identical runs.
Screenshot ([captures](../v0.8.md#screenshots)): *Agent-state badges, silhouette weight*.

Commits: ae22ac5, 6686ba4

## GUI-58

**The focus audit cannot see an open overlay's own mouse-only controls** - fixed 2026-11-09:
`_audit_focus` snapshots the open overlay's visible, enabled `FOCUS_NONE` buttons - text, tooltip,
declared reason and path, all as strings - before the Escape that closes it, reports each one as
`mouse-only button scope=overlay`, and only then closes and prints the escape result; the
workspace's own are collected after the close and deduped by path, so a control a failed Escape left
visible is not named twice. The summary splits the count:
`focus-none-buttons=N declared=M unaccounted=U`. `KeyboardFocus.declare_mouse_only(control, reason)`
+ `mouse_only_reason` are the declaration, the palette's rows and the search strip's step buttons
use it, and `docs/content/docs/agents/testing.md` states the contract. Measured:
`--audit-focus palette` names all 15 rows (8 pane types and 7 actions) before the Escape and still
reports `closed=true`, `declared=15 unaccounted=0` - the same state reported `focus-none-buttons=0`
before, because it counted after closing, which is also why this row's original "13 rows" figure was
stale.

Commits: 725f383, 8ececa3

## GUI-59

**The window's own titlebar controls are mouse-only** - fixed 2026-11-09:
`WindowChrome._make_titlebar_button` no longer sets `FOCUS_NONE`, and `build()` joins the three
controls into one explicit `KeyboardFocus.ring` after the bar enters the tree (`get_path_to` is
empty before that, which is why the call sits there). `Ctrl+Shift+A` (`app:focus_window_chrome`,
`Workspace._focus_window_chrome`) moves the keyboard in through `WindowChrome.focus_controls()`,
which answers false unless the bar is on screen and has a stop - so the chord is inert in
`System Frame` mode, where `apply_mode` leaves the bar hidden - and Escape goes one level out:
`_escape_window_chrome` recognises a focus owner under `titlebar` and hands the keyboard back
through `TerminalManager._return_focus_to_body`, matching the pane-chrome step and running after it
in `Workspace._input`'s ladder. Discoverability: the chord is in `ShortcutCatalog`'s Workspace group
and in the wiki's shortcut table. Evidence, all measured on this build: the new
`window-chrome-borderless` capture state (`settings: {cfg_window_mode: 1}`, applied before the scene
exists, so it is the real borderless window) takes the audit from
`focus-none-buttons=3 unaccounted=3` to `focus-none-buttons=0 unaccounted=0` and makes the ring
visible to it - `ring[1]=GlobalTitleBar/WinControls/Minimize, Maximize, Close`; the image shows the
bar with its three glyphs. Tests: `godot/tests/integration/test_window_chrome_keyboard.gd` - the
ring in both directions with no tree-order fallback, the chord entering at Minimize and Escape
returning to the active pane, the chord inert in the decorated mode, and Escape outside the bar not
swallowed (a terminal keeps the raw ESC byte). The row's own claims held: nothing else in it needed
correcting.

Commits: 8ececa3, c1d518e

## GUI-60

**The view panes' toolbars are mouse-only** - fixed 2026-11-09: the two toolbars are keyboard rings,
entered by `Ctrl+Shift+L` (`app:focus_pane_toolbar`) and left by Escape. The contract moved onto the
base class rather than being spelled per pane: `PaneBody._action_bar` (the pane's own row),
`focus_toolbar()` (first reachable stop, false when the bar is hidden or empty),
`toolbar_has_focus(owner)` (the scope test) and `leave_toolbar()` (one level out to
`keyboard_entry()`, and never back into the bar), so a third view pane joins by assigning one field.
`CodeViewerPane` rings Reload + view toggle from `_refresh_view` (a non-Markdown file hides the
toggle, which is then a one-stop bar) and aims `keyboard_entry()` at the text; `CliViewPane` rings
Restart + Stop from `_sync_buttons()` and aims at its output. `KeyboardFocus.ring` grew the
one-member case: a single stop keeps `FOCUS_ALL` and gets no `"."` self-path, and it clears the
paths a larger ring left behind - measured as a real defect, since `Tab` from a lone Restart still
walked onto the just-exited run's disabled Stop. A disabled button also stops being engine-reachable
at all (`focus_mode` follows `disabled` in `_sync_buttons`), because the engine's own traversal does
not skip one. The Wiki pane's note toolbar joins the same ladder: `_action_bar` is its `_toolbar`,
`_return_from_note_toolbar()` is deleted, its `_input` declines Escape when the owner is in the bar,
and `Workspace._escape_pane_toolbar` performs the step - `Ctrl+Shift+K` and its preconditions are
untouched. Correction folded in: this row said neither pane holds a text field - both hold a
read-only `CodeEdit` (a focusable stop, and it keeps Tab for indentation), so the defect was the
`FOCUS_NONE` flags, not a missing text field; the fix direction stood. Evidence, measured: the new
`code-viewer-content` state (a Markdown fixture written into the sandbox, since `TextRead` refuses
`res://`) and `cli-view-content` state (`/bin/sh -c "printf 'ready\n'"`, which exits at once so the
capture is repeatable) take both audits to `focus-none-buttons=0 unaccounted=0` from `unaccounted=2`
and `unaccounted=1` (the CLI state counted only Restart: Stop is disabled after the exit) and show
the rings to the audit - `ring[1]=…/Toolbar/ReloadButton, ViewToggle` and
`…/Header/RestartButton, StopButton`. Tests: `godot/tests/integration/test_view_toolbar_keyboard.gd`
(both rings and their wrap, the chord entering each and Escape returning to the editor, the chord
inert on an empty viewer, and the CLI ring following `disabled`),
`test_keyboard_focus.gd::test_a_one_member_ring_is_a_stop_without_a_wrap` +
`::test_shrinking_a_ring_clears_the_path_to_the_gone_member`, and the existing
`test_wiki_note_keyboard.gd` passes unmodified.

Commits: 8ececa3, c1d518e

## GUI-61

**The capture harness approves the plan the Workspace Trust state exists to have reviewed** - found
and fixed 2026-11-09 while running the full `ui-capture-check` sweep for *Discoverability: pane
names, shortcuts and the window-mode control*: `godot/tests/bench/ui_capture.gd` records every tile
a state seeds as approved (`TrustedStore.approve_builtin("ui-capture", …)`) so a state that needs a
non-default program for an unrelated reason (`pane-spawn-size` prints its own PTY size) does not
trip the restore gate. That block landed 2026-11-08 with the spawn-size row (commit `01d5859`) and
silenced a state that had existed since 2026-11-03 (commit `5778aeb`): `workspace-trust` *is* the
prompt, so `_show_multi_trust_dialog` never ran and the capture failed with "the untrusted tile did
not raise the Workspace Trust dialog" on every run - reproduced in a pristine `git archive HEAD`
checkout in a fresh sandbox, so the dialog had stopped being captured by any state. Fix: an
`approve_seeded_plans: false` flag on that one state, checked by the staging block; nothing else in
the harness changes. Evidence: `scripts/ui-capture workspace-trust` writes the dialog again
(Workspace Trust, the `/bin/sh` plan against `/bin/bash`, Restore and Cancel) and the full sweep has
no failure.

Commits: e5b9cb0

## GUI-62

**The close confirmation names the workspace and the pane, not just `T1`** - reported 2026-11-10:
with `lazygit` running in the `git` workspace's T1, closing the workspace asked "Closing will stop
processes still running in: T1" - the label alone names neither the workspace nor what T1 is. The
dialog was introduced in `b8bf5f9` with `pane_label`s only and the text has never changed
(`git log -S'Closing will stop processes'` finds that commit alone), so the recollection of an
earlier fix is the v0.7.0 row that added the confirmation itself. `_ask_running_then` now takes the
caller's action phrase and a qualification flag: a workspace-scoped action names the workspace in
the intro ("Closing the 'git' workspace will stop a running process in 1 of 2 panes:"), every other
action qualifies each line with its workspace ("'git': T1 (Terminal)"), and
`PaneBody.display_name()` supplies the user's own pane name or the type's name. The intro reports
busy panes against the panes the action destroys, with singular, all and count forms. Tests:
`test_running_ask_intro_counts_busy_panes_against_the_action_set`,
`test_running_ask_entries_name_the_pane_and_its_workspace`,
`test_closing_a_workspace_with_a_running_terminal_names_it`; `./scripts/gut-check` reports 101
scripts, 1214 tests, all passed, and `./scripts/ci-check` passes.

Commits: a5b2019

## GUI-63

**Workspace and pane close is explicit, and the last workspace can be closed** - the sidebar's
footer **Close All** is removed; **Workspaces:** and **Panes:** carry a trash that swaps to an
inline check/cross before the running-work walk, every workspace row carries a **More** menu (**Set
Directory**, whose tooltip is the current path, and **Clear Workspace**, which clears a hidden
workspace without switching), and workspace/pane close uses the trash glyph (the pane title bar
included). Closing the last workspace is legal: first run and "close all workspaces" land on zero
workspaces with the guide, and the first pane created there creates a **Default** workspace. Tests:
`test_sidebar` (row/title confirms, menu signal), `test_workspace_settings` (zero state, Default
spawn, close last, header close-alls, menu, hidden clear), `test_pane_close_guard` (clear asks),
`test_workspace_store` (zero round-trip); `scripts/ui-capture first-launch`/`empty-workspace` and
`scripts/accessibility-probe`.

Commits: 14cb04d

## GUI-64

**A workspace the user emptied restores a terminal on the next launch** - reported 2026-11-11 from
daily use: close every pane of a workspace, quit, relaunch - the workspace has a terminal again. The
save side is faithful (`_exit_tree` saves on quit, `workspace.gd:314-322`; `WorkspaceStore.save`
keeps `layout: []`, `workspace_store.gd:41-52`) and an empty workspace is a supported visible state
(`_apply_layout` shows `EmptyState`), so only the restore disagrees. Cause: `_restore_into` spawns
one terminal whenever the restored set is empty and the pane ceiling skipped nothing
(`workspace.gd:1417-1421`), a first-run rule applied to every empty layout - an empty store, a
legacy import and a layout the user emptied are indistinguishable there. Fixed 2026-11-11:
`_init_workspaces` derives `fresh` from an empty stored workspace set (a legacy import clears it)
and passes it through `_build_workspaces(entries, active, seed_first)` into
`_restore_into(ws, tiles, seed_terminal)`, where the seed now requires the flag; every other caller
(profile activation, the tests) keeps the default `false`, so a profile that restores nothing stops
inventing a terminal too. Tests: `test_an_empty_saved_layout_restores_no_panes` and
`test_a_junk_layout_restores_nothing_instead_of_inventing_a_pane` in `test_layout_restore.gd` (the
second replaces `test_restoring_nothing_usable_still_leaves_a_terminal`),
`test_a_workspace_the_store_kept_empty_stays_empty` in `test_workspace_settings.gd` (a store whose
workspace carries `layout: []`), and `test_pane_ceiling.gd`'s restored-workspace test now seeds a
real tile instead of leaning on the fallback. Verified 2026-11-11: `test_layout_restore` 21 tests,
`test_pane_ceiling` 8, `test_workspace_settings` 25, `test_startup_focus` 3, all green. Superseded
2026-11-11 by **Workspace and pane close is explicit, and the last workspace can be closed**: a
first run now has no workspace or pane, and the first pane creates **Default**; the empty-layout
rule stands.

Commits: 683d73d, 14cb04d

## GUI-65

**A spawned pane is not the active pane, and a close falls back to the wrong one** - reported
2026-11-11 from daily use: a workspace's first terminal does not take the keyboard until it is
clicked, and closing the newest of three panes activates the oldest instead of the middle one. Both
are the activation decision, not the focus plumbing: the sidebar's Add Pane is connected straight to
`_spawn_pane` (`workspace.gd:2019-2020`) and `_spawn_pane_into` never activates, so a fresh
workspace keeps `last_body == null` and the keyboard on the sidebar button; `_kill_now` scans
`ws.tm.tiles` forward and takes the first `TerminalPane` (`workspace.gd:621-647`), so T1,T2,T3 minus
T3 focuses T1 although the tiling logic's survivor is T2. Fixed 2026-11-11:
`_spawn_pane_into(..., activate := true)` is the one activation point and is gated on
`ws.tm == _tm`, so a restore or a spawn into a hidden workspace records nothing; the shortcut
closure, the palette's `new ` arm and `_request_pane_into` lost their hand-written `activate_pane`
calls, `newPane` passes its `focus` flag through, and `paneRun` passes `false`. `_kill_now` takes
`held_focus = ws.tm.last_body == body or _focus_owner_in(body)` and activates `_last_pane_body(ws)`
(reverse tile order, any pane type) before `_list()`. Tests:
`test_a_spawned_pane_is_the_active_pane` (the sidebar's `request_new_pane` signal leaves the new
pane as `last_body` and the viewport focus owner),
`test_killing_the_focused_pane_hands_focus_to_the_last_survivor` (T1,T2,T3 minus T3 leaves T2),
`test_closing_the_active_pane_records_a_read_only_last_pane` (active with no focus owner);
`test_wiki_note_keyboard` and `test_startup_focus`'s unvisited-workspace case now spawn with
`activate := false`, the restore route. Verified 2026-11-11: `test_workspace_settings` 25,
`test_startup_focus` 3, `test_wiki_note_keyboard` 4, `test_ipc_dispatch_contract` 31, and the
activation-sensitive files `test_palette`, `test_pane_open_request`, `test_overlay_focus`,
`test_pane_settings_panel`, `test_pane_close_guard`, `test_title_bar_keyboard`,
`test_agent_state_contract`, all green.

Commits: 683d73d

## GUI-66

**A workspace switch costs about a second on the daily-use set** - reported 2026-11-11 from daily
use (two workspaces - `omp` terminal + Reasoning, and `btop` in a terminal - window 2053x1382,
window mode 0, `max_fps` 165): every switch, especially into `btop`, takes about a second, while the
same set measured 63-75 ms of synchronous GDScript on 2026-11-09 (see **The sidebar rebuilds every
list on a workspace switch**). The first fix removed the switch-time settings re-apply
(`_on_settings_changed`) and the unconditional window-mode round trip, and the committed bench then
measured 36.6-37.4 ms - but the reporter still saw the second, so the bench was not covering the
expensive path. Re-measured 2026-11-11 against the reporter's own store, copied into
`scripts/ui-sandbox`, with `btop` running in both panes (windowed 2053x1382, `--disable-vsync`):
`_switch_workspace` 0->1 cost 992-1,020 ms and the first painted frame 1.5-1.6 s, while 1->0 cost
37-39 ms. The view steps account for 37 ms of that (workspace UI 16-17 ms, profiles 10 ms, `_list()`
11 ms, save 0.25 ms, layout/titlebars/status under 0.1 ms). The second is the focus path:
`TerminalPane._on_a11y_focus_entered` -> `_push_accessibility_value` -> `A11y.publish`, which
created a `Label` whose `text` was the whole screen - 221x78 = 17 315 characters cost 992 308 us in
that one call, against 3 362 us for the `omp` pane's 134-character screen. `Label` shapes and
measures its `text`; the name a driver reads comes from `Control.accessibility_name`
(`Control::_get_accessibility_name`) and `publish` already sets it, while the value `Label.text`
feeds does not reach AT-SPI on 4.7.2. Fix: `A11y.publish` no longer sets `node.text`, and the
slot-reuse check compares `accessibility_name` (against `text` it could never match, so the slot
would churn on every push). After: the 17 315-character publish is 53 us, 0->1 is 40.6 ms, 1->0 is
38.9 ms, and the first frame is 78 ms. `test_publish_carries_text_name_and_live_mode` and
`test_publish_replaces_the_slot` pin the name channel and the empty `text`.

Commits: 683d73d, aff5684

## GUI-67

**A dialog can grow past the window it opens in** - reported 2026-11-11 from daily use: the "Stop
running processes?" confirmation for a workspace whose panes are all running extends beyond the app
viewport, and "Close anyway" can end up below the bottom edge. `AppDialog` never clamps a modal: it
sets no `max_size` and every site centres with a bare `popup_centered()` (`workspace.gd:578` and 25
more), and the autowrap body `set_text` builds has no width floor (`app_dialog.gd:141-148`), so the
engine shapes it one word per line before the first layout and the card's minimum size is unbounded
in both axes - the running-work list (`RUNNING_ASK_MAX_NAMES = 8`, `workspace.gd:10`) is the app's
longest dialog text. Settings is the counter-example: an in-tree card at `UiTokens.MIN_LAYOUT`
(540x560) with a `ScrollContainer` per tab, so content can never grow it. Related: **Small windows
adapt instead of clipping**. Fixed 2026-11-11: `AppDialog.modal_limit`/`text_width`/`available_size`
are the pure maths (0.75 of the window less 24 px, floored at 240x160),
`AppDialog.popup(dialog, ratio)` sets `max_size` and centres with `popup_centered_clamped`,
`set_text` gives its autowrap label a width floor (it was shaped one word per line before its first
layout, which is what made the card tall) and `set_body` clamps its requested minimum; the hidden
engine label that carries `dialog_text` clips, so a long line there cannot set the card's width
again. All 25 modal sites migrated (`popup_centered()` -> `AppDialog.popup`; the cwd picker keeps
its 0.6 ratio). Tests: `test_app_dialog.gd` 18 green (limit maths, `max_size` at the limit, the
label floor, the clamped body, the clipped engine label) and a new `running-work` capture state at
800x500 over four busy panes, whose workspace-scoped card lists four names and sits wholly inside
the frame. Screenshot ([captures](../v0.8.md#screenshots)): *Stop running processes? at 800x500*.

Commits: 683d73d

## GUI-68

**Typing into a pane that is also streaming is throttled to 10 Hz by the flood back-off** - found
2026-11-11 from daily use (typing into the OMP pane in T1 while btop runs in T2), measured in a
sandbox on the v0.8.1 source at the reporter's shape (165 fps, two panes, 102x78 pane): a 60-line/s
coloured stream in the pane being typed into pegs `_sync_backoff` at 93.9 ms - the
`MAX_SYNC_INTERVAL` ceiling - so the grid is refreshed 2-3 times per 300 ms (7-10 Hz) and a
keystroke's echo arrives at the next refresh, key-to-next-grid-change p50 15 ms and max 114.8 ms;
btop's 18-39 ms repaints in the other pane drop the frame rate from 165 to 145-155 and widen that
tail. Cause: the budget check `_fetch_ms + _draw_ms > PANE_WORK_BUDGET_MS` runs once per sync with
no regard for the stretched cadence, so a pane whose fetch+draw is 8-10 ms keeps re-arming the
back-off although that is 9 % of a 100 ms window, and only view input (scroll, search) was exempt
(`user_driving` reads `_view_input_ms`), never typing - the pane the user types into was the one
being throttled. Fixed: `_note_view_input` zeroes `_sync_backoff` and both send helpers
(`_send_to_term`, `_send_line_to_term`) call it, so input reclaims the frame cadence for
`VIEW_INPUT_GRACE_MS` (500 ms). Verified in the same sandbox: back-off 0.0 in every phase, 14-19
grid refreshes per 300 ms (47-63 Hz), key-to-grid p50 14.2-14.3 ms and max 63-70 ms;
`test_typed_input_reclaims_the_frame_cadence` added to `test_flood_cadence.gd`.

Commits: da2fc47, 8dc74eb

## GUI-69

**Re-applying unchanged settings repacks the whole grid** - measured 2026-11-09 on the same run: the
incoming terminal's first `_process` after a switch reports `_fetch_ms` 5-6 ms with `is_full = true`
on the 145x78 `omp` pane, although it produced no output while hidden. Cause: `_switch_workspace`
calls `_on_settings_changed()`, which passes `color_scheme_path` into `apply_to_terminal` on every
broadcast; `PaneBody.apply_settings` sets every accepted key unconditionally, and
`TerminalPane.color_scheme_path`'s setter calls `_apply_stored_scheme()`, which with no scheme calls
`set_palette("")`; `set_palette` sets `palette_changed = true` and bumps the generation even when
the palette already is the system default (`crates/gpty-gdext/src/lib.rs:509-513`), and
`TermGrid::get_grid_updates` answers any `palette_changed` with `GridUpdate::Full`
(`crates/gpty-core/src/term.rs:386-392`), so all 11 310 cells are repacked into new arrays and the
pane's whole cell cache is replaced. Fix: return from the `color_scheme_path` setter when the value
is unchanged and make `set_palette` flag only a real change. Tests: re-applying identical settings
leaves `get_grid_generation()` unmoved, a changed scheme still repaints, and a settings save that
touches no pane setting leaves every generation alone. Fixed 2026-11-11 from the switch bench: the
`color_scheme_path`, `font_path` and `max_fps` setters return on an unchanged value, so the palette
bump, the font reload with its cell-metric recompute, and the double refresh-rate probe are skipped,
and the switch path no longer broadcasts settings at all - a settings save reaches every workspace
once (`test_a_settings_save_reaches_a_hidden_workspace`). `set_palette` itself was left alone: its
one caller reaches it only after the guard, so the Rust-side `palette_changed` change the row first
proposed was not needed. Measured on the same bench: the incoming `btop` pane's first frame after a
switch dropped from 18.6-18.7 ms to 6.4 ms, and its `_fetch_ms` from 7-9 to 1-2.

Commits: 4f1dc74, 683d73d, 8dc74eb

## GUI-70

**Opening Settings with a non-terminal first tile raises a script error and empties the Concepts section** - found
2026-11-13 from a crash report: `Workspace.get_terminal_for_ffi` walked every tile reading
`body._terminal`, which on a `ReasoningPane` is
`Invalid access to property or key '_terminal' on a base object of type 'Control (ReasoningPane)'`
(`workspace.gd:3256`); the function aborts, answers null, and `settings_panel.gd`'s
`_add_concept_section` then disables Add Concept and lists nothing even when a terminal sits in
another tile. Fix: the walk answers only a `TerminalPane`'s live backend
(`body is TerminalPane and body._terminal != null`). Tests: `test_workspace_concept_terminal.gd` (a
reasoning tile first and a terminal second must find the terminal; a workspace with no terminal
answers null without raising the error, which GUT would fail the test on).

Commits: 09c2da2

## GUI-71

**The workspace store drops the grid unit it is handed** - fixed 2026-11-12: `PaneTypes` now owns
the unit vocabulary - `GRID_LEGACY` (12) beside `GRID`, and `sanitize_grid_unit(raw)`, which returns
a declared unit only when it is one this build can scale and 0 ("unknown, infer") otherwise - and
the field round-trips both ways: `WorkspaceStore.save` writes it (absent in the dict = this build's
`PaneTypes.GRID`), `WorkspaceStore.load` reads it through `_as_int` (absent = unknown), and
`_init_workspaces`'s entry dicts carry it into `_build_workspaces`'s existing `scale_layout` call,
including through the trust dialog's approve/cancel paths. Tests:
`test_grid_unit_round_trips_and_unknown_units_are_dropped` (store) and
`test_a_store_written_in_a_coarser_unit_restores_the_same_shares` (integration; the tiles stop at
half the 12-unit grid so inference alone rescales them, verified by reverting the restore read - the
same tiles measure 510x389 px instead of 255x194.5).

Commits: 683d73d, 6422038

## GUI-72

**The engine rejects the accessible value writes, and every launch prints two errors** - fixed
2026-11-12: `A11y` no longer calls the server at the call site. `set_value`/`set_text` record
`VALUE_META` and, when a driver exists, queue the pair in `PENDING_VALUE_META`/`PENDING_ROLE_META`
and ask for `queue_accessibility_update()`; `A11y.apply_update(control)` is the only writer and runs
from the host's own `NOTIFICATION_ACCESSIBILITY_UPDATE` - `TerminalPane._notification` forwards it,
the only `PaneBody` that records a value. The engine side is why: 4.7.2 refuses
`update_set_role`/`update_set_value` unless `in_accessibility_update` is set
(`drivers/accesskit/accessibility_server_accesskit.cpp:746`, `:834`), and that flag is true only
inside `_accessibility_build_tree_update`'s `update_cb` (`:649-653`) ->
`SceneTree::_process_accessibility_changes` ->
`node->notification(NOTIFICATION_ACCESSIBILITY_UPDATE)` (`scene/main/scene_tree.cpp:263`). Verified:
a rebuilt export launched with `--accessibility always --accessibility-driver accesskit --verbose`
logs `AccessKit driver loaded` + `adapter created` and **zero** refusal lines (no `ERROR` line at
all; the v0.8.1 build printed two per launch). Tests:
`test_set_value_records_the_value_without_a_driver` (headless queues nothing),
`test_apply_update_consumes_a_queued_value_once`,
`test_a_terminal_forwards_its_accessibility_update`. `scripts/accessibility-probe` now fails a run
whose app log carries the refusal, before its tree walk so another assertion cannot mask it - proven
by re-introducing the illegal call, rebuilding, and watching the probe print it and exit 1. The
value still does not reach AT-SPI on 4.7.2 (the adapter maps neither value nor role); the Future row
**Re-test the AT-SPI element-value mapping when an engine release carries it** now says the call
side is fixed, so that re-test grades the mapping.

Commits: da2fc47, 6422038

## GUI-73

**A pane cannot be moved to another workspace without closing it** - shipped 2026-11-13 (CI run
43453896318 green). Workspaces are live parallel grids (`_workspaces`, `workspace.gd`), so a move is
a reparent: the PTY, scrollback and pane env are keyed by `attachment_id` (all
workspace-independent) and `_resolve_pane_target` already addresses panes across workspaces, so
nothing is re-keyed. Blocker found in the feasibility pass: `reparent` fires `_exit_tree`, which
`cli_view`, `media` and `inspector` treat as close (`_cli.stop`, `_stop_backend`, `_close_session`),
so a naive move kills the backend; `PaneBody.backend_preserved` guards it. Policy A moves a terminal
with its follow set (`source_attachment_id` in its own workspace, today Reasoning only); a follower
moved alone is warned that it will observe nothing; the Inspector has no follow link and moves only
when named, warned when `auto_run` starts answering the target workspace's captures. Also fixes, all
found in the same pass: the three `ws`-capturing closures in
`_attach_pane_into`/`_wire_pane_activation` (a moved terminal's badge freezes because
`_agent_state_primed` still matches, a moved file-tree pane spawns into the old workspace, and a
stale `last_body` lets "close active" close a pane in another workspace); `pane_label` collisions on
adopt, which make label-addressed IPC permanently ambiguous; and atomicity (capacity is planned
before anything detaches, so a refusal mutates nothing). Fix:
`TerminalManager.detach/plan_adopt/adopt` (reusing `kill`'s rect absorption and `_split_for`),
`Workspace._move_panes_into`, the pane-menu submenu, `movePane` + `workspaceList` IPC, `move-pane` +
`workspace-list` CLI/MCP tools. Tests: 9 in `test_workspace_pane_move.gd` (same pane instances and
ids, PTY session and child alive, rects tile the grid exactly, a full-grid refusal mutates nothing,
label unique, the active pane stays, `request_pane` lands in the target, the badge resumes, the move
notes), 3 IPC contract tests, and the pane-menu submenu test. Measured live: the moved PTY kept pid
660430 and its scrollback marker, W1 0 / W2 3 panes after the move and 2/1 after the move back, and
`workspaces.json` round-tripped the membership.

Commits: ea6bc15, dd16d6d

## GUI-74

**A restored terminal publishes no text to the AT-SPI tree** - fixed 2026-11-13, and the row was two
defects. (1) *The push was starved*: `_a11y_tick` gated `_push_accessibility_value` on a settle
window keyed to the grid's damage counter, so a pane whose generation moved faster than
`A11Y_SETTLE_MS` never pushed - a GUT tick right after `echo A11Y_MARKER` published nothing, and the
export trace (`enabled=true`) showed the value pushed twice at start-up with an empty screen and
never again. The value now follows the screen text, limited only by `A11Y_PUSH_MS`; the settle
window delays the one-line announcement alone, and the publish host is re-resolved per push so a
rebuilt tile cannot leave a body pointing at a freed bar. (2) *The published node's name was empty*:
a `Label`'s AT-SPI name is its display text, not `accessibility_name` (proved by publishing a
literal label text - the tree showed that literal), so the content node arrived unnamed; a bare
`Control` is dropped from the tree entirely (container role). New `A11yContent`
(`godot/scenes/ui/a11y_content.gd`) is a `Control` that writes the role `A11y.set_text` queues from
its own update notification, so the node carries role 79 and the whole screen in its name with no
text shaping (the 992 ms cost of 2026-11-11). Tests:
`test_a_restored_terminal_publishes_its_screen_on_its_own_host` (the body's own `_a11y_host`, the
node's name, `VALUE_META`), `test_a_churning_grid_still_publishes_the_value`,
`test_the_value_push_is_rate_limited`, `test_the_announcement_waits_for_a_quiet_grid`, and
`test_publish_carries_text_name_and_live_mode` now pins that the node is not a Label; the gate is
reachable headless through the new `A11y.force_enabled` seam. `scripts/accessibility-probe` also
stops asserting a marker it never typed: it resolves a CLI (`GPTY_CLI`, else `gpty`, else
`target/release/gpty`), exits 3 without one, and prints its first non-empty `Text` answers. Verified
end to end: `./scripts/accessibility-probe` exits 0 and the marker appears in the name dump as
`[neilp@cachyos-x8664 ~]$ echo A11Y_PROBE_MARKER \| A11Y_PROBE_MARKER \| ...`.

Commits: d56e815, 6422038, 09c2da2

## GUI-75

**A streaming pane nobody is typing into still refreshes at 10 Hz** - cadence half fixed 2026-11-13;
the paint half is split out as **A terminal repaint rebuilds the whole canvas when one row changed**
(next row). The budget is now a share of the wall clock,
`PANE_WORK_BUDGET_MS * (_sync_interval + _sync_backoff) / _sync_interval` - a quarter of a 60 Hz
frame, ~24 % at any cadence - so a sync over its share stretches the cadence and one under it calls
the new `_relax_sync_backoff()`, which is the half the old code lacked: a streaming child has damage
every sync, so the found-nothing-new branch that used to relax the cadence never ran and the pane
parked at `MAX_SYNC_INTERVAL`. User input still resets it (`_note_view_input`). Measured with
`BENCH_FLOOD=1 draw_bench --max-fps 60` on the row's own grid, 3 reps per side at 102x78 and 2 at
120x60: 102x78 went 10.5-13.3 syncs/s with `_sync_backoff` pegged at 83.3 ms to 33.5-39.5 syncs/s at
`backoff_ms=0.0`; 120x60 went 16.5-23.2 to 34.6-39.5. `draw_bench` gained
`syncs`/`sync_hz`/`backoff_ms` (its `gen_changes` counts grid damage, not the pane's syncs) and both
its header and the flood helper now say `--max-fps 60` is required for a cadence question -
unthrottled, the loop outruns the back-off and every frame syncs, which measures cost but not rate.
Tests: `test_a_sync_that_fits_the_stretched_window_relaxes_the_cadence` and
`test_the_same_cost_still_stretches_at_the_frame_cadence` pin both directions with the same 9 ms
cost; `test_backoff_never_exceeds_the_cadence_ceiling` now uses a cost above the ceiling's own
scaled budget (40 ms) because a 24 ms sync legitimately fits a 100 ms window; the probe helper is
`_run_sync_with_draw_cost`. Gate: 1333 GUT tests pass.

Commits: da2fc47, e54cc6f

## GUI-76

**A terminal repaint rebuilds the whole canvas when one row changed** - fixed 2026-11-13:
`TerminalPane`'s paint is split across child CanvasItems - one background band and one text band per
row (a `Layer` Node2D, drawn in the order the two passes used), then an overlay for the focus
border, cursor, scrollback indicator, selection and search highlights. A partial grid update queues
only the rows its damage covers (`_painted_rows`, ascending); a full update queues everything; a
cursor blink, a selection change and a search change now queue the overlay alone. The bands keep an
identity transform and draw at the grid's absolute pen positions: the text server picks the glyph
raster from the position argument, not from the composed item transform, so a per-band `position`
repainted every glyph with a different antialiasing (73 357 differing pixels in the bench PNG).
`_draw_ms` is now a float sum of the bands a frame drew, so the cadence budget reads a one-row
update as one row. Measured on the release gdext (`draw_bench`, 2026-11-13): a full repaint 2976 →
2834 µs at 102x78 and 2913 → 2630 µs at 120x60 (idle 241/264 µs), one row 60 µs and 32 µs over idle,
a cursor blink 0-3 µs; `BENCH_SPARSE=1 --max-fps 60` (one line per 0.2 s) 2286 → 190 µs per damage
sync at 102x78 and 2286 → 120 µs at 120x60, `avg_rows` 2, `backoff_ms` 0; `BENCH_FLOOD=1` still
repaints every row (`avg_rows` 78/60) at 3262 → 2957 µs and 2646 → 2434 µs. The render is
pixel-identical: `ui-capture --compare` reports identical PNGs for the `draw_bench` pair at both
grids and for the staged `workspace-1280x760`, `search` and `scrollback-return` captures (the search
capture is what caught the band-order bug below). Tests: `test_terminal_repaint.gd` - a full repaint
lays one background and one text band per row at the origin (a band transform is the antialiasing
bug), a smaller grid frees the extra bands and keeps the overlay above them, a partial update queues
only its damaged rows, and a typed line in a real shell repaints at most 4 of ≥ 10 rows and covers
every row whose text changed, with every band below the search strip. The end-to-end assertion first
read "the repainted rows are the cursor's", which Windows CI turned red on 2026-11-13: ConPTY
rewrites the rows it relays, so one typed line damaged rows 0, 3, 4 and 6 with the cursor on row 6,
so the test asserts the platform-neutral direction (text changed ⇒ repainted) and `pitfalls.md`
carries the trap. Both paint traps are recorded in `pitfalls.md`; the ordering one is the reason a
real-pane test exists at all - a synthetic probe (no strip) passed with the bands in the wrong
order, and only the `search` capture diff showed the grid painting over the strip's panel, because
moving the background band and its text band in one interleaved `move_child` pass leaves every text
band *after* the strip whenever the strip sits between the two groups.

Commits: e54cc6f, 9c3e5c9, 5db52d0

## GUI-77

**Small windows adapt instead of clipping** - fixed 2026-11-13 (build 0.8.3). The Settings and Pane
Settings cards clamp to the window instead of keeping a fixed size: `OverlayPanel.fit_card` sets
`custom_minimum_size` to `min(design, host - 2*edge)`, shared with the command palette (which
already did this inline), so the 540×560 card is 540×484 at 800×500 - inside the window, where it
used to be centred at y=-30 with 60 px past the bottom - and 540×324 at 560×340 where it was clipped
at (10, -110); the height is what clamps first - the 540 px design width fits a 560 px window - and
every tab was already a `ScrollContainer`, so a shorter card scrolls its content. A pane title stops
at the button column (`TitleLabel` inset 30 px from the left, clearing the agent badge, and 76 px
from the right against the 74 px button reserve) and ellipsizes with `OVERRUN_TRIM_ELLIPSIS`, the
full title on its tooltip; both `title_changed` handlers write through the new
`TerminalManager.set_title_label`. The sidebar scrolls as one column (`SidebarScroll` between the
margin and `SidebarContent`) and its pane list takes the five-row cap `SECTION_MAX_VISIBLE_ROWS`
already claimed for all three lists, so the stack overflows the 488 px content area of an 800×500
window and every row is reachable by scrolling instead of the list being squeezed into the 33 px the
fixed blocks above it left; `Sidebar.WIDTH`/`COLLAPSED_WIDTH` replace the `180`/`20` literals in the
workspace and in the fold. `UiTokens.MIN_LAYOUT` drops from 540×560 to 560×340 - the smallest layout
this row asserts, and the size at which the card still keeps all seven tabs - so
`UiTokens.ui_scale_ceiling(Vector2i(800, 500))` is 142 % where it was 89 %: a 125 % request in an
800×500 window is honoured instead of forced to 100 %, and the cap now only refuses a scale that
would squeeze the layout below the floor. Tests: `test_small_window.gd` (the Settings card at
800×500 and 560×340 and its re-clamp on a resize while open, the Pane Settings card at 560×340, a
title's right edge at or before its buttons' left edge with a title measured wider than the label,
and the sidebar's last pane row reachable after scrolling, with the pane list still filling a tall
window) plus the re-pinned floor in `test_ui_scale.gd`, `test_settings_panel.gd` and
`test_workspace_settings.gd`. Screenshots ([captures](../v0.8.md#screenshots)): *Small window,
800×500* and *Small window, Settings*.

Commits: d17bac7, 6cecfd6, eb79bc4, 611b8f0, f3d2893

## GUI-78

**Resizing a pane is smooth: the resize cursor always shows, no gray band while dragging, no hop on release** - fixed
2026-11-13, four defects in one row, all reproduced on the 0.8.2 build. (1) *The cursor recovers.*
`TileDrag.drive_edge_drag` ends the drag on the left release and now returns false for it, so
`Workspace._input` no longer consumes the release of the press the grab band took and the viewport
sees its matching release; the drag publishes `divider_drag_started(axis)`/`divider_drag_finished`,
and the workspace answers with `Input.set_default_cursor_shape` (HSIZE/VSIZE for the axis, ARROW
after) because the pointer leaves the handle on the first motion. (2) *No grey band.* A terminal now
fills itself with the grid's own background - `palette[0]`, which `NamedColor::Background` resolves
every cell's background to - read back through the new `GptyTerminal.get_background_color()`,
instead of a per-pane `default_bg` no cell ever painted; `default_bg` is now the terminal's
background (`set_background_color` writes `palette[0]` and forces the full repack that re-resolves
every cell, default black, and a scheme's first colour wins while one is set). The grid also follows
the divider: `_on_resize` stops restarting its 50 ms quiet period while a drag is in flight, and
`TerminalPane.set_drag_resizing` turns it into a 10 Hz throttle (`RESIZE_DRAG_INTERVAL`) plus one
final reflow on release - measured mid-drag, the grown pane went 59 to 63 columns with the button
still down. (3) *No hop.* `_preview_edge_drag` rounds the pointer travel to whole grid units before
moving anything, the same integer `_commit_edge_drag` applies: a 40 px drag on a 17 px unit previews
and commits 34 px. (4) *One handle per divider line.* The four 6 px strips per pane are gone
(`EDGE_STRIP`, `EdgeHost`, `_make_edge_strip`, `_sync_edge_strips`):
`godot/scenes/terminal/divider_handles.gd` (`DividerHandles`) puts one 12 px band per divider
segment - exactly the stretch where a tile ends on the line and another starts on it, so a spanning
pane never has a handle over its own content - inside the workspace grid, topmost, with a 2 px
ACCENT highlight on hover; the old pair of strips left the two 1 px wrapper borders dead inside a 14
px target, and a divider with no travel (one pane, or both sides at `MIN_TILE`) shows an arrow and
starts nothing. Drags are started by line (`TileDrag.begin_line_drag`/`line_limits`,
`_tiles_on_divider` reading the live model before a press). Tests: `test_divider_handles.gd`
(segment geometry: side-by-side, the Agent Workspace L, 2x2, a spanning tile, band rects) and
`test_pane_edge_drag.gd` rewritten (one band per line and its cursor, no band for a single or
immovable divider, GUI picking, preview == commit, the release not consumed, absolute backtracking,
the `MIN_TILE` clamp, one line moving every tile, and the mid-drag reflow plus the final one);
`test_the_ground_is_the_grid_background` in `test_terminal_repaint.gd` pins
`ground_color() == get_background_color()` across a `default_bg` change and a scheme. Screenshot
([captures](../v0.8.md#screenshots)): *Divider handle* and *Resize drag*.

Commits: 66b99a3, 6cecfd6, 7178999

## GUI-79

**The sidebar's three sections cannot be folded** - fixed 2026-11-13 (build 0.8.3); requested from
daily use, measured 2026-11-05 on the 0.8.0 development build: `sidebar.gd` builds Workspaces
(`_add_workspace_section`), Profiles (`_add_profile_section`) and Panes (`_add_pane_list_ui`) as
permanently open sections, and each reserves vertical space the user cannot give back - the
workspace and profile lists grow to `SECTION_MAX_VISIBLE_ROWS` (5) measured rows through
`_measured_section_height`, and the pane list takes every remaining pixel
(`size_flags_vertical = SIZE_EXPAND_FILL`); the only fold in the app is the whole 180 px sidebar
(`_toggle_sidebar`, `Ctrl+Shift+B`). Panes is also the one section with no header row: a bare
`Label` whose text carries a leading space (" Panes:", against "Workspaces:" and "Profiles:"),
hidden while the list is empty, holding no button. At 800x500 the pane list is already cut after one
row - the state *Small windows adapt instead of clipping* measures - so folding the two lists the
user is not switching right now is what buys that space back, and the pane list's `SIZE_EXPAND_FILL`
gives the freed height to it with no layout code. Fix: one header builder for all three sections -
the heading label (`SIZE_EXPAND_FILL`), the section's existing add button where it has one
(`AddWorkspaceBtn`, `SaveProfileBtn`), then the fold toggle as the header's right-most control,
which leaves Panes with the toggle alone; `Icons.style_button`, `focus_mode = FOCUS_ALL` (the v0.8.0
keyboard pass made every sidebar control a tab stop) and a `tooltip_text` naming the section and the
direction. The label's glyph becomes the state: caret-down while open, caret-up while folded; the
set has only caret-left/right (`Icons.COLLAPSE` `E138`, `Icons.EXPAND` `E13A`, what the
whole-sidebar arrow draws), so add caret-down `E136` and caret-up `E13C` - resolved by rendering the
bundled Phosphor font, where `E136` is 704 units wide at the top of its box and 46 at the bottom and
`E13C` the reverse. Folding hides the section's `ScrollContainer`, which container sorting then
skips - measured on 4.7.2, laid out over frames: a `VBoxContainer` of heading, `ScrollContainer`
(`custom_minimum_size.y = 150`) and a following label reports a 216 px combined minimum and places
that label at y=187, and 62 px / y=33 with the scroll container hidden, back to 216 / 187 when it is
shown again; the `ScrollContainer` reserves nothing of its own even holding five 30 px rows (a 66 px
minimum with it shown against 62 hidden - the 4 px separation), so `_measured_section_height` is the
only thing reserving list space and the refresh that runs it (`update_workspace_list` /
`update_profile_list` / `update_pane_list`) cannot re-open a folded section. The header row inherits
`_pane_heading`'s empty-list visibility rule, so a Pane section with no tiles still shows no
heading. Fold state persists per section in `user://settings.json` (a closed `sidebar_folded` list
of the three section ids, `SettingsManager`), so a user who folds Profiles to reach Panes keeps it
across launches; the whole-sidebar collapse stays non-persisted, which
`docs/content/wiki/gpty/sidebar.md` documents. The engine `FoldableContainer` already folds the
Reasoning pane's turns, but it owns its own header row and toggle, which is not the placement
requested here. Docs: that page's "Shape and collapse" section. Tests:
`godot/tests/integration/test_sidebar.gd` - a fold hides the list and drops the section's combined
minimum to the header, an update while folded does not re-open it, the glyph and tooltip swap, and
only a registered section id is accepted from the settings key. Shipped 2026-11-13 (build 0.8.3):
each section is one header row plus its list, built by `Sidebar._add_section_header` (heading label,
the section's own controls in order, then the fold toggle right-most), so the Panes section gains a
header row and stops being a bare " Panes:" label; the caret is `Icons.CARET_DOWN` while open and
`CARET_UP` while folded, and the tooltip and accessible name carry the verb and the section
(`Fold the Profiles section` / `Show the Profiles section`). The state is
`SettingsManager.cfg_sidebar_folded`, a `sidebar_folded` list in `user://settings.json` reduced on
load to `SIDEBAR_SECTIONS` ids in registry order and written by `set_sidebar_folded` without the
`settings_changed` broadcast, because nothing a pane draws reads a fold and that broadcast
re-applies terminal settings to every pane; the whole-sidebar collapse still is not saved. A list
refresh never touches the fold, and the Panes host gives up its `SIZE_EXPAND_FILL` while folded so a
closed section does not hold an empty band open. Docs: `docs/content/wiki/gpty/sidebar.md` ("Shape
and collapse") and the sidebar bullet in `docs/content/docs/agents/gdscript.md`. Implemented tests:
`test_sidebar.gd` (43/43) and `test_settings_manager.gd` (17/17), plus the `sidebar-folded` capture
state. Screenshot ([captures](../v0.8.md#screenshots)): *Foldable sidebar sections*.

Commits: b4703be, c40f333

## GUI-80

**Creating a pane gets slower as the window fills** - fixed 2026-11-14 (build 0.8.3). The growth was
the sidebar, not the tiling: `Sidebar._render_panes` cleared and rebuilt every row on any pane-list
change, at the recorded 7-10.4 ms per row (five Phosphor glyph Labels), so a spawn at 64 panes
rebuilt 64 rows it already had. `_sync_pane_rows` mutates the list in place from `_pane_rows` (body
instance id -> row): a closed row is detached in the same call (not queued), a spawn builds only its
own row, a renumbered label is rewritten on its row, and a row's actions swap for its check/cross in
place (`_apply_row_pending`), so the close-confirm paths do not rebuild either. The create path also
stopped paying a whole-window title-bar sweep (the new bar already follows `cfg_show_titlebar`) and
now defers `DividerHandles.refresh()` one idle (`_apply_layout(false)` plus
`_queue_divider_refresh`), whose O(grid x tiles) scan was 5.1 ms at 64 panes. The check the row
asked for is committed: `godot/tests/bench/spawn_bench.gd` (POSIX, needs a display; per-spawn
`sync_us`, child-resolved `total_us`, RSS, child count, and per-pass marks at 1/8/16/32/48/64
panes). Measured 2026-11-14, 1920x1080 windowed X11, debug build, 64 panes: `sync_us` 35 382 -> 34
747 at pane 1 and 761 655 -> 25 016 at pane 64, slope +11 528 -> -154 us per live pane, `total_us`
810 825 -> 51 435, RSS 1198-1235 -> 1192-1211 MiB, children 64 against 64 tiles. Tests:
`test_a_spawn_adds_one_row_and_keeps_the_attached_ones`,
`test_a_closed_pane_row_leaves_in_the_same_call`, `test_a_renumbered_pane_rewrites_its_row_label`,
`test_a_close_confirm_swaps_only_its_rows_actions`.

Commits: 3823302, 6cecfd6, 4f1dc74, 6def169

## GUI-81

**The sidebar rebuilds every list on a workspace switch, 62 of 74 ms** - fixed 2026-11-13 (build
0.8.3); measured 2026-11-09 on the 0.8.1 development build (a windowed X11 run of the reporting
user's own workspace set: `omp` = terminal + Reasoning, `git` = lazygit, plus `kb`, `omp2`, `work`):
`_switch_workspace` spends 63-75 ms of synchronous GDScript, and the breakdown is
`_update_workspace_ui` 34.5-36 ms (5 workspace rows), `_refresh_profile_buttons` 17 ms (2 built-in
profiles + the catalog hint) and `_list()` 10.2-10.8 ms (1-2 pane rows), against
`_save_workspaces_to_store` 0.3 ms, `_apply_layout` 0.02 ms, `_apply_ui_colors` 0.04 ms and the
settings re-apply to the incoming panes 0.1 ms - the panes are not the cost. The cost is control
creation: building a row is 0.09 ms, but each Phosphor glyph Label costs 3.3-3.5 ms to enter the
tree (an ASCII Label with the same font override costs 0.09 ms, and putting the glyph in
`Button.text` - the pre-v0.8.0 shape - costs the same 3.4 ms, so the a11y child Label did not
introduce it), and every row carries 1-3 of them: a workspace row (cwd + close) 7 ms, a profile row
7 ms, a pane row (settings/menu/close) 10.4 ms. Switching to the `omp` workspace costs 74-75 ms
against 63-65 ms for the single-pane ones, which is its extra Reasoning row. The first switch after
launch measured 551 ms once (unexplained outlier; every later switch 63-75 ms). Not newly
introduced: the path has rebuilt the lists since workspaces landed (`124d432`, v0.5,
`_ws_tabs.update` + `_list()`), and the cost grew with each control a row gained (the workspace cwd
button, `aae08f0` 2026-10-21; the profile catalog hint and new-workspace glyph; the pane action
glyphs). Fix: do not rebuild a list that did not change - keep the rows, compare a content
signature, and move only the state (`_apply_row_accent` for a row, `Sidebar.set_active_pane` already
does it for panes), and reuse a row's glyph Label instead of freeing it (re-assigning `Label.text`
on an attached Label measured 0.00 ms). Tests: a switch with unchanged lists allocates no rows and
its accents still follow the active workspace; a switch after a spawn or close still shows the new
pane set. Shipped 2026-11-13 (build 0.8.3): the three `update_*_list` entry points compare
`_workspace_signature`/`_profile_signature`/`_pane_signature` (one string per row, fields joined
with U+001F) and, when it matches and no close question is open, call `_apply_*_state` - the active
accent and the section header - with nothing built or freed; a changed model still rebuilds, and the
first draw is forced by `_ws_drawn`/`_profile_drawn`/`_pane_drawn` because an empty model matches an
empty signature. Measured with `godot/tests/bench/switch_bench.gd` (two restored workspaces, 5 reps,
defaults, 2053x1382): median 0->1 sync_us 43210 -> 12338 and median 1->0 43311 -> 12309, a 71 % cut
on the same machine in the same session - the Workspaces and Profiles halves of the switch no longer
create a control, and the remaining 12 ms is the incoming Pane list's own rows plus `activate_pane`.
That pane half of the signature was replaced in v0.8.3 by the in-place `_sync_pane_rows` (**Creating
a pane gets slower as the window fills**), so a switch with an unchanged pane set now touches no row
either. The 551 ms first-switch outlier is its own row now (**The first workspace switch after
launch takes 551 ms**).

Commits: 4f1dc74, c40f333, 6def169

## GUI-82

**The workspace-switch bench never fills the incoming pane, so it misses focus-time work** - fixed
2026-11-13: the warm-up now settles each workspace's pane while it is on screen (`_settle_pane`:
non-empty `visible_text()`, its grid quiet for 8 frames, or filled for 1.5 s when the payload never
goes quiet, 20 s deadline), and the measured loop starts from the same workspace afterwards. Every
`_switch` records the incoming pane's character count, each rep prints `chars=`, and a switch into
an empty pane fails the run - with one exception, the warm-up's first arrival, which is the one
switch that may land before the pane has painted (`require_screen=false`). The bench also forces
`A11y.force_enabled = 1`: the focus-time half only runs with the app's a11y gate open, and a
developer session usually has no screen reader, so the bench would measure a switch with that work
switched off (`switch_bench: seeded (a11y forced on)`). The default `QUIET` payload gained
`echo quiet` so it has a screen to arrive at. Measured 2026-11-13 at 1900x1000, 3 reps,
`DISPLAY=:0`: both panes settle (`chars=2429` for the flood payload, `5` for the quiet one), every
rep prints a non-zero `chars=` (2429 / 5), `sync_us` 42.4-46.6 ms for `_switch_workspace` and
`frame_us` 4.5-5.5 ms - against the 36.6-37.4 ms the empty-pane bench reported. The ~1 s the
reporter saw does not reproduce on this build and is not what is left to measure: its two halves are
closed elsewhere in v0.8.3 - the 992 ms was the old Label-based `A11y.publish` shaping the whole
screen (**A restored terminal publishes no text to the AT-SPI tree**), and the residual synchronous
switch cost is the sidebar rebuild (**The sidebar rebuilds every list on a workspace switch**).
`SWITCH_CMD_B=btop` settles at only 24 characters in the sandbox (btop does not reach a full screen
there), so the recorded numbers use the bench's own QUIET/FLOOD pair.

Commits: aea2b85, 9c3e5c9

## GUI-83

**The switch bench's `draw_ms` readout is always 0** - fixed 2026-11-14. `_switch` baselines the
incoming pane's own sync counter (`_last_grid_gen`, which stands still while the pane is hidden)
before the switch and waits, bounded to `SYNC_WAIT_MAX_FRAMES` (120 frames, longer than the flood's
0.4 s interval), for the frame it moves: `first_sync_frame` (1-based; 0 means the pane needed no
sync in the window), `first_sync_us` (wall time from the switch) and
`fetch_ms`/`draw_ms`/`sync_work_ms` read at that frame, per direction, with a median
`first_sync_us`. Measured 2026-11-14 (2053x1382, quiet in A and the flood in B, 5 reps): the flood
direction reports `first_sync_frame` 1-2, `first_sync_us` 32.9-43.5 ms, `draw_ms` 5.28-7.92 and
`sync_work_ms` 13.3-17.9 (was `draw_ms=0.00` on every rep), while the quiet direction reports
`first_sync_frame=0` with `draw_ms=0.00` - a stated fact (nothing to repaint) instead of the old
silent zero.

Commits: d83df54, 6def169

## GUI-84

**The toast queue never queues** - fixed 2026-11-14: `_enqueue` no longer dismisses the visible
toast. It appends and returns while one is up, the toast's own tween callback starts the next, and
the queue is bounded at `MAX_QUEUE` = 8 (oldest dropped, newest kept) so a caller in a loop cannot
grow it. `_dismiss_current` is gone - its only caller was the preempt. A burst now reads in order:
the three restore warnings show one after another, each for its own lifetime, and a refused loop's
newest sentences are what survive the cap. Tests: `test_a_second_message_waits_for_the_first`,
`test_the_dismissal_starts_the_queued_message`, `test_the_queue_is_bounded_and_keeps_the_newest`.
`ui_capture`'s `TOAST_TIMEOUT_MS` is 70 s because a queued drain costs the sum of its messages
(eight 8 s errors is the cap), not the longest.

Commits: 9fab4cf, 6def169

## GUI-85

**A concept row's provenance tooltip can never show** - fixed 2026-11-13. The row carried the
provenance twice: on its `HBox` (a hover target) and on the `Label` inside it, whose tooltip could
never show because a `Label`'s default `mouse_filter` is `MOUSE_FILTER_IGNORE`. The provenance now
has one owner, the label, which is set to `MOUSE_FILTER_STOP` - so the sentence is reachable over
the text a reader is pointing at - and the row builder is its own function
(`SettingsPanel._make_concept_row`), which is what makes the contract testable without a terminal.
The audit the row asked for found two more unreachable ones and fixed them the same way: the
Terminal tab's on-disk size label (its tooltip is the store path) and the concept editor's error
label (its tooltip is the full error list); `AgentBadge` is `MOUSE_FILTER_PASS` and was already
reachable, and every other `tooltip_text` site is a `Button`, an `OptionButton` or the swatch rows,
hover targets by construction. Tests: `test_settings_concepts.gd` (a plugin concept's row carries
the provenance and stops the mouse; a rule with no source carries none), `test_settings_panel.gd`
(the on-disk label's hover target, and a walk over every label in the panel asserting that one
carrying a tooltip never ignores the mouse) and `test_concept_graph_editor.gd` (the error label's).

Commits: 9fab4cf, f3d2893

## GUI-86

**A scrolled-back terminal offers a jump to the oldest line as well as back to live output** - delivered
2026-11-12: the bottom chevron (v0.8.1) gained its counterpart in the top-right corner, and both
moved into one shared widget (`godot/scenes/ui/scroll_hints.gd`). The terminal binds it with
`bind_custom`: up while `get_scroll_offset() < get_history_size()`, down while `> 0`, neither at the
ends, and the up chevron hides while the search strip covers the pane's top edge. The jump is one
`scroll_up(get_history_size())` - the call measured 0.01 µs and the forced full render that follows
79 µs at 102x78 / 68 µs at 120x60 (release `gpty-core`, 200 reps), identical at 179 / 1,179 / 10,000
lines of scrollback because `display_iter` is viewport-bounded - so depth never enters the cost and
nothing animates (one frame, no tween). The bespoke `ScrollToBottom` button is deleted. Tests:
`test_scrollback_return.gd` (the up chevron reaches the oldest line and hides; the down one still
returns to live output; the click stays chrome in a mouse-reporting pane; the up chevron hides with
the search strip open).

Commits: e0d1088

## GUI-87

**Every scrolling pane carries the same two scroll chevrons** - delivered 2026-11-12: `ScrollHints`
drives a pane's own scroller through one of three bindings - `bind_bar(bar)` for a `ScrollBar`
(`ScrollContainer`, `TextEdit`/`CodeEdit`, `RichTextLabel`), `bind_tree(tree)` for a `Tree`
(`get_scroll()` up, `get_item_area_rect` of the last visible row down,
`scroll_to_item(first/last, false)` to jump), `bind_custom(...)` for the terminal grid - and each
chevron shows only while its direction has content, so a body that fits its viewport shows neither.
Wired: the code viewer (rebound to the visible body on a source/rendered toggle), the CLI view, the
Inspector's answer, the Reasoning turn list, both halves of the wiki note view, and the file tree;
media and the wiki link graph are exempt by design. The pair sits clear of the 8 px scrollbar column
(14 px right inset) and keeps the terminal's 6 px corner. Tests: `test_scroll_hints.gd` (fits-none,
each direction at both ends and mid-range, the two jump actions, a hidden body, tree first/last row,
a custom binding, mouse-only/named chrome, the file-tree and code-viewer wirings).

Commits: e0d1088

## GUI-88

**The pane menu's type list reads as a silent rebuild** - the More menu carried the eight types as a
top-level radio list, so a press on another type discarded the pane with no wording that said so.
The menu is now three named actions with icons - Minimize/Restore pane (U+E32A minus / U+E0A2
arrows-out), Swap pane (U+E0A0 arrows-left-right, no ellipsis), Switch pane type (U+E464
squares-four) - and Switch opens a second popup listing every type with its Phosphor icon and the
current one radio-checked; choosing the current type stays a no-op. Both the workspace rows and the
pane menus build items through `MenuItems.add`/`MenuItems.add_radio`
(`godot/scenes/ui/menu_items.gd`), one icon+text+tooltip+metadata path. Tests:
`test_pane_actions_menu.gd` pins the three-item menu, every icon, the switch list's
order/icons/current mark, and both type-press outcomes.

Commits: 2bf409a

## GUI-89

**The File Tree's first double-click on a folder folds the rows it just listed** - reported
2026-11-14 from daily use: the first activation made the expand arrow appear but left the folder
closed, so opening a directory took a second double-click. Measured on the repo's Godot 4.7.2: a new
`TreeItem` starts with `collapsed == false` and `Tree` never expands by itself (`item_activated` is
only a signal), so `file_tree.gd`'s handler listed the children and then ran its unconditional
`item.collapsed = not item.collapsed`, flipping `false` to `true` in the same event; the second
activation was the first real expand. Fix: population is the first expand (`_populate`, then
`collapsed = false`), and the toggle stays on later activations and still only for a folder with
rows. Test: `test_file_tree.gd::test_the_first_activation_expands_a_folder` (first activation lists
the row and stays open, second folds). The wiki already stated this rule - `panes/file-tree.md` says
a directory is listed "the first time and then expands or collapses it".

Commits: 0f7bc89

## GUI-90

**The first workspace switch after launch takes 551 ms** - fixed 2026-11-14 (build 0.8.3). The
one-shot was never in the switch's GDScript: `_restore_into` attaches every restored workspace's
bodies, but `_apply_layout` positions the active workspace's tiles alone, so a never-visited
workspace had tiles at rect (0,0), unsized bodies and terminals whose children had never started
(`_start_child_if_ready` runs from `_ready`, `_on_resize` and `_process` only, and a hidden grid
processes neither of the last two) - the first visit to one laid its tiles out and spawned their
programs on its arrival frame. `Workspace._prime_restored_workspaces` now supplies one restored
workspace per frame after the launch frame: `_layout_tiles(grid, tm)` (the pass extracted out of
`_apply_layout`) gives its tiles the rect they will be drawn at, and
`TerminalPane._start_child_if_ready(size_hint)` starts each terminal's child at that rect - the
body's own size wins once the container has sorted it, and the `_started` guard keeps the primer
idempotent. Measured windowed (2053x1382, X11, debug gdext, two restored workspaces with one pane
each, `A11y.force_enabled=1`, three launches before and after, `SWITCH_REPS=3`): the arriving
workspace's started panes went 0/1 to 1/1, the arrival frame `frame_us` 29.4 ms (19.8-34.8) to 4.4
ms (4.3-4.4), and switch-to-first-sync `first_sync_us` 49.5 ms (49.0-59.0) to 18.5 ms (18.1-19.4)
against a steady 33.4 ms - so the first switch is now 0.53-0.58x a warm one, and `sync_us` (14.2 ms
on both sides) says the synchronous switch was never the cost. The 551 ms itself was one observation
on the 0.8.1 build over a five-workspace store with `omp`/`lazygit` panes and does not reproduce as
an 8x one-shot on today's build. `switch_bench.gd` reports the first switch on its own
(`cold … started=n/m`, then a `first_switch … ratio=` line) instead of swallowing it as the warm-up.
Consequences: every restored workspace's programs start at launch; a saved pane whose program cannot
start warns and closes its tile then rather than on first visit; and closing a never-visited
restored workspace now asks the running-work question, because its programs are live. Tests:
`test_a_restored_workspace_starts_its_panes_before_it_is_viewed` and
`test_priming_does_not_restart_a_running_child`, both of which fail with the primer's call removed.

Commits: c40f333, 54a4cbb

## GUI-91

**The Inspector's backend is free text, so a typo fails only at session open** - fixed 2026-11-12:
Pane Settings' Backend field is an `OptionButton` built on every panel open from
`GptyAi.list_backends()`, and the vocabulary lives in one pure module,
`godot/scenes/panes/backend_choice.gd` (`BackendChoice`): it mirrors `BackendKind::parse` (`mock`,
`omp`/`oh-my-pi`/`pi`, `cli`, trimmed and case-folded), so a profile that names an alias selects the
canonical row and re-saves its kind. A program the machine does not have stays listed and
selectable, labelled with a `(not found)` suffix and the install-or-`GPTY_OMP` sentence, and a value
the list does not know is kept as `Custom: <value>` instead of being reset. The Command row and its
empty-command hint appear only for `cli`; the model placeholder no longer names omp. Tests:
`test_backend_choice.gd` (alias normalization, empty and malformed rosters, custom-row retention,
missing-program annotation, duplicate and unknown entries) and `test_inspector_backend.gd` (the real
extension roster, selection applied and persisted through `_get_layout_state`, an alias selecting
the omp row, an unknown value staying custom, a stub-reported missing omp annotated but not
disabled, a fresh roster read per open, the cli-only Command row). No capture change: the
`pane-settings` state opens a terminal's panel.

Commits: 6232fd3, 6cecfd6, db5a47c

## GUI-92

**A pane's launch command is honoured but no UI can set or see it** - shipped 2026-11-15 (build
0.8.4). Pane Settings' Shell section gained **Launch command** (`LaunchCommand`, one `LineEdit` plus
a caption): it reads and writes the tile's `launch` line and nothing else, its placeholder is
`Your shell (<cfg shell>)` while empty, and the caption says it runs at this pane's next start and
does not change the program already running. Save Profile's per-pane field became a launch line: it
is prefilled from `settings.launch`, labelled with the pane's name (or its tile number), writes
through `PaneTypes.apply_launch_field` and no longer writes `shell` or `shell_args` - typing
`lazygit` in it runs `lazygit` through the shell exactly as the pane does, a non-terminal tile gets
no row (the dialog says "geometry only" when none exists), and nothing is written for the other
types. A saved launch tile carries the line alone (`_get_layout_state` emits `launch` instead of
`shell` + `shell_args`), so clearing the field falls back to the pane's own program. Tests:
`test_pane_settings.gd` (`test_launch_command_round_trips_through_the_pane_settings_ui`,
`test_clearing_the_launch_command_goes_back_to_the_pane_program`), `test_layout_restore.gd`
(`test_save_profile_dialog_keeps_the_launch_line`), and the `new-pane --setting launch` smoke probe,
which spawns a two-command line and reads both halves back.

Commits: 4ad9a77, 6cecfd6, 01d5859, d099a9f

## GUI-93

**A profile cannot ship a portable launch command: `omp update && omp` needs a shell runner** - shipped
2026-11-15 (build 0.8.4). A terminal tile may carry `launch`: one line, ≤1024 characters, trimmed,
no control characters and no U+FFFD (`PaneTypes.sanitize_launch`; rule kind `launch` in
`TERMINAL_SETTINGS`, accepted from files, the pane panel and IPC). The expansion is one pure helper,
`PaneTypes.spawn_argv`, called at the single `start_shell` site
(`TerminalPane._start_child_if_ready`), so restore, spawn, a profile activation and a restored
workspace all reach it and no second spawn path exists - `_restore_into` needed no expansion code,
and a launch line wins over `command`/`shell_args`. Its plan key is `PaneTypes.LAUNCH_KEY_MARK`
(U+FFFD) + the line: U+FFFD is refused by every sanitizer, so no program or argv can forge a launch
key, and the runner is deliberately absent because it is the user's configured shell rather than a
file's choice (and the install review runs in the CLI before any shell is known) - so the GUI and
`plugin.rs::profile_plan_keys` derive the same key. The Rust mirror gained the launch branch,
`profile_programs` names a launch line first (then `command`, `settings.shell`, the legacy `shell`)
so the install review shows what the record covers, `plugin_manifest::validate_tile` validates
`settings.launch`, and `launch_plan_key_marker_matches_the_gui` reads the GUI source through
`include_str!` so the marker cannot drift. The Workspace Trust dialog prints `program:` (the runner)
and `launch:` (the line). Tests: `test_pane_hardening.gd` (`test_a_launch_line_is_one_trimmed_line`,
`test_a_launch_tile_is_untrusted_and_keyed_by_its_line`,
`test_spawn_argv_expands_a_launch_line_through_the_configured_shell` - POSIX, `cmd.exe`, `pwsh`, the
both-keys winner and the refused line - `test_untrusted_plan_names_the_runner_and_the_launch_line`,
`test_a_launch_line_is_a_terminal_setting_a_file_may_ship`),
`test_layout_restore.gd::test_a_launch_tile_restores_as_a_portable_line`,
`plugin.rs::review_summary_lists_the_plan_keys_each_profile_would_run` (launch keys deduplicated;
the same text as a plain argv is a different plan),
`review_summary_lists_a_launch_line_as_what_the_profile_starts`,
`launch_plan_key_marker_matches_the_gui`, `plugin_manifest::a_launch_line_is_validated_as_one_line`,
and the smoke's end-to-end run of a two-command line. `security.md` carries the verbatim rule; the
v0.7.1 cwd-trust dependency is closed (`tile_plan_key` already appends the workspace directory), so
a builtin may carry a launch line - no builtin does yet (row **gpty-omp ships the OMP-branded
workspace** is where `omp update && exec omp` lands).

Commits: 4ad9a77, 707258b, 6232fd3, 6cecfd6, d099a9f

## GUI-94

**A pane can choose its own directory, with the workspace directory as the fallback** - shipped
2026-11-15 (build 0.8.4). A pane's own working directory is `user://pane_cwd.json` (`PaneCwdStore`,
the `PaneEnvStore` pattern: owner-only atomic writes, typed reads, id-pattern keys, ≤4096 absolute
real paths, 256 entries, one bad entry costs itself), keyed `<workspace id>/<attachment id>` —
attachment ids are unique across the window, so an entry keyed by the pane id alone would follow a
profile from repo X into repo Y. That needed a stable per-workspace id, so `workspaces.json` entries
now carry `id` (`PaneTypes.new_workspace_id`: `ws-` plus 12 hex), minted on the first load of a
store that lacks one and written straight back, surviving renames and resaves;
`sanitize_absolute_dir` (on `BasePersistenceManager`) is now the one directory sanitizer, shared by
`WorkspaceStore.sanitize_cwd`, the store and the new `dir_path` settings rule. Resolution is
`PaneBody.spawn_cwd()` — the pane's own directory when it exists, else the workspace's, else `""`
(gpty's own) — resolved at the moment of the spawn (so a `cli_view` Restart re-checks) with one
toast per stale key and the fallback done in GDScript, because the PTY layer drops an unusable cwd
silently and that is the layer a stale override must not reach. Pane Settings gained a **Directory**
block on terminals and on `cli_view` (picker, **Use workspace directory**, the inherited value named
while empty, a caption saying it applies at the next start); `pane_cwd` is in both types' tables as
`file: false, ipc: false` and never appears in `_get_layout_state`, so no profile, layout, plugin or
`pane-set` caller can supply one. `Workspace`'s `settings_applied` handler is the only writer and
moves the entry on a user rename (a collision rename leaves it: the key names a workspace, so the
other instance keeps its own); `_close_workspace_now` and `_close_all_workspaces_now` drop a
workspace's entries, and `_init_workspaces` retains only the surviving ids. The row's second half is
closed too: `CliProcess::spawn` takes `cwd` (refusing a relative or missing one, and setting `PWD`
on Unix because `chdir` does not), `GptyCliView.start` parses the optional `"cwd"`,
`TerminalManager.spawn_pane` and `_restore_into` hand the workspace directory to any body carrying
`workspace_cwd`, and `scripts/record-demo` lost its `git -C "$HOME"` compensation. Tests:
`test_pane_cwd_store.gd` (sanitizing, key grammar, load caps, move/drop/retain, resolve order, the
stale fallback), `test_pane_cwd.gd` (`test_same_profile_id_in_two_workspaces_keeps_two_directories`,
`test_a_pane_rename_carries_the_entry`, `test_closing_a_workspace_drops_its_entries`,
`test_a_stale_override_falls_back_to_the_workspace_directory`,
`test_a_usable_override_wins_over_the_workspace_directory`,
`test_a_profile_tile_cannot_carry_a_directory`, `test_clearing_the_directory_inherits_again`),
`test_workspace_store.gd`'s three id tests,
`test_cli_view.gd::test_the_child_starts_in_the_panes_directory`, `cli.rs`'s
`spawn_starts_the_child_in_the_given_directory`/`spawn_sets_pwd_for_a_direct_program`/`spawn_refuses_a_missing_directory`/`spawn_refuses_a_relative_directory`,
and the `pane_cwd` markers in `test_pane_settings_reports_the_closed_table`. Behaviour worth
stating: it applies to the next spawn, not the live shell, and a pane's directory sits outside
`tile_plan_key` exactly as its env does (user-owned, keyed by a locally minted workspace id,
unreachable from a file). Original plan, for the record: each workspace now owns one directory
(`workspace_store.gd:78-89` sanitizes it, `workspace.gd:1003-1004` hands it to every terminal,
`terminal_manager.gd:63-78` and `terminal_pane.gd:280` carry it to `pty.rs:421-423`), and that is
exactly the wrong granularity when one profile is activated into two repositories: the pane that
should start in the second repo has no say. Fix: a user-owned per-pane directory in a new
`user://pane_cwd.json` (the `PaneEnvStore` pattern - `BasePersistenceManager`, owner-only,
absolute-only and ≤4096, id-pattern key, empty means inherit, written only by Pane Settings),
resolved in GDScript as pane override, then workspace directory, then gpty's own directory. It must
NOT be a tile field: the v0.7.1 cwd trust row's acceptance is that a profile or plugin tile still
cannot carry a cwd, and the v0.9.5 project-workspaces row states the directory is user-originated,
never a profile or plugin field. The key cannot be `attachment_id` alone: ids are unique across all
workspaces (`workspace.gd:576-585`) and a builtin such as `agent-terminal` reappears in every
workspace that activates the profile, so an override pinned to repo X in one workspace would
silently follow the profile into repo Y and defeat the workspace setting. Key it
`<workspace_id>/<attachment_id>`, which needs a stable per-workspace id in
`workspace_store.gd:48-52` (entries are positional today and renames are allowed), generated on
first load and backfilled on migration. Resolve the path in GDScript, not in Rust:
`crates/gpty-gdext/src/lib.rs:250-269` drops an unusable cwd and the child then inherits gpty's own
directory, so a stale override would land in the wrong layer - instead warn once and fall back to
the workspace directory, and apply the same existence check to a restored workspace path, which
today is only validated when the picker sets it (`workspace.gd:848-856`) and silently degrades after
a repo move. UI: a Directory row in Pane Settings with the existing directory picker
(`FILE_MODE_OPEN_DIR`, `workspace.gd:818-843`) and a `Use workspace directory` action that clears
the entry, showing the inherited value when empty; the debounce/gather pattern is
`terminal_pane.gd:1373-1393`. Migrate the entry on an `attachment_id` rename the way env already
does (`workspace.gd:59-63`), cap the store, and drop entries for deleted workspaces. It applies to
the next spawn, not the live shell, and only terminal panes receive a cwd today
(`workspace.gd:1003`), so decide explicitly whether `cli_view` follows. Tests: store sanitizing
(relative, oversized, control characters, the cap); the same profile id in two workspaces keeps two
directories; a rename carries the entry; a stale override warns and starts in the workspace
directory, not gpty's; a tile that carries `cwd` is still ignored. - and the same resolution must
reach `cli_view`: a cli_view child runs in the GUI process's cwd (Godot's project directory),
because `CliProcess::spawn` (`crates/gpty-core/src/cli.rs`) takes no cwd while terminals go through
`PtyHandle::spawn_with_cwd` (`pty.rs:400`). Found 2026-11-06 while recording `demo-cli-view`:
`gpty new-pane -t cli_view -c git --arg log` in the sandbox listed gPTY's own history instead of the
sandbox repo's four commits, while the same `git log` in a terminal pane showed the sandbox. The
clip now compensates with `git -C "$HOME"`; when this row ships, a cli_view pane prints the pane
override and then the workspace directory (a test runs `pwd` through it) and that `-C` comes out of
`scripts/record-demo`.

Commits: 4ad9a77, 6232fd3, 39085e9, 6cecfd6, 5ce59b2, cbe89dd

## GUI-95

**The built-in Agent Workspace still names OMP** - shipped 2026-11-15 (build 0.8.4).
`profiles.default.json` now describes the profile as "A terminal beside an Inspector for private Q&A
and a Reasoning pane for the agent's live commentary" and wires it with
`agent-terminal`/`agent-inspector`/`agent-reasoning`; the Inspector tile's redundant
`backend: "omp"` is gone (the pane's own default is `omp` and `apply_settings` only writes keys it
is given). The pane copy stopped naming a tool: the Inspector status is "Inspector idle — private
Q&A, not the terminal session" and its hint "Private Q&A. Does not follow the terminal session.";
the Reasoning pane starts on `agent-terminal`, its idle status reads "Listening for agent events
from …", and its states are "Attached to agent session"/"Agent session ended"; the three Pane
Settings attachment placeholders now show the `agent-*` family. The actionable extension instruction
is byte-identical (`omp plugin link <gpty>/extensions/gpty-omp-events`, `restart omp`,
`echo $GPTY_EVENT_PROTOCOL`), and the adapter contract did not move: the `omp` backend default,
`omp_events.rs`'s vocabulary, the `omp_session_id` envelope field and `@gpty/omp-events`. Tests:
`test_reasoning_pane.gd` (its fixture id and all four status/copy assertions renamed, plus the new
`test_default_source_is_the_built_in_agent_terminal`), and `test_layout_restore.gd`'s new
`test_the_agent_workspace_reasoning_tile_follows_its_terminal`, which asserts the three ids as a
set, that every Reasoning tile follows a terminal in its own profile, and that the Inspector carries
no `backend` - a half-rename fails it. `./scripts/gut-check` 115 scripts / 1422 tests; a
fresh-profile smoke (own `XDG_DATA_HOME`, `GPTY_SOCKET`) loaded the seeded profile, `list-panes`
answered exactly `agent-terminal`/`agent-inspector`/`agent-reasoning`, and the seeded description
came back generic. Existing installs keep the `omp-*` copy already in `user://profiles.json`
(seeding is by name and the marker stops a re-add), and saved layouts and workspaces keep their own
ids, so the one public-handle change is a script that assumed `omp-terminal` after activating the
built-in.

Commits: 6232fd3, 6cecfd6, 3546b85, a2bfbb3

## GUI-96

**The Profiles section's entry point advertises "layouts"** - fixed 2026-11-15 (build 0.8.4). One
vocabulary, applied to the three visible strings and the docs: `CATALOG_HINT_TEXT` is now
`"More profiles \u2192"` (its comment too: the only shipped *profiles* are the two built-ins, the
tool profiles live in plugin repos), the workspace-restore trust dialog opens "This saved workspace
set contains %d workspace(s) whose panes start a different program…" because a layout lives inside
one workspace and the file being restored is the set, and the plugin review prints "no program
(geometry only)" for a profile whose tiles carry geometry and nothing to run. The terms now match
the app's own tables everywhere: a profile is the named reusable tile set; a layout is the
arrangement inside one workspace. `docs/content/plugins.md` says "profiles (named tile sets)", and
`docs/content/wiki/gpty/sidebar.md`'s Profiles paragraph says "two shipped profiles",
`More profiles →`, and (stale from the launch-line work) "lets you give each pane a launch line"
instead of "edit each pane's command". Copy that was already true stays: "Save current layout as
profile", "Activating a profile will replace your current layout", and the vault graph's `Relayout`.
Tests: `test_sidebar.gd` pins the row to `Sidebar.CATALOG_HINT_TEXT`;
`test_plugin_review_text.gd::test_profiles_show_what_they_would_start` asserts the new sentence. No
test pinned the dialog body (verified: no `This layout contains` in the suite).
`./scripts/gut-check` 115 scripts / 1422 tests.

Commits: b4703be, a2bfbb3

## GUI-97

**A profile's declared grid unit is dropped on load** - found 2026-11-12 while closing the v0.8.3
row **The workspace store drops the grid unit it is handed**: `workspace.gd` read
`profile.get("grid_unit", 0)` before `scale_layout`, but no producer set the field, so the read was
dead code and a profile authored in a coarser grid relied on `scale_layout`'s inference (correct
only while the tiles touch the grid's far edge). Fixed 2026-11-15 (build 0.8.4): every producer
writes the unit through `PaneTypes.sanitize_grid_unit` -
`ProfileManager.add_profile`/`update_profile` stamp `PaneTypes.GRID` (their tiles come from live
tiles, so a save cannot be in another unit; the Save Profile dialog and `profileSave` inherit the
stamp), `_load_defaults` copies a declared unit and stamps `GRID` on a file that declares none (the
shipped file is this build's app content), `load_profiles` normalizes a hand-edited store (12 and 60
survive, anything else becomes 0 = infer), and `_derive_plugin_profiles` copies the plugin record's
unit. The one consumer, `Workspace._activate_now`, reads through the same sanitizer. The plugin
chain carries it end to end: `[[profiles]]` may declare `grid_unit` (12 or 60; geometry is validated
against it and `cspan`/`rspan` default to it, anything else is refused by name),
`PluginProfileRecord` stores it (`Option<i64>`, absent for a record written before the field
existed), `profile_records` writes the manifest's unit, and `profiles_json` forwards it - a plugin
declaring one must set `min_gpty_version` to `0.8.4`, because an older GUI ignores the field and
infers. Tests: `test_profile_grid_unit_round_trips_and_unknown_units_are_dropped` (all four
producers + the four store shapes),
`test_a_profile_written_in_a_coarser_unit_activates_the_same_shares` (installed-plugin JSON ->
`find_profile` -> activation; a quarter of a 12-unit grid stays a quarter),
`a_profile_declares_the_grid_unit_its_tiles_are_written_in`,
`profile_grid_unit_round_trips_and_a_non_integer_is_rejected`,
`profiles_json_forwards_a_declared_grid_unit`; measured on the running app in a sandbox,
`gpty profile save` wrote `"grid_unit": 60` (the seeded defaults too) and a hand-written 12-unit
profile loaded both of its panes over `profileLoad`. Docs: `agents/plugins.md`, wiki `plugins.md`
and `profile.md`.

Commits: 6422038, 1f8b3fb

## GUI-98

**A settings value the pane normalizes is accepted as applied** - fixed 2026-11-15 (build 0.8.4). A
rule may carry `values`, a closed set checked in `PaneTypes._value_for_rule` after the rule's length
check, so an unknown member is refused at every source: `pane-set`/`new-pane --setting` answer
`-32602` naming the key, a saved tile drops it and `Workspace._restore_into` reports it once, and
the pane keeps the value it had. `paneSettings` publishes `values` beside `kind`/`file`/`ipc`. The
vocabularies moved to one owner in `PaneTypes` - `CODE_VIEWER_LANGUAGES`, `CODE_VIEWER_VIEW_MODES`,
`FILE_TREE_OPEN_MODES`/`FILE_TREE_DEFAULT_OPEN_MODE`, `WIKI_VIEW_MODES` (also `paneView`'s `mode`) -
and the wiki, code-viewer, file-tree and Inspector apply-time re-derivations are deleted.
`inspector.backend` is the one canonicalizing rule, `kind: "backend"`: `BackendChoice.selected_kind`
runs in the table, `BackendChoice.KINDS`/`ALIASES` are data (the list `pane-settings` publishes), an
alias folds to its kind and an unknown name is kept verbatim so the shipped, tested `Custom:` row
still shows it - closing that key to a set would have reset a user's file instead. Measured
2026-11-15 on a sandboxed headless build: `pane-set <code_viewer> --setting view_mode=bogus --json`
answers `-32602` with "cannot be applied to this pane: view_mode (an unknown key, a value of the
wrong type or outside a closed set, ...)" and exits 1, `--setting view_mode=source` answers
`changed: ["view_mode"]` with `settings.view_mode: "source"` and exits 0, and `pane-settings` prints
`wiki.view_mode = {kind: text, max: 32, values: [edit, split, preview]}` and
`inspector.backend = {kind: backend, max: 32, values: [mock, omp, cli]}`. Tests:
`test_a_closed_set_refuses_a_member_it_does_not_know`,
`test_a_saved_tile_names_a_refused_closed_set_member`,
`test_a_backend_alias_folds_and_an_unknown_name_is_kept`,
`test_a_closed_set_member_never_reaches_the_pane`,
`test_pane_set_refuses_a_member_outside_a_closed_set`, and the live smoke's
`pane-settings`/`pane-set` steps. Screenshot: none - the dropdowns render the same, only a value
that used to be silently ignored is now refused.

Commits: b823d5f, f9e51e3

## GUI-99

**A code viewer re-reads its file on every settings edit** - found 2026-11-14 while wiring pane
settings over the API: `CodeViewerPane.apply_settings` called `load_file(settings["file_path"])`
whenever the key was present, and the pane settings panel's gather always includes it, so editing
the pane's name or font size re-read the document and reset the read-only editor's scroll and caret
(`MediaPane` already guarded exactly this). Fixed 2026-11-15: the viewer takes
`previous_path := file_path` before `super.apply_settings` and reloads only when the path moved - an
unchanged path just re-renders the view, so a font or name edit repaints without touching the
document. Test `test_a_name_edit_keeps_the_viewers_scroll` (200-line temp file, scrolled to line 10,
a `pane_name` edit leaves the scroll and the text alone, and a genuinely moved `file_path` still
loads the new file so the guard is not "never reload"). No headless-observable live surface for
scroll position: the test drives the real pane and the panel's gathered dictionary.

Commits: b823d5f, 3a3c266

## GUI-100

**A per-pane store is rewritten on every settings keystroke** - found 2026-11-15 while adding the
pane-directory store: the pane settings panel re-applies its gathered dictionary on every 150 ms
debounce tick, and `PaneEnvStore.set_env` wrote the 0600 store each time even when the value was
unchanged, so editing a pane's *name* or font size rewrote `user://pane_env.json` at typing speed
(`PaneCwdStore.set_dir` already compared first). Fixed 2026-11-15: `set_env` returns before the
write when the stored value already equals the cleaned one (`remove_env` already returned when the
id was absent), so there is one write per actual change. Test
`test_setting_the_same_value_writes_nothing` counts `_write_file` calls through
`MockAutoloads.write_count` (the bytes are identical either way, so content cannot prove it): a real
change writes once, the same value however padded writes nothing, a changed value writes again, and
removing or clearing an absent entry writes nothing. `MockAutoloads` now counts every mocked
`_write_file`, so the other stores' write discipline can be asserted the same way. No user-visible
failure was involved - no data loss, the write is atomic, and the file is small.

Commits: 52efe76, e70ba6c

## GUI-101

**A pane with no configured directory starts in two different places** - fixed 2026-11-16 (build
0.8.4). `PaneCwdStore.resolve` now answers the user's home (`home_dir`: `HOME`, then `USERPROFILE`,
then `HOMEDRIVE`+`HOMEPATH`, sanitized like every directory) when neither the pane nor the workspace
names a usable directory, so the terminal's PTY and a `cli_view`'s child receive the same explicit
path. Measured before in a sandbox: `pwd` in a terminal answered `/home/neilp`, a `cli_view`
answered the project directory `/mnt/App/Projects/godot-pty/gpty/godot`; after, both answer the home
directory. One owner also feeds the Pane Settings "Inherits" line, the workspace picker and the two
Rust edge docs; the trust key's `""` stays "no configured directory" (`security.md` updated). Tests:
`test_a_terminal_and_a_cli_view_start_in_the_same_place` (both children print their cwd in one
workspace with no directory), `test_with_no_directory_the_child_starts_in_the_users_home`,
`test_resolve_prefers_the_pane_then_the_workspace_then_home`,
`test_resolve_falls_back_when_a_directory_is_missing`.

Commits: 47092ee, c6d0d8f

## GUI-102

**A scheme with fewer than 16 colours inherits the rest of the previous one** - fixed 2026-11-16
(build 0.8.4). `gpty_core::color::palette_from_csv` answers a complete 16-colour array - every valid
CSV entry fills its own slot and every other slot is `SYSTEM_COLORS` - and
`GptyTerminal.set_palette` assigns that whole array, bumping the generation only when it differs. A
short or malformed scheme can no longer paint indices 4-15 with the colours of the scheme before it,
and re-applying the current scheme costs no repaint. Tests (gpty-core):
`a_short_scheme_keeps_no_colour_from_the_one_before_it`,
`a_malformed_entry_keeps_the_default_in_its_slot`, `entries_after_the_sixteenth_are_ignored`.

Commits: 7178999, c6d0d8f

## GUI-103

**Settings cards and the command palette keep a fixed height their content does not fill** - fixed
2026-11-16 (build 0.8.4). `OverlayPanel.fit_card_content` sizes a centred card to its content up to
its design size and the window; `place_card_top` does the same for the palette's plain host and
keeps the top edge a design-size card had, so filtering from 15 rows to two shrinks the card
downward and the query field never moves under the caret. The Settings card measures the active
tab's own content (the `ScrollContainer`'s minimum) and refits on `tab_changed`: a short tab no
longer paints the dead band below its last row, and a tall tab keeps the design height and scrolls.
Tests: `test_filtering_shrinks_the_card_and_keeps_the_field_still` (palette),
`test_a_short_settings_tab_sizes_the_card_to_its_content`, with the three clamp tests updated to a
tall tab. Screenshots ([captures](../v0.8.md#screenshots)): *Filtered palette, content-sized* and *A
short Settings tab sizes the card*.

Commits: f37fde8, c6d0d8f

## GUI-104

**A pane re-sanitizes the settings the table already sanitized** - fixed 2026-11-16 (build 0.8.4):
all five overrides now let `PaneBody.apply_settings` do every assignment and keep only their live
side effects. Deleted: `CliViewPane.apply_settings`'s `sanitize_shell`/`sanitize_shell_args` pair
(and the comment claiming `super` assigns a String `command` unchecked); `TerminalPane`'s
`shell_args` re-sanitize; `InspectorPane`'s re-assignment of `auto_run`, `accept_concept_captures`,
`system_prompt`, `model` and `command`; `MediaPane`'s `clampf` on `volume_db` and its second `muted`
assignment; `ReasoningPane`'s `source_attachment_id` re-derivation. What stays is the side effect
each override exists for: cli_view's `prev_*` captures and its "Program, arguments or directory
changed - Restart to apply" row, terminal's `_restore_color_strings` and `_repaint_all`, the
Inspector's `_close_session` on an aim change, media's `_apply_audio_volume` and the `file_path`
reload guard, reasoning's turn reset and idle status. Test
`test_pane_settings.gd::test_a_refused_setting_value_leaves_each_panes_property_alone`; run against
the pre-fix panes it failed on five assertions (terminal and cli_view cleared `shell_args` to `[]`,
the Inspector stored a 200-character `model`, media turned `INF` into `6.0`, reasoning cleared the
source id to `""`), and it passes now.
`test_cli_view.gd::test_apply_settings_sanitizes_the_spawn_plan` keeps its assertions with its two
stale comments corrected. Docs: `agents/gdscript.md` now states the table is the only assignment
path and names the test. `./scripts/gut-check` 115 scripts / 1433 tests; `./scripts/ci-check` green.

Commits: f9e51e3, 47092ee

## GUI-105

**A pane's font-size setting does not reach text already on screen** - closed 2026-11-17:
`PaneBody.font_size`'s setter now calls `_recompute_cell_metrics()` for **every** pane type (a
repeated value is a no-op, so the debounced panel does not re-measure per keystroke), and the hook's
contract is that an override re-applies the size to every view the type owns, invalidates any height
measured at the old font, and tolerates null widgets (a spawn applies settings before `_ready`). It
reaches the Inspector's answer and thinking view, the CLI View's output, the code viewer's editor,
rendered Markdown and empty state, the file tree's `Tree` (which had never received the setting at
all) and empty state, the media pane's placeholder and status, and the wiki editor and preview.
`PaneBody.empty_state_font(title, hint, font_px)` is now the one owner of the empty state's
title/body offset, and the Reasoning and Wiki `apply_settings` workarounds are deleted (the base
drives both). The wiki note list, the graph labels and the media transport's time label stay on the
theme/chrome size by decision: index, diagram and chrome, not the pane's text. Tests:
`test_a_font_size_change_recomputes_and_a_repeated_value_does_not` (the hook reaches a pane with no
`_font`; a repeated size does not re-measure), `test_a_font_size_change_reaches_an_inspector_answer`
(theme size and a grown content height), the per-pane `test_a_font_size_change_reaches_…` tests for
a rendered file, streamed output, the file tree, the media placeholder and an open note, and
`test_a_font_size_applied_before_the_terminal_is_ready_lands_with_its_font` for the spawn-order
guard.

Commits: 12e7d7f, 7f630ce

## GUI-106

**TextRead uncapped buffer read on dynamic files and concurrent writes** - closed 2026-11-20. Cause
(`unbounded`): `TextRead.read_prefix` called `FileAccess.get_size(path)` to decide
`truncated := size > cap`, falling back to `f.get_as_text()` when `size <= cap`. On dynamic files
with 0 stat size (e.g. `/proc/version`) or files concurrently appended to after `get_size`, the read
was uncapped on the GUI thread and reported 0 size. Fixed in `godot/scenes/panes/text_read.gd`: the
read is always bounded to `cap + 1` bytes via `f.get_buffer(safe_cap + 1)` and decoded with
`_decode_utf8_prefix`, completely eliminating `f.get_as_text()`. `f.close()` is called immediately
after the buffer read, `truncated := raw.size() > safe_cap`, and
`reported_size := maxi(size, raw.size())` so dynamic and growing files report actual read length.
Tests: 10 unit tests in `godot/tests/unit/test_text_read.gd` verifying refusal of
non-absolute/virtual/missing/directory paths, exact cap and cap + 1 reads, 2 MiB file capped to
exactly 1 MiB without `get_as_text`, clean UTF-8 slicing on torn multi-byte sequences at the cap,
bounded `/proc/version` reads with non-zero size, and static assertion that `text_read.gd` contains
no `get_as_text()` call. All existing tests in `test_pane_file_sinks.gd`,
`test_code_viewer_markdown.gd`, `test_viewable_files.gd`, and the 123-script / 1562-test GUT suite
pass.

Commits: 80eebf6, 182908b

## GUI-107

**The empty workspace teaches every shortcut, with a living keycap** - closed 2026-11-11:
`godot/scenes/ui/shortcut_guide.gd` (`ShortcutGuide`) replaces the two-label empty state with a
title/subtitle, a 3 s keycap press/ripple that cycles the four spawn bindings (chords read from
`ShortcutManager.chord`), an **Open a Terminal** action, and all 23 registered bindings as grouped
cards fed by `ShortcutCatalog.rows(...)`; the rows, hero steps and primary action are callables, so
a later guided tour can reuse the surface. The guide re-reads the registry on every show, keeps the
CTA above the fold and scrolls inside the empty surface at 560x340, centres when it fits, and
`pin_animation()` freezes the clock for captures. Tests: `test_shortcut_guide.gd` (rows, primary
signal, cycle/pin, fit/columns, split) and `test_workspace_settings.gd`
(`test_an_emptied_workspace_shows_the_guide`, `test_the_empty_guide_scrolls_at_the_layout_floor`);
the full GUT gate passed 103 scripts / 1257 tests.
`scripts/ui-capture-check settings first-launch empty-workspace empty-workspace-560x340` passes (two
runs pixel-identical, only `settings` changes under perturbation); `--audit-focus first-launch`
reports `unaccounted=0` with `PrimaryAction` first in the tab order, and
`--audit-accessibility first-launch` reports `unnamed=0`. Captures: `first-launch`,
`empty-workspace`, `empty-workspace-560x340`.

Commits: a4ecd54

## GUI-108

**Dynamic Shaders** - closed 2026-11-21 (build 0.8.6): the closed table is `UiEffects` - `crt`
(static scanlines, a phosphor mask and a vignette) and `grain` (film grain in a half-resolution
`SubViewport` at 30 Hz) - and its two `preload` paths are the only shaders the app can run; no
profile, settings file or plugin names one. `Settings → Appearance → Effects` offers the table and
an `Off`/`Subtle`/`Full` intensity (Off by default, Subtle = half the shader's amplitude), persisted
as `effect`/`effect_intensity` and broadcast through `apply_to_terminal`; the pane schema
(`PaneTypes.TERMINAL_SETTINGS`) accepts only the table's ids and `test_ui_effects.gd` keeps the two
lists equal. The orphan `godot/shaders/crt.gdshader` was deleted and its replacement fixes both
defects it carried: the scanline term is a UV period computed from the pane's own height and the
font's cell height (`rows`), never `SCREEN_PIXEL_SIZE` and never scaled by resolution, and the
shader keeps `COLOR` (the ground's tint and alpha) instead of sampling a texture. The lit band adds
a little light so the comb is visible on the default black ground, and the gap darkens a lit ground,
so both themes read. A pane paints the ground through one `Layer.EFFECT` quad under every band; the
pane's own ground rect and the row runs at the default background are skipped while it is active, so
text, selection, inverse cells and ANSI backgrounds stay opaque and a scheme's alpha does not
compound. Static effects are not evaluated per frame (the layer is redrawn only when the pane
changes); grain's budget is declared as the row's measured FBM upper bound (0.29 ms at 1080p, 1.02
ms at 4K) because this environment has no GPU (Godot fell back to GL Compatibility on llvmpipe,
where the bench measured a 2.46 ms full-frame software delta at 4K over an 18 ms baseline), and
`godot/tests/bench/effect_bench.gd` is the harness that will replace it on real hardware.
Glassmorphism's translucency is the shipped window-opacity veil; a backdrop blur reads behind the
window and stays in the Future row. Tests: `test_ui_effects.gd`
(`test_the_ambient_ids_are_the_pane_schema_values`,
`test_every_ambient_entry_declares_a_shader_a_budget_and_a_rate`,
`test_an_unknown_effect_falls_back_to_the_default`,
`test_the_level_clamps_and_strength_is_half_at_subtle`), `test_pane_effects.gd`
(`test_an_active_effect_adds_one_ground_layer_below_every_band`,
`test_no_effect_layer_exists_while_the_intensity_is_off`,
`test_a_default_background_run_is_skipped_only_while_an_effect_is_active`,
`test_the_animated_effect_renders_into_a_half_resolution_buffer`,
`test_a_pin_renders_one_buffer_frame_and_stops_the_clock`,
`test_turning_the_effect_off_frees_the_layer_and_the_buffer`), `test_settings_manager.gd`
(`test_the_effect_and_its_intensity_survive_a_restart`,
`test_an_unknown_stored_effect_loads_as_the_default`), `test_workspace_settings.gd`
(`test_a_settings_save_broadcasts_the_effect_to_every_terminal`) and `test_settings_panel.gd`
(`test_the_effects_section_lists_the_closed_table_and_intensity`,
`test_the_appearance_reset_restores_the_effect_defaults`). Screenshot
([captures](../v0.8.md#screenshots)): *The CRT effect at Full behind text, the same effect at Subtle
on the light scheme, and film grain at Full.*

Commits: d17bac7, 6cecfd6, 03dea32, 46b68e9, 1bd3a18

## GUI-109

**Panes animate when they are created, destroyed or swapped** - closed 2026-11-17 as the framework
plus three built-ins. `godot/scenes/terminal/pane_transitions.gd` is the registry: each animation
declares the transitions it serves (`create`/`close`/`swap`), the channels it touches (`alpha`,
`scale`, or the swap's rect pair) and a property schema (`duration_ms`, `scale_from`,
`overshoot_pct`), so a new animation is one table entry and appears in the pickers with no settings
or workspace code. `godot/scenes/ui/ui_motion.gd` is the policy: `SettingsManager.cfg_motion` is
Off/Subtle/Full - Off draws every change in one frame, Subtle eases with no overshoot, Full allows
the animation's declared overshoot capped at 3 % (`UiMotion.overshoot`). Settings → Appearance →
Motion carries the master switch, one picker per transition (None included) and the selected
animation's property rows generated from the schema; every write applies without a restart. Create
reserves the final rect first, then fades and scales the wrapper from 0.92 with its pivot at the
centre, so no sibling moves; close detaches the tile, grows the siblings, draws the dying wrapper
above them and below the divider bands, fades it out and frees it exactly once after the tween (a
closed terminal's process therefore lives one transition longer); a position swap records both
rects, commits the tile data, lays out, then eases both wrappers between the old and new rects.
`PaneTransitions` is skipped on an inactive or hidden workspace, during a divider drag, and while
any terminal in that workspace is in its flood cadence (`TerminalPane.under_flood_load`); a layout
pass snaps create and swap to final and leaves a close ghost alone (its rect is already final); the
launch/profile restore path never reaches the layer. A type switch fades the new pane in over the
freed old one. Tests: `test_pane_transitions.gd` (registry shape, default/kind fallback, parameter
sanitation and clamping, the overshoot cap, runner guards), `test_pane_motion.gd` (create settles on
the exact layout rect, close frees once, one transition through a close-during-create, Off is one
frame, a layout pass snaps, swap ends in the swapped rects, hidden-workspace and flood suppression),
`test_settings_manager.gd` (roundtrip, damaged store), `test_settings_panel.gd` (pickers, generated
rows, debounced edit, reset).

Commits: 6cecfd6, 46b68e9, e2eeaa9

## GUI-110

**The transition library grows past fade and move** - closed 2026-11-21: three entries joined the
registry. `slide` (create/close) is the new `slide` channel: it offsets the wrapper `distance_px`
(8-240, default 48) toward the tile's split edge - the manager records that edge on the tile (`edge`
= `left`/`right`/`top`/`bottom`, written by `_split_horizontal`/`_split_vertical`, absent on a
restored or full-grid tile) and the runner clamps the offset to the grid, so a ghost never paints
over the sidebar - then eases to the final rect, and `_snap` restores the position of a snapped
create; `pop` is a create/close entry over the existing alpha+scale channels (scale from 0.55 in 120
ms, the 3 % overshoot at Full) and needed no runner code; `crossfade` is the new swap `fade` channel
- both wrappers dissolve out where they were drawn, trade rects at the midpoint, and dissolve back
in, with the swap snap restoring the base modulate. Every entry keeps the framework's contract:
`Off`/`None` draws in one frame, a natural finish lands exactly on the final rect/scale/alpha, and a
second transition on the same wrapper takes ownership of the first. The pickers, property rows and
storage took no change: all three appear in `Settings → Appearance → Motion` from their registry
entry alone. Tests: `test_a_slide_offset_points_at_the_split_edge_and_stays_in_the_grid`,
`test_every_create_and_close_animation_declares_a_channel`,
`test_a_slide_create_enters_from_the_split_edge_and_lands_on_its_rect`,
`test_a_slide_close_exits_toward_the_split_edge`, `test_a_pop_create_grows_from_its_scale`,
`test_a_crossfade_swap_dissolves_through_the_midpoint`, and the extended picker and property-row
assertions. No new capture here: the v0.8.6 capture row owns the release images.

Commits: e2eeaa9, b4a0f56

## GUI-111

**Window fit: opacity and inner padding** - closed 2026-11-20:
`Settings -> System -> Window opacity` (presets 100/95/90/85/80/75/70/60/50/40 %, stored as
`cfg_window_opacity` and clamped 40-100) writes `Window.transparent`/`transparent_bg` and shows the
`Workspace`'s full-screen opacity veil (`godot/shaders/window_opacity.gdshader`: a `BackBufferCopy`
plus a `blend_disabled` pass that samples the finished canvas, renormalises its premultiplied colour
and writes the setting's alpha once), with a new first-child `WindowBg` rect covering every seam
(with `transparent_bg` the engine's clear colour is transparent, so an uncovered pixel would turn
black at that alpha); a per-surface `Workspace.modulate` was the first implementation and measured
framebuffer alpha `0.992` at a 70 % setting because the terminal stacks four opaque surfaces, while
the veil gives `0.698` - the window is genuinely at the setting; the row is disabled, not dead, when
`WindowChrome.transparency_supported()` (i.e. `DisplayServer.is_window_transparency_available()`) is
false, and `project.godot` now carries `display/window/per_pixel_transparency/allowed=true`, because
the engine answers unavailable without it even on OpenGL. Measured on this desktop (Godot 4.7.2, RTX
5070 Ti, XWayland): false under the shipped Forward+ renderer here, so the row is disabled on this
desktop, and true under `--rendering-driver opengl3` and native Wayland; an in-app capture of the 70
% setting reads framebuffer alpha `0.698` across the app's pixels, while an embedded `AcceptDialog`
stayed 1.0 - dialogs, file pickers and popup menus are separate engine viewports and stay opaque,
like a terminal's menus. `Settings -> Appearance -> Terminal padding` (0-24 px per side, default 4
in `PaneTypes.TERMINAL_PADDING_DEFAULT`, stored as `cfg_terminal_padding`) is spent on the fit:
`_grid_for_size` subtracts `2 x pad` and `_grid_offset` centres the grid inside that box, so the row
and column counts always equal what the pane draws; a padding change refits the live grid at once
through `_resize_to_fit` (the existing 0.05 s debounce is its retry for a refused backend resize),
and the same metrics hook now makes a font-size change refit instead of waiting for a tile resize.
Tests: `test_the_fit_spends_the_padding_on_every_side`,
`test_a_padding_change_refits_the_live_grid`, `test_a_font_size_change_refits_the_live_grid`,
`test_opacity_veils_the_whole_window`, `test_a_window_that_cannot_be_transparent_stays_opaque`,
`test_saving_the_opacity_reaches_the_window`, `test_the_opacity_veil_sits_above_every_surface`,
`test_the_window_opacity_row_is_disabled_with_a_reason_when_unsupported`,
`test_the_opacity_hint_names_the_driver_and_the_way_out`,
`test_the_window_opacity_row_offers_the_presets_and_saves_a_pick`,
`test_the_terminal_padding_row_writes_and_saves`, `test_window_fit_settings_roundtrip`. The Linux
`.desktop` entry, icon and "Open gPTY here" file-manager action ship with v1.0.0's Distribution
item, not here. The Settings row is present on every display server (2026-11-20): where
`transparency_supported()` is false it is disabled and carries `opacity_hint`'s reason, because
hiding it made the shipped feature look unshipped under X11/XWayland.

Commits: d17bac7, 6cecfd6, bf8d378, 66a986c

## GUI-112

**Colour schemes: import, and light mode that follows the system** - closed 2026-11-20:
`gpty-core::scheme` turns a native JSON, Alacritty (TOML and YAML), iTerm2 XML plist, Base16 or
legacy 16-colour CSV file into one `Scheme` (16 ANSI entries plus foreground, background, cursor and
selection), capped at 16 KiB, with a closed native key set, a strict YAML block-mapping subset, and
an iTerm2 reader that refuses an internal DOCTYPE subset, CDATA and any entity but the five
predefined ones. `GptyScheme.parse` is the FFI seam and `SettingsManager.import_scheme` copies a
validated native file into `user://schemes/`, so the source may move or be deleted. Eleven schemes
ship (dracula, gruvbox dark/light, nord, tokyo-night, catppuccin mocha/latte, one-light, solarized
dark/light, vivid) with their licences recorded in `LICENSE-EXCEPTIONS.md` section 4. The terminal
joins the chrome's existing resolution: `cfg_scheme_dark`/`cfg_scheme_light` are read through
`active_scheme_path()`, an empty light slot follows the dark one, and the old `color_scheme` key
migrates on load. A pane keeps its own scheme in `PaneSchemeStore` (`pane_scheme`, `file: false`,
`ipc: false`). Colour now reaches the cells for real: `Palette` carries the default pair,
`set_default_colors` writes it, `CellInfo::from_cell` resolves `NamedColor::Foreground`/`Background`
through it, and `_apply_palette` runs unconditionally after `start_shell`, which also closes the
v0.9.5 foreground row; a scheme's cursor and selection are drawn at gPTY's overlay alphas. The
chrome palette stays separate - `UiPalette` tokens are untouched. Tests: `parse_scheme`'s Rust suite
(`native_json_*`, `iterm2_*`, `alacritty_*`, `base16_uses_the_shell_mapping`,
`legacy_csv_fills_missing_slots_from_the_system_palette`, the byte cap and name caps, the native
round trip), `palette_resolve_separates_foreground_from_white`,
`a_cell_with_the_default_foreground_uses_the_palette_foreground`, `test_scheme_library.gd` (listing,
import copy, refusal sentence, id suffix, six keys), `test_scheme_settings.gd` (pair resolution,
light-follows-dark, migration, save drops the old key), `test_pane_scheme_store.gd`, and
`test_the_ground_is_the_grid_background`'s native-scheme half. Screenshot
([captures](../v0.8.md#screenshots)): *The terminal's colour pair beside the chrome*.

Commits: d17bac7, 6cecfd6, 017e1cb, 9571f98

## GUI-113

**The launch frame is the engine's default logo on grey** - fixed 2026-11-20 (build 0.8.6):
`godot/assets/boot_splash.png` is a committed 3840x2160 (2x a 1920x1080 window) frame - the
`icon.png` blue line art with its grey plate dropped, a 640 px mark, and a 240 px Open Sans SemiBold
`gPTY` wordmark over a soft accent glow on `UiPalette.DARK["SURFACE"]` (`#202128`), 172 KiB.
`project.godot` names it (`application/boot_splash/image`), pins `bg_color` to the same SURFACE so
every letterbox/crop edge is seamless, and uses `stretch_mode=2` (Keep Width in 4.7's hint: a 16:9
window is an exact fill, a 4:3 window letterboxes without clipping the mark, and a wider window
crops only the flat edge); `minimum_display_time` stays 0. The frame is one fixed dark picture
because the engine paints it before any script (the row's constraint); the exporter embeds the
image, so no export filter changed and all three platforms get the same frame.
`test_the_launch_frame_is_configured` pins the wiring and colour, and
`test_the_launch_frame_is_a_brand_surface` pins the 3840x2160 texture, the four SURFACE corners, the
mark/wordmark pixels and the <512 KiB cap. Verification is the window-level capture
(`scripts/screenshot-gpty` with `SCREENSHOT_CAPTURE=import`, which does not draw the pointer): the
engine's own frame, not the Godot logo. Screenshot ([captures](../v0.8.md#screenshots)): *The
branded launch frame*.

Commits: b4703be, 1c3d39e

## GUI-114

**The Settings tab bar overflows behind the engine's arrows at the 560 px floor** - fixed 2026-11-20
(build 0.8.6): measured at the floor, the live eight-tab bar needed 561 px of the 504 px it had and
hid `Shortcuts` and `About`. Cause (`missed-call-site`): a `TabContainer`'s internal `TabBar` takes
its tab styleboxes and font colours as overrides from the **`TabContainer`** theme item, not the
`TabBar` item; `UiTheme` registered them on `TabBar` only (only `font_size` was mirrored), so the
engine's default box - 10 px a side plus 1 px borders, 20 px per tab - was live and the row was
off-brand as well as 57 px too wide. Both types now carry the same `StyleBox` objects and colours,
and the engine's 8 px `side_margin` indent is zeroed so the row aligns with the header; the app's 6
px box puts the eight at 401 px of ink + 8*12 = 497 px, 15 px inside the 512 px bar (the card's 544
px less its 16 px inner margins). `test_the_tab_box_is_on_both_types` pins the two registrations,
`test_the_live_tab_bar_uses_the_theme_box` pins the forwarding, and
`test_all_eight_tabs_fit_the_560x340_floor` pins the clamped card (544 px, bar 512 px) with
contiguous rects; `settings-560x340` shows `About` on the row with no arrows. Screenshot
([captures](../v0.8.md#screenshots)): *All eight Settings tabs on the 560x340 floor*.

Commits: d1d49d0, 1c3d39e

## GUI-115

**A GPU fallback to a software rasterizer is silent, and its FPS reads as the app's cost** - reported
2026-11-21 from a launch log: Vulkan returned `ERR_CANT_CREATE`, OpenGL 3 `ERR_UNCONFIGURED`, Mesa
EGL logged `failed to create dri2 screen`, and the run ended on `Mesa llvmpipe`; `nvidia-smi` agreed
with `Failed to initialize NVML: Driver/library version mismatch` (userspace 620.73 against the
loaded module), so no GPU context existed at all. The live app measured 80 FPS at 1720x1382; a fresh
sandbox at 1920x1080 measured 91-92, and the empty first-run app at 1720x1382 measured 82 with vsync
on and 81-85 with it off (12.2 ms/frame) - the renderer's fill cost, not the terminal's paint or the
effect's. The log said none of that after the engine's three errors, and the status bar printed a
bare `80 FPS` as if the number were the app's. Fixed 2026-11-21: `godot/scenes/ui/renderer_info.gd`
(`RendererInfo`) matches the engine's adapter name against the known CPU rasterizers (llvmpipe,
softpipe, SwiftShader, WARP, Apple's software renderer); `Workspace._ready` writes one `[renderer]`
line naming driver, method, adapter, viewport, device scale, screen refresh, vsync, frame cap and
effect, and one `push_warning` saying the frame rate is CPU-bound and to check the driver (the Linux
kernel-module sentence is gated to Linux); the status bar appends ` · software` to the FPS
(`StatusBar.set_render_note`), and Settings -> About carries a `Renderer:` line. Tests:
`test_renderer_info.gd` (10: marker list, vendor dedupe, record format, scale, vsync labels, the
platform-gated hint, glow capability), `test_status_bar.gd` (the note rides in the FPS segment and
clears), `test_settings_panel.gd` (the About line). Verified on the reporter's session in both
states: on the fallback the startup log named
`opengl3_es (gl_compatibility) on Mesa llvmpipe (LLVM 23.1.5, 256 bits)` at `1920x1080`,
`scale 1.00`, `164.9 Hz`, `vsync on`, `max_fps unlimited`, `effect crt@0`, the warning followed, and
the status bar read `91 FPS · software`; after the reboot the same line read
`vulkan (forward_plus) on NVIDIA GeForce RTX 5070 Ti` at `1720x1382`, `scale 1.00`, `164.9 Hz`,
`vsync on`, `max_fps 165`, no warning was emitted, and the live window measured 155-158 FPS (162-165
in a clean sandbox of the same shape) against 80 on the fallback. Cross-platform review: the
warning's Linux kernel-module sentence is gated to Linux; the record carries the window's screen
scale (Retina/HiDPI) and its current screen's refresh; `Native` FPS and a pane's follow-the-display
cadence read the window's current screen; the 3D graph enables glow only on Forward+ (Mobile ignores
it). Remaining: a window moved to another display keeps the cap resolved at launch (its own row);
WARP is detected by adapter name because GDScript exposes no adapter-type enum; CI is headless, so
the GPU path is verified manually.

Commits: 2c55825, 5d9c4ec

## GUI-116

**Close the loop: recapture the assessment on the 0.8.5 build** - recaptured 2026-11-22 on this tree
(app version 0.8.5; the v0.8.6 bump happens at tag time). 62 states captured in a private sandbox by
the committed harness, each a `SCRIPT ERROR`-free app viewport. The 22-surface re-audit
(`--audit-focus` and `--audit-accessibility` on first-launch, Settings incl.
Reasoning/Concepts/Effects/light, Pane Settings, palette, sidebar, wiki vault and orbital graph,
concept editor, plugin review, workspace trust, 800x500 and 560x340, the empty states and the effect
states) reports `unaccounted=0` on every surface, `unnamed=0`, `escape overlay ... closed=true` on
every overlay, and `reached == focusable` except the concept editor's `reached=55 / focusable=54`
(the closed ring counts its first member once more; `unaccounted=0`). Found and fixed: the zero-pane
first run had no focus owner; the empty guide's hero keycap is now its first stop
(`focus-owner=.../HeroKeycap`; test `test_an_emptied_workspace_shows_the_guide`). The release set is
`v0.8.6_1..5` (desktop window grabs): first launch/Getting Started, light chrome, the orbital graph,
Motion+Effects, and a pinned Tint cue. Harness coverage added: `settings-reasoning`,
`settings-concepts`, `settings-opacity-560x340`, the scheme rows scrolled into frame
(`DarkschemePicker`, with `scroll_to` now using the target's global rect), and the orbital graph's
dust frozen (`cfg_motion=0`); `ui-capture-check` passes on every changed state. Real-window checks:
live resize to 800x500 and 560x340 (geometry confirmed, no clipped controls, no `SCRIPT ERROR`);
window opacity is unavailable on this X11/XWayland session (`settings-opacity-560x340` reads
"unavailable on the X11 display server"), carried to the v0.9 row *The GUI runs under XWayland in a
Wayland session, so window opacity stays unavailable*; scale 2 is deferred with evidence: Godot
4.7.2's X11 `screen_get_scale()` reports 1.00 with `Xft.dpi=192` and with an xsettingsd
`Gdk/WindowScalingFactor 2` file, and the session has no 2x display, so the OS scale factor needs a
2x Windows/macOS run (the v0.9 display rows own it). Windows window behaviour is the new
`Renderer smoke (real display)` in `windows-smoke` (run 45077452383; the default and forced `d3d12`
launches on Microsoft Basic Render Driver/WARP, the forced `opengl3_angle` launch on its D3D11 WARP
adapter; lines in the row *The Windows build has no fallback above native OpenGL 3*). macOS window
behaviour is deferred to the v0.9 row *macOS has no GUT or smoke job, so the platform only
release-builds* (no macOS job executes the app; `release-build.yml` only builds and bundles). The
pulse/particles stills are deferred to the v0.8.7 row *The Effects and Reactive rows never show what
they play* (`PaneEffects.pin_cue` has no particle still and the pulse border shares the focus
accent). The v0.8.6 changelog row consumes the images.

Commits: 8dc74eb, 8c58684, 13c36ee

## GUI-117

**The README and every document it links are readable inside Settings** - closed 2026-11-17: the
About tab is a documentation viewer over a generated bundle. `scripts/build-docs` walks the Markdown
reachable from `README.md` (64 documents: the root guides and the roadmap, changelog and agents
pages, including `SUBPROJECTS.md` through its GitHub blob URL) and packs it into `godot/docs.json`
(1.6 MiB), with a byte-for-byte `--check` in `ci-check`, `scripts/build`, the Docs workflow and the
workflow path filters. The generator strips YAML front matter, unwraps `<details>`/`<summary>`,
drops the README's centered badge header (the renderer shows images as alt text, so it would be a
wall of `Image: ...` lines), and rewrites every internal link - relative, blob URL, or same-page
`#anchor` - to `gpty-doc:<repo path>#<heading text>`, translating the site's slug to the heading
text `MarkdownView.scroll_to_heading` matches. `DocsBundle` validates the bundle and caches it
lazily on the About tab's first visit (never at startup); `DocsViewer` renders one document through
the existing `MarkdownView`/`GptyMarkdown` pipeline, and the renderer's new opt-in docs mode
percent-encodes the `gpty-doc:` halves and refuses a payload over 1024 bytes, so a document can only
ever name a bundled key and the shell is never handed the scheme. Navigation is `NavHistory`: the
trail is capped at 64, a new page truncates the forward tail, and overflow drops the second entry -
never the root - so Back always reaches the README. Back/Forward are `Icons.icon_button` carets with
disabled states; a link outside the bundle raises a toast and leaves the page in place. Keyboard
shortcuts moved to their own Shortcuts tab (the palette row follows), the app and IPC versions share
one `VersionRow`, the repo URL row is gone, and the card grew to `CARD_SIZE` 720x560 with the About
tab's `FILL_TAB_SIZE` 720x640, both clamped to the window. Tests: `test_nav_history.gd` (root
pinning, cap, forward truncation), `test_docs_bundle.gd` (validation, caps, missing bundle),
`test_docs_viewer.gd` (README, link, back, forward, refusal), the doc-mode cases in `markdown.rs`,
`test_gdext_ffi.gd`, `test_settings_about_tab.gd`, the eight-tab fit test, and the resized-card
assertions in `test_small_window.gd`; the `settings-about` capture state is the visual record.

Commits: 1131180

## GUI-118

**A fidelity spike decides the rest of this release: surfaces, mechanisms, budgets** - closed
2026-11-24, no feature code and no committed audit document. (1) *Surface inventory*: 40 surfaces
classified from the scene tree and the 61 `ui_capture` states. Reading and animate no text (none did
when the spike ran - there was no `visible_characters`/`visible_ratio` use anywhere in
`godot/scenes`): the terminal grid, the seven pane bodies, Settings tab content and the modal
dialogs. State loops and chrome, each with an owner: pane transitions, the vault graph and the
badge/keycap (v0.8.6 rows and row 226), the effect layers and reactive cues (the Effects and
Reactive rows), the cursor (a terminal readout), the dividers, scroll hints and search strip (the
new small-chrome row), the focus border, the backdrop, the empty state, the created row and the
Settings tab (rows 228 and 231). The concept graph canvas was the only interactive canvas with no
owner and became its own row. (2) *Probes with numbers*: the per-glyph `RichTextEffect` probe (a
throwaway `-s` harness, deleted) measured on the RTX 5070 Ti at Forward+ with vsync off, 120 frames
per configuration, median of three runs: a 22-character title at 0.233 ms plain against 0.250 ms
with a per-glyph wave (+0.017 ms, 48 effect calls a frame) and a 2000-character note at 0.582 ms
against 2.576 ms (+1.99 ms, 3564 calls a frame). A note fails the 1.60 ms 90x30 full-repaint budget
by a quarter, so `visible_characters` stays the ceiling for text; the title is cheap but rejected
anyway, because no surface in this release animates text being read and the Getting Started
typewriter (row 227) is the one text arrival. The probe also caught that `[wave]` is a built-in
label tag, so a custom effect must use a non-built-in identifier (`gpty_wave` worked). The
reduced-buffer CRT probe was dropped: its owner row closed in v0.8.6 with the renderer decision
(Forward+ 667 MB warm against 310 on Compatibility, `testing.md` budget table) and `crt` is static,
so the per-entry effect budget it would have fed is the ambient-effect-table row's contract
(`effect_bench` per entry). The pooled-particles probe was dropped as moot: Reactive Environments
shipped the pooled cue, and its Motion hole is row 226's amended contract. Two rows came out of this
- the small chrome arrivals and the concept graph canvas, both below - plus row 226's grain/cue
amendment, folded there rather than duplicated. Rejects, explicit: the planar vault canvas (a
deliberate static presentation; its family is the v0.8.6 orbital row), cursor blink (a readout with
its own setting, not chrome motion), a whole-window backdrop (the gradient row is scheme-scoped; a
window backdrop is a different design with no ask) and pane-frame depth (panes stay flat; elevation
is for floating surfaces).

Commits: 8d87221, 0e6d593

## GUI-119

**Every animation obeys the Motion setting, including the badge and the keycap** - closed
2026-11-24: every animated surface now reads the one policy. `PaneTransitions` and `VaultGraph3D`
already did; the badge, the guide's keycap clock, the toast, the animated effect field, the reactive
cue, the Getting Started reveal, the arrivals and the focus border now do too. `UiMotion` grew the
duration conversion (`duration_s`, zero at Off) and the one arrival helper (`arrive`, with
`pin_arrival` for captures); `agent_badge` and `shortcut_guide` and `pane_effects` connect
`SettingsManager.settings_changed`, so a save applies without a restart. Off behaviour, per
consumer: the badge stops `_process` and keeps the phase-0 silhouette (the frame a capture pins);
the guide freezes at step 0/phase 0 and shows every character; the toast is reduced to its hold (no
fades); the grain field stops at phase 0 and renders that one frame; a reactive cue is one still 2
px border in its cue's tone for 400 ms (`CUE_STILL_MS`), with no fade, no particle pool and the same
334 ms rate limit; the focus sweep and every arrival draw their final frame in one frame. Subtle and
Full share these declarations (only overshoot differs), so there is no separate amplitude level -
the helper reports the duration and the Off switch. Tests:
`test_motion_off_stops_the_clock_at_the_pinned_frame`, `test_motion_off_is_the_pinned_frame`,
`test_a_motion_change_starts_or_stops_the_clock`, `test_motion_off_is_a_hold_without_fades`,
`test_motion_off_stops_the_animated_clock`, `test_a_cue_at_motion_off_is_a_still_border`,
`test_a_cue_at_motion_off_keeps_the_rate_limit`, plus the helper contract in `test_ui_motion.gd`.

Commits: 46b68e9, 1c63034, 8c58684, e2eeaa9, 0e6d593

## GUI-120

**Getting Started types each shortcut step in** - closed 2026-11-24: `ShortcutGuide` reveals each
step's `_hero_caption` and `_hero_chord` with `Label.visible_characters` at 36 characters/s
(`REVEAL_CPS`) under a 0.6 s ceiling (`REVEAL_CEIL_S`), and the surface's own title
(`Getting Started`) types once on its first show. The text is always set in full first, so a reveal
clips drawing and never reflows: a test asserts the label's rect is identical before and after.
Reveals are independent groups (the title and the hero step), because a step change replaces only
the hero's; hiding the guide completes every running group, so it cannot come back part-typed; and
`_activate_step` completes the reveal before it emits, so a click on the keycap mid-word spawns
exactly once. `Motion.off` shows every character on frame 0 (the group is never created), and
`pin_animation(reveal := 1.0)` completes the title and pins the hero step at `reveal` (0.5 for the
`guide-typewriter` capture) with the clock stopped. The atlas cards stay untyped. Tests:
`test_each_step_types_in_and_completes`, `test_the_reveal_finishes_by_its_deadline`,
`test_a_click_mid_reveal_spawns_exactly_once`,
`test_motion_off_shows_every_character_at_frame_zero`,
`test_the_title_types_once_and_is_not_frozen`, `test_pin_animation_completes_the_reveal`; the
existing hero and clock tests still pass.

Commits: 1c63034, 0e6d593

## GUI-121

**New chrome arrives instead of snapping** - closed 2026-11-24: `UiMotion.arrive` is the one arrival
- a fade from the surface's own alpha to it, 120 ms (`ARRIVAL_MS`), with a 4 px rise only at Full
(`ARRIVAL_RISE_PX`) and a 30 ms stagger capped at three rows (`ARRIVAL_STAGGER_MS`,
`ARRIVAL_MAX_STAGGERED`). Three surfaces use it: the shared empty state (`PaneBody.empty_state`
fades its host once, when the pane builds it; a build outside the tree arrives final rather than
frozen transparent), a created pane row in the sidebar (120 ms, and only when the previous list is
still a prefix of the new one and at most three rows were appended - a first render, a renumber, a
switch and a restore fade nothing), and the incoming Settings section (80 ms, `TAB_ARRIVAL_MS`, no
movement) connected to `TabContainer.tab_changed` after the tabs are built, so the deep links
(`open_commands`, `open_shortcuts`) share it. Nothing else animates: a renumber, a reorder, an
action swap, a palette filter keystroke, streaming Reasoning and the terminal grid are updates, and
`Motion.off` (or a node built outside the tree) draws every surface at its final state in one frame
with no tween and no meta. `pin_arrival` freezes a staged arrival mid-fade for a capture. Tests:
`test_the_empty_state_fades_in_at_its_final_rect`, `test_motion_off_draws_the_empty_state_final`,
`test_full_records_the_four_pixel_rise`, `test_a_spawn_fades_only_the_created_row`,
`test_a_renumber_creates_no_arrival`, `test_a_list_replacement_fades_no_rows`,
`test_motion_off_inserts_the_row_final`, `test_a_tab_switch_fades_the_incoming_tab_only`,
`test_motion_off_switches_tabs_in_one_frame`, `test_open_commands_fades_the_commands_tab`,
`test_a_filter_keystroke_creates_no_arrival`, plus the helper contract in `test_ui_motion.gd`.

Commits: 1c63034, 0e6d593

## GUI-122

**The terminal background can carry a two-stop gradient from its scheme** - closed 2026-11-24:
`Settings → Appearance → Terminal backdrop` (`cfg_backdrop`, Flat/Gradient, default Flat; the
`settings.json` key `backdrop`, clamped on load) broadcasts through `apply_to_terminal` like the
effect. The pane paints one per-vertex-coloured quad from `_draw_ground` (`UiTokens.backdrop_stop`:
6 % of the way toward white for a dark ground, toward black for a light one; the stop at the top,
the exact scheme background at the bottom), so the GPU interpolates the ramp with no shader, texture
or translucency; default-background cell runs skip their band through `_backdrop_covers_background`,
while ANSI, inverse and selection paint exactly as before. An ambient effect paints its own ground,
so the gradient draws only while no effect is active (logged in `future.md`). Contrast: the shipped
default foreground measures 16.67:1 on the flat black ground and 15.22:1 on its `#0f0f0f` stop; the
16 ANSI entries are unchanged because a non-default run still paints its own rect (the lowest
against the flat ground: black 1.00, blue 2.23, red 3.60, bright blue 4.43, magenta 4.48). Tests:
`test_terminal_repaint.gd`'s `test_a_gradient_backdrop_skips_only_the_default_background_runs`,
`test_the_backdrop_top_stop_is_the_ground_six_percent_toward_the_far_end`,
`test_the_default_foreground_clears_45_to_1_against_both_stops` and
`test_a_backdrop_change_repaints_the_grid_once`;
`test_settings_manager.gd::test_the_backdrop_survives_a_restart_and_clamps`;
`test_settings_panel.gd::test_the_backdrop_picker_writes_the_setting`;
`test_workspace_settings.gd::test_a_settings_save_broadcasts_the_backdrop_to_every_terminal`.
`draw_bench` at 90x30 on the RTX 5070 Ti (median of 3): `forced_us` 1675.8 flat / 1691.1 gradient
and `draw_us` 1432.1 / 1451.6 - one extra fill inside the run-to-run spread, no per-cell work.
Screenshot ([captures](../v0.8.md#screenshots)): *The scheme ground can fall off*.

Commits: 46b68e9, 9a5aa53

## GUI-123

**Floating surfaces sit above the page: contact shadow and a light edge** - closed 2026-11-24:
`UiPalette` gained `SHADOW` (`#000000` at 0.30 in dark; the neutral slate `#2a2e38` at 0.16 in
light, so it does not read as dirt) and `UiTheme` one rule - the `FLOATING_PANEL` `Panel` type
variation: an 8 px shadow at offset (2, 4), one light direction, plus a 1 px inner top rim in
`SURFACE_RAISED`. The command palette, Settings card, Pane Settings card and concept-graph card set
the variation; the toast variations keep their severity border and carry the same shadow, and
`AcceptDialog`'s panel is the elevated box. A borderless embedded dialog draws its panel inside its
own sub-viewport, so that halo is clipped at the window rect (the `file-dialog` image shows the
surface and rim only; queued in `future.md`); the palette, cards and toasts are ordinary Controls
and cast it. No blur shader and no per-pixel work: a `StyleBoxFlat` shadow is one item. The contrast
pairs are unchanged. Tests: `test_ui_theme.gd`'s `test_a_floating_panel_gets_the_elevation_box` and
`test_the_toast_variations_carry_the_shadow_token`, the shadow assertions in
`test_a_confirmation_dialog_resolves_the_accept_dialog_panel`,
`test_ui_palette.gd::test_the_light_shadow_is_neutral_not_black`,
`test_toast_overlay.gd::test_a_toast_is_an_opaque_padded_panel` and
`test_pane_settings_panel.gd::test_the_floating_cards_wear_the_elevation_variation`. Screenshot
([captures](../v0.8.md#screenshots)): *A floating card sits above the page*.

Commits: 46b68e9, 9a5aa53

## GUI-124

**A focus change is visible: the new pane's border sweeps in** - closed 2026-11-24: the border is
drawn in the pane's overlay layer from `_focus_alpha`, so a focus gain fades it in over 140 ms
(`FOCUS_SWEEP_S`) and a loss fades it out through `UiMotion.duration_s` (Off writes the final alpha
and repaints once). The grid, text and every rect never move: the border is drawn, not laid out, and
a focus change leaves the tile wrapper's rect and the body's size identical. A second change kills
the running tween and starts from the alpha on screen, so an interrupted sweep leaves exactly one
tween; `pin_focus_sweep(alpha)` holds a mid-sweep frame and ignores later focus changes for the
`focus-sweep` capture. The row also closed a real hole: before this, `focus_entered` triggered no
overlay repaint at all, so the border only appeared at the next cursor blink or output repaint.
Tests: `test_a_focus_gain_sweeps_from_transparent_to_the_steady_border`,
`test_motion_off_draws_the_focus_border_in_one_frame`, `test_an_interrupted_sweep_leaves_one_tween`,
`test_a_pinned_sweep_is_stable`.

Commits: 46b68e9, 0e6d593

## GUI-125

**The Settings card is a navigation rail with a content column and a live sample** - found
2026-11-21 from daily use: the card is one `TabContainer` (`settings_panel.gd:127`) with eight tabs,
and the v0.8.6 floor fix leaves the bar at 497 of 512 px, so a ninth section overflows behind the
engine's arrows; the tab labels carry 6 px horizontal and 4 px vertical content margins with
`side_margin=0` (`ui_theme.gd:323-333`), which reads as unpadded, while the content's inner margin
is `SPACE_LG` (8 px, `_create_tab`). The strip also has no room for the previews the next two rows
need. Fix: replace the `TabContainer` with an `HBoxContainer` - a left navigation rail (a
`ScrollContainer` of focusable section buttons, the selected row = the current section) and a right
content column, both independently scrollable; each section keeps its own scroll offset, its
per-section Reset sits in a sticky header, and the rail remembers the last section for the run. Give
the content 16 px inner padding and the rail rows 8-12 px; at the design size the preview column is
about 220-240 px (the card's design width grows to fit it, e.g. 960x640, while the window clamp
still wins below that), and at the 560x340 floor the rail narrows and the preview stacks or hides,
never overflows horizontally; a section switch stays instant (the update rule in *New chrome arrives
instead of snapping*). Add a shared preview surface on the right for sections that have one: one
sample pane mock carrying the active scheme, text and inverse/underline cells, run through
`PaneTransitions` for a transition or `PaneEffects` for a shader, plus a sidebar strip when the
effect scope includes it; the scheme, Motion and Effects pickers all preview through this one sample
(never a second mock), the caption names the selected effect/transition and its static-or-30-Hz
rate, and it is hidden and paused on other sections and when the panel is hidden; it is the only
preview implementation the next two rows drive. Keep the public deep links (`open_commands`,
`open_shortcuts`, the capture states' section names) working through a section-name map, and put a
small Back/Forward trail over visited sections (the About viewer's `NavHistory` pattern) beside the
title, so a search jump and a manual section pick share one history; Up/Down/Enter move the rail and
the first content control follows; every rail row and the sample carry accessible names, and the
sample's text description names the selected effect/transition and scope. Tests: section switching
and deep links, per-section scroll/reset, the 560x340 floor, preview hidden/paused, the keyboard
ring; update `test_settings_panel.gd` (62 tests), `test_small_window.gd`, the `settings*`
`ui_capture` states (a rail state and a preview state), and the capture/accessibility audits. This
replaces the fixed tab-size row and is the prerequisite for the two preview rows below. closed
2026-11-25: the TabContainer is gone; the card is the rail/content/preview shell at 960x640, each
section keeps its own scroll and sticky Reset, Back/Forward walks one history, and the card fits the
560x340 floor; tests `test_settings_panel.gd`, `test_small_window.gd`, the deep-link and
accessibility audits; capture `settings-rail`.

Commits: eda4f35, 60cbace, bd46205

## GUI-126

**The Motion pickers name their animations but never show them** - `Settings → Appearance → Motion`
offers four animated create/close entries and two swap ones by name, and nothing plays until the
next pane spawn, close or position swap, so "Pop" against "Fade and Scale" and "Move" against
"Crossfade" is a guess. Fix: a Play button beside each picker (and a replay when the picker changes)
plays the selected entry on the rail row's shared preview surface - a scratch `Control` carrying the
pane chrome's background, run through `PaneTransitions.create`/`close` (a swap entry plays on two
samples through `swap`), so the runner stays the only animation implementation and the preview reads
the live Motion level and the same stored params; `Off` draws the final frame, and the sample is
never a pane body. Tests: the button plays the registry entry the picker names, a property edit
reaches the next preview without a save, and `Off` leaves the sample at its final state. closed
2026-11-25: each picker's Play replays the selected registry entry on the shared sample, a property
edit reaches the next preview without a save, and Off writes the final frame; tests
`test_settings_preview.gd`; capture `settings-preview-motion`.

Commits: b4a0f56, eda4f35, bd46205

## GUI-127

**The Effects and Reactive rows never show what they play** - `Settings → Appearance → Effects`
offers two ambient effects and an intensity, and each reactive rule picks Tint, Pulse or Particles,
yet neither picker draws anything: a user choosing Film grain while the intensity is Off sees
nothing, and Tint against Pulse is a guess until a concept happens to fire. Fix: the rail row's
shared preview surface plays the selected effect at the selected intensity on a sample carrying a
terminal pane's ground, in the selected scope (with a sidebar strip when the scope includes it),
through `PaneEffects` so the preview is the shipped implementation rather than a second one; a Play
button replays it, and each reactive row gets a Test button that plays its cue on the same sample
under the same 334 ms rate limit; the effect preview at Off draws the plain ground, the cue previews
pin their final frame (as `effect-cue` does), and both previews are new `ui-capture` states so the
images repeat. Tests: a preview adds the same effect layer a pane would, `Off` leaves the sample at
its ground, and a Test press is rate-limited exactly like a concept fire. closed 2026-11-25: Play
and Test run the shipped EffectSurface on the sample, the Scope picker and the 334 ms rate limit are
live, and Off leaves the ground; tests `test_settings_preview.gd`; captures
`settings-preview-effect`.

Commits: a287210, eda4f35, bd46205

## GUI-128

**The ambient effects stop at the pane edge, so the sidebar cannot carry one** - found 2026-11-21
from daily use: `UiEffects.AMBIENT` is configured only by `PaneEffects` on each terminal body, the
sidebar's ground is the workspace's `_sidebar_bg` `ColorRect`, and no effect host sits under the
sidebar rows, so the Effects picker changes terminal panes alone. The requested scope is panes,
panes + sidebar, or sidebar only. Fix: a closed `cfg_effect_scope` (panes, both, sidebar) in
Settings → Appearance → Effects, sanitized and reset with the section; the sidebar gets a reusable
effect host - the configure/paint/clock half of `PaneEffects` extracted, or a `PaneEffects` mounted
on a sidebar ground layer - below the rows and above its ground, using the sidebar's colour, with
text and row surfaces opaque. The scope gates the pane layer as well, so "sidebar only" draws no
global effect in panes even when a pane's own picker names one; the pane settings panel says the
global scope excludes panes instead of silently drawing nothing. In icons mode the host follows the
rail, while the flyout is a raised card with its own opaque surface. Static effects redraw only when
the sidebar changes; the 30 Hz half-res grain is the only continuous cost; measure both at sidebar
size with `effect_bench`, record the run in the v0.9.0 budget table, pin the phase for captures, and
keep the existing contrast pairs (the effect is below text, never on it). Tests: the scope
vocabulary and reset, the sidebar host on each value, panes off/on, Off frees both layers, contrast
unchanged, and `settings-sidebar-effect` / `effect-sidebar` / `sidebar-icons-effect` captures.
closed 2026-11-25: Scope Both/Panes/Sidebar only, the sidebar host at 180 and 48 px, the effect
below the text with the row surfaces opaque, and the measurements under the floor; tests
`test_ui_effects.gd`, `test_settings_manager.gd`, `test_pane_effects.gd` and
`test_sidebar_modes.gd`.

Commits: eda4f35, 60cbace, bd46205

## GUI-129

**The ambient effect table is two entries, so the picker is a coin toss** - found 2026-11-21 from
daily use: `UiEffects.AMBIENT_IDS` is `["crt", "grain"]` and
`PaneTypes.TERMINAL_SETTINGS["effect"]["values"]` mirrors it; the transition library already grew to
five entries through a registry (row *The transition library grows past fade and move*), while the
effect table has no such path. Fix: add at least three closed entries behind `preload` constants - a
cheap static one (e.g. vignette or halftone), an animated field at 30 Hz (e.g. aurora or plasma),
and one more (e.g. dither or noise) - each with a label, hint, animated flag, rate at most 30 Hz,
and a measured `budget_ms_1080p` / `budget_ms_4k` on the bake-off GPU (the v0.9.0 row *The effect
frame budgets are borrowed from another shader* is the measurement precedent, and the measured run
is recorded in that release's budget table); the hint names whether the entry is static or animated
at 30 Hz, and a static effect declares 0 and redraws only on change. Keep the table closed: a
profile, settings file or plugin names an id, never a path. The picker, the pane schema test, the
preview surface, the sidebar scope and the capture states all read the table, so a new entry needs a
shader file, a table row, budgets and a pinned capture; no new settings code. Tests: the id list
equals the schema, every entry preloads a Shader and declares its budget and rate, the preview plays
each entry, and `effect_bench` runs each on both renderers. closed 2026-11-25: the five-entry table
(off, grain, aurora, vignette, dither) is closed, every static entry preloads a Shader and declares
its budget and rate, and the bench passes on both renderers; tests `test_ui_effects.gd`; captures
`effect-vignette`, `effect-dither`.

Commits: eda4f35, 60cbace, bd46205

## GUI-130

**The sidebar has two positions, not three: open or gone** - found 2026-11-21 from daily use:
`Sidebar.WIDTH` is 180 and `COLLAPSED_WIDTH` is 20 (`sidebar.gd:27-28`); `_toggle_sidebar` flips the
whole column and the 20 px state holds one `SidebarCollapsedBtn`, so every section is unreachable
until the sidebar is reopened. The requested third position is an icon rail - one column of icon
buttons (about 44-48 px) that keeps the window-mode menu, Add Pane, Search, Settings, Feedback,
Workspaces, Profiles and Panes reachable, with a targeted flyout for the section whose icon was
pressed. Fix: a closed `cfg_sidebar_mode` (expanded, icons, collapsed), persisted and reset like the
other chrome settings; the header's collapse control becomes a three-state control and
`Ctrl+Shift+B` cycles expanded -> icons -> collapsed, each mode naming itself in its tooltip and
accessible name. The icon rail reuses the existing section content rather than a second copy:
Workspaces/Profiles/Panes open one flyout anchored to the rail, Add Pane opens the existing type
grid, Search/Settings/Feedback act as today, and the window-mode dropdown becomes a glyph button
with the same popup. The flyout is an overlay beside the rail: it does not reflow the grid, closes
on selection/click-outside/Escape and after a workspace/pane action, carries the section header and
its Help, clamps at the 560x340 floor, and keeps its content live (the pane list updates while
open). Keyboard: the rail is one focus ring, the flyout takes focus and returns it on close; every
icon is named and tooltipped. The collapsed 20 px state and the existing per-section folds
(`sidebar_folded`) stay exactly as today. Icons mode saves about 132 px at the 180 px default;
measure the flyout's overdraw and capture `sidebar-expanded`, `sidebar-icons` (Workspaces and Panes
flyouts open), `sidebar-icons-560x340` and `sidebar-collapsed`. Tests: mode persistence/reset and
the cycle, each icon opens the right flyout or direct action, selection closes it,
click-outside/Escape, the grid rect is unchanged while the flyout is open, the pane list stays live,
the 560 floor, focus ring and audits; the expanded and collapsed modes' existing tests stay green.
closed 2026-11-25: the three modes cycle from the header arrow, the chord and the System row; the 48
px rail opens one lazily filled section flyout (selection, click-outside, Escape), the 20 px handle
expands the column, and the grid rect is unchanged while the flyout is open; tests
`test_sidebar_modes.gd`; captures `sidebar-expanded`, `sidebar-icons`, `sidebar-icons-panes`,
`sidebar-icons-560x340`, `sidebar-collapsed`.

Commits: 60cbace, bd46205

## GUI-131

**The finish pass is captured** - the three motion states shipped with their rows and are on the
[v0.8 page](../v0.8.md#screenshots) (`focus-sweep`, `guide-typewriter`, `chrome-arrival`,
2026-11-24). The backdrop and elevation states shipped with their rows (`backdrop-gradient`,
`elevation`, 2026-11-24) and are on the [v0.8 page](../v0.8.md#screenshots). What remains: add
staged states to `godot/tests/bench/ui_capture.gd` for `settings-rail`, `settings-preview-motion`,
`settings-preview-effect`, `settings-sidebar-effect`, `sidebar-icons-effect`, `sidebar-expanded`,
`sidebar-icons`, `sidebar-icons-560x340` and `sidebar-collapsed`, and save `issue-v0.8.7-<slug>.png`
under `docs/static/images/`, each listed under Screenshots on the [v0.8
page](../v0.8.md#screenshots) with a caption that names the row(s) and every numbered box. Pin every
animation a capture depends on (`pin_animation()`, `pin_arrival`, `pin_focus_sweep`, or the Motion
setting's `off` frame) and open the icon flyout on a named section, so two runs are pixel-identical;
`scripts/ui-capture-check` proves it. closed 2026-11-25: the 13 states were captured
(`settings-rail`, `settings-preview-motion`, `settings-preview-effect`, `settings-sidebar-effect`,
`sidebar-icons-effect`, `sidebar-expanded`, `sidebar-icons`, `sidebar-icons-panes`,
`sidebar-icons-560x340`, `sidebar-collapsed`, plus `effect-sidebar`, `effect-vignette` and
`effect-dither`), `ui-capture-check` passed for `settings-preview-motion` and for the whole state
list, the three annotated images and the captions are on the [v0.8 page](../v0.8.md#screenshots),
and the finish pass is closed.

Commits: 46b68e9, 1c63034, 8c58684, eda4f35, 60cbace, 0e6d593, 9a5aa53, bd46205

## GUI-132

**The small chrome state changes still snap** - closed 2026-11-25: all six surfaces ramp through
`UiMotion`, and `UiMotion` gained its mirror - `dismiss(node, ms, finished)` fades to 0, hides, and
keeps the settled colour in the existing `ARRIVAL_META` record so a later arrival returns to full.
An interrupted ramp now resumes from the alpha on screen, a settled surface fades again, and the
previous tween is killed before the record is replaced (the old `arrive` re-targeted a mid-fade
alpha). The search strip is `_show_search_strip`/`_hide_search_strip` (100 ms, `SEARCH_STRIP_MS`),
and the strip's hide callback returns the up chevron because the strip owns that corner while
`visible`. The chevrons ramp in `ScrollHints._set_chevron` (100 ms, `CHEVRON_MS`), with `_shown` so
a bar's frequent `changed` cannot restart a ramp. The scrollback indicator is
`_indicator_alpha`/`_indicator_target`/`_indicator_text` (100 ms, `INDICATOR_S`), driven from
`_sync_scroll_hints`, drawn from its alpha, and reading the cached text so a fade-out never flashes
`0/N`; its row follows `_search_strip.visible`. The divider band is a per-slot `_hover_alpha` (100
ms, `HOVER_MS`) drawn as `Color(accent, accent.a * alpha)`, cleared instantly when a press starts a
drag and zeroed when `refresh` moves a slot to a different segment. `UiMotion.appended_indices` and
`stagger_ms` are now the one append rule and stagger for the pane, workspace and profile lists
(`_render_workspaces(created)`/`_render_profiles(created)`; a first render, a rename, a replacement,
a switch and >3 new rows create nothing). The sidebar shell keeps the instantaneous width and grid
reflow and then fades for 80 ms (`_on_sidebar_toggled`); launch never fades because the initial
`set_mode` runs before `mode_changed` is wired. At Off every path writes the final frame, no rect
moves, and a search keystroke creates no arrival. Tests: `test_a_dismiss_fades_out_then_hides`,
`test_off_dismisses_in_one_frame`, `test_an_arrival_after_a_dismiss_is_visible_again`,
`test_an_interrupted_arrival_keeps_its_settled_target`, `test_only_a_prefix_append_is_an_arrival`,
`test_stagger_is_full_only`; `test_a_chevron_fades_in_and_out`,
`test_off_flips_a_chevron_in_one_sync` (the rest of `test_scroll_hints.gd` runs at Off, so its
visibility contract is the one-frame one); `test_the_search_strip_fades_in_and_out`,
`test_a_search_keystroke_creates_no_arrival`, `test_the_scrollback_indicator_ramps`,
`test_the_scrollback_indicator_is_static_at_off`; `test_the_hover_band_ramps_and_off_is_instant`;
`test_an_appended_workspace_fades_only_the_created_row`,
`test_an_appended_profile_fades_only_the_created_row`,
`test_motion_off_inserts_the_workspace_row_final`; `test_a_mode_change_fades_the_shell`.
`docs/content/docs/agents/gdscript.md`'s ScrollHints bullet records the ramp. Screenshot
([captures](../v0.8.md#screenshots)): *The small chrome arrivals*.

Commits: 0e6d593, 1d9af4b

## GUI-133

**The concept graph canvas has no fidelity owner** - closed 2026-11-25. The selected node's ring is
the theme's (`ui_theme.gd`): `GraphNode/panel_selected` is a 2 px accent border and
`titlebar_selected` has top+left+right with no bottom, so the title bar and body draw one outline
instead of two; both reuse `_graph_node_box`'s content margins, so selecting a node never resizes
it, and `_graph_node_selected_box` reads `UiPalette.active()` per build (the light set gets the
light accent). The node state is *selection*: `GraphNode` is `FOCUS_ACCESSIBILITY`, not a Tab stop,
so the engine's own `panel_selected`/`titlebar_selected` switch is the focus state it exposes; the
`GraphEdit`, which holds the keyboard, gets `GraphEdit/panel_focus` - a 1 px accent box replacing
the engine's stock 2 px blue outline. Frame All is a new toolbar button: `_frame_target` fits
`_content_bounds` into the canvas minus 2*`FRAME_PAD_PX` (zoom clamped to
`zoom_min`..min(`zoom_max`, 1)) and centres it with `scroll = center * zoom - size/2`;
`_apply_frame` writes zoom then scroll; `_frame_all` eases the pair for 0.12 s through
`UiMotion.duration_s(FRAME_S)` (one frame at Off) and ends with `_apply_frame(target)`, so both
paths land on the same transform. A second frame, a canvas wheel/press/drag, a node drag, Tidy, a
rebuild and close kill the one tween, and nothing runs per frame when idle. The row's "GraphEdit
jumps its scroll and zoom" was narrowed: no code moved the canvas before this, and the engine's own
wheel pan/zoom is direct manipulation that must not be eased, so Frame All is the jump the ease
serves. The old "Fit" button is "Tidy" (it re-rows nodes in rule order), so it no longer reads as
framing. Tests: `test_the_selected_graph_node_carries_an_accent_ring` (both boxes, the canvas focus
box and the light rebuild); `test_selecting_a_node_moves_nothing`,
`test_a_selected_node_resolves_the_accent_ring`, `test_frame_all_fits_every_node`,
`test_frame_all_eases_and_off_lands_on_the_same_transform`,
`test_an_interrupted_frame_all_leaves_one_tween`. Screenshot ([captures](../v0.8.md#screenshots)):
*The concept graph focus ring*.

Commits: 0e6d593, 1d9af4b

## GUI-134

**Add places the draft node half a viewport from the click** - found 2026-11-25 while adding Frame
All: GraphEdit 4.7 lays a node out at `position_offset * zoom - scroll_offset` (engine
`graph_edit.cpp`, `_update_scroll_offset`), so the graph point under a control-local point is
`(local + scroll_offset) / zoom`; `_graph_position_for` returned
`(local - size/2)/zoom + scroll_offset`, which on an unscrolled canvas put a toolbar "Add Trigger"
at `-size/2` (off the canvas) and a right-click Add half a viewport up-left of the click. Measured
before the fix: at zoom 0.5, a local (300, 200) placed the node at (-372, -41.5). Cause
(`wrong-constant`). Fix: the engine formula. Tests: `test_a_draft_node_lands_under_the_pointer` (the
node's local position equals the point it was placed at, and a toolbar draft lands at the canvas
centre).

Commits: 1d9af4b

## GUI-135

**A window moved to another display keeps the frame cap resolved at launch** - found 2026-11-21
while reviewing the Windows/macOS paths: `Workspace._apply_fps_setting` and
`TerminalPane.refresh_sync_interval` read `DisplayServer.window_get_current_screen()` when the
setting is applied, so they are right at launch, but moving the window to a display with a different
refresh rate does not re-run either. With `max_fps = Native` the engine cap is the old screen's
rate: with vsync on, 165 on a 60 Hz display is harmless because the compositor holds 60, while 60 on
a 165 Hz display caps it at 60 until a settings change or restart; a terminal's follow-the-display
cadence keeps the old interval in both directions. Fix: notice the current screen changing (a
low-frequency timer, or a window event where the platform raises one) and re-apply `Engine.max_fps`
plus each live terminal's `refresh_sync_interval`; an explicit cap is left alone. Tests: a seam that
supplies the screen and its rate, asserting the cap and cadence follow a move and an explicit cap
does not; no per-frame polling.

## GUI-136

**The empty-workspace guide drops its two redundant headings and its keycap answers a real click** - reported
2026-11-26 from use; code: `ShortcutGuide._build_ui` hardcodes `Title = "Getting Started"` and
`AtlasHeading = "Keyboard shortcuts"` (`godot/scenes/ui/shortcut_guide.gd:354-430`), and
`configure(title)` only writes the first (`:127-132`). Both labels are implied by the surface:
remove them, set the guide's own accessible name to the removed title, and delete the now-dead
`title` parameter and its call sites (`godot/scenes/terminal/workspace.gd:518-524`,
`test_shortcut_guide.gd:42-46`). The keycap's handler is already wired (`_activate_step` →
`new_pane_requested` → `_spawn_pane`, `shortcut_guide.gd:278-289`, `workspace.gd:534`), but the
tests only emit `pressed` directly (`test_shortcut_guide.gd:61-76`,
`test_workspace_settings.gd:1229`), so reproduce the reported pointer failure first with the capture
harness's real press (`godot/tests/bench/ui_capture.gd:1529-1545`); if the press never reaches the
button, fix the control that swallows it (candidates: the `MOUSE_FILTER_IGNORE` hero containers at
`shortcut_guide.gd:365-395`, the empty-state `ScrollContainer` drag, or a focus steal), then add a
GUT test that delivers the real click and asserts the displayed type spawns. Update the two title
assertions (`test_shortcut_guide.gd:10,58`, `test_workspace_settings.gd:1215`).

## GUI-137

**The About page and every Markdown pane render headings and fenced blocks through the one renderer** - reported
2026-11-26: the About README shows `###` literally and a fenced block as running text. There is one
implementation - `MarkdownView` (`godot/scenes/ui/markdown_view.gd`) over `GptyMarkdown`
(`crates/gpty-gdext/src/markdown.rs`); DocsViewer, Inspector, Reasoning, Code Viewer and Wiki all
instantiate it, so a second parser is not the fix. Reproduce on a dev build first: if `_renderer` is
null the view falls back to `_pending_markdown.replace("[", "[lb]")` (`markdown_view.gd:268-272`)
and silently shows the source - replace that fail-soft with a visible notice and a `push_error`; if
the render is present, fenced blocks emit the inline `[code]` tag
(`crates/gpty-gdext/src/markdown.rs:228-232` for spans, `:490-503` for blocks), so use `[codeblock]`
for a fence and theme a mono font plus a code background in `UiTheme`; level-1 headings already emit
`[font_size=26]` (`:586-594`) and need a visible size/rule rather than a raw hash. Add a
`test_docs_viewer.gd` fixture containing `# H1`, `### H3` and a fenced block, and assert
`get_parsed_text()` contains the heading and code text without `# ` or backticks. Syntax
highlighting and footnotes stay in v0.12's **Preview depth** row.

## GUI-138

**The terminal search strip closes from its own right-hand button** - the strip is `ScopeBtn`,
`SearchBar`, `SearchCount`, `SearchPrev`, `SearchNext`
(`godot/scenes/terminal/terminal_pane.gd:614-680`); dismissing it needs Escape only while the field
has focus (`:2151-2153`) or re-clicking the sidebar Search, so a pointer user has no close
affordance. Add a right-most `SearchClose` `Button` (`Icons.CLOSE`, accessible name "Close search",
tooltip "Close search (Escape)", `FOCUS_ALL`) wired to `_close_search()` (`:2193-2202`, which
already returns focus to the pane) and keep it inside the strip's top-right corner that
`_sync_scroll_hints` suppresses while search is open. Test: open search, press the button, assert
the strip hides, `_search_visible` is false, focus is on the pane, and Tab reaches the button.

## GUI-139

**One widget factory builds every button, and the sidebar and Settings share one elevated treatment** - measured:
111 `Button.new()` sites across 21 files; the sidebar uses the default box (`SURFACE_RAISED` plus a
1 px `BORDER`, `godot/scenes/ui/ui_theme.gd:300-312`), the Settings rail uses `RAIL_ROW` whose
pressed state is the command palette's `_selected_row_box` with a 2 px accent leading edge
(`ui_theme.gd:188-197`, `:316-323`), and pane chrome uses `ICON_BUTTON` (`:271-276`). Add
`godot/scenes/ui/ui_widgets.gd` (`class_name UiWidgets`) as the one constructor set:
`button(text, icon, variant)`, `icon_button`, `rail_button`, `toggle`, `radio_group`, `option`,
`setting_field`, `group_card`. One button style: `SURFACE_RAISED` plus a 1 px `BORDER` at rest, the
accent wash and accent border on hover, a 2 px contact shadow at rest, and a pressed state that
drops the label 1 px and removes the shadow - the visual click. `RAIL_ROW`'s leading edge is retired
for buttons (the palette's `SELECTED_ROW` cursor keeps it). Migrate every `Button.new()` site,
delete the per-site styleboxes, and make `Icons.icon_button` delegate to the factory. Test: a
scene-tree walk asserts every `Button` under `godot/scenes` carries the factory's meta/theme;
captures `settings-rail` and `sidebar` show one treatment.

## GUI-140

**Every control, row and card is built by `UiWidgets`, and a gate keeps controls there** - the
factory is only half the rule while `OptionButton.new()`, `CheckBox.new()`, `CheckButton.new()`,
`LineEdit.new()` and `SpinBox.new()` stay scattered (`settings_panel.gd` alone has 39 `Button.new()`
and 29 option/check/spin sites). Add the remaining builders (`toggle`, `radio_group`, `option`,
`text_field`, `number_field`, `section_header`, `group_card`, `setting_field`) and migrate every
construction site under `godot/scenes/{ui,terminal,panes}`; `option` is only for lists longer than
four or numeric presets, binary settings use `toggle`, and a 2-4 choice enum uses a horizontal
`radio_group`. Add `scripts/check-ui-widgets` in the `check-theme-tokens` shape (reads only, exits 1
on a violation) that fails a control constructor outside `ui_widgets.gd` unless the line carries
`# widgets-ok: <why>`, and call it from `scripts/ci-check` beside the theme-token step. Test: the
gate against a violating and a clean fixture, a radio group emitting its selected index, and a
master toggle disabling its children.

## GUI-141

**Settings rows are one aligned grid, two short fields per band** - every `_add_*` builds its own
`HBox` label+control, so the control's x differs per row (`settings_panel.gd:711-760`,
`:1493-1700`); only Shortcuts uses a grid (`:1816`). Add
`UiWidgets.setting_field(label, control, wide)` and pack a section into bands: a per-section label
column measured from its widest label and clamped 96-180 px, two half-width fields per band, a wide
field alone. A field is wide when its measured label width plus the control's
`custom_minimum_size.x` plus the field separation exceeds half the available content width;
otherwise it is half-width. This is measured, not a hand table (at the design card the half-column
control budget is about 170 px). Below 720 px card width every field is wide (the preview already
hides below 800, `PREVIEW_MIN_CARD_WIDTH`). Migrate the simple rows in System, Terminal, Appearance
(excluding Motion and Effects) and Reasoning; Motion and Effects are rebuilt on this builder in the
next row; leave the colour table, reactive table, command list, shortcut cards and About body as
full-width blocks. Drop the repeated in-content section title (the rail already names it) and keep
the sticky Reset. Keep each label discoverable for v0.9's rail-search row. Test: one x per control
column in a section, two fields per band where declared, no horizontal clip at the 800x500 floor
(`test_small_window.gd`), and the preview still shows on Appearance at the design size.

## GUI-142

**Motion and Effects each have a master toggle, horizontal radios, and children that disable when off** - Motion
is one `OptionButton` with Off/Subtle/Full plus per-kind pickers (`settings_panel.gd:953-1010`);
Effects uses an intensity `OptionButton` whose Off is the only off switch, an effect picker, a scope
picker and reactive rows (`:1055-1130`). On the `setting_field` builder from the previous row,
replace each with a `CheckButton` master first, then horizontal radios: Motion on/off writes
`cfg_motion` (`OFF` versus the last non-off level, `SUBTLE` by default), radios choose Subtle/Full,
and the kind pickers disable when off; Effects on/off writes `cfg_effect_intensity` the same way,
radios offer the five `UiEffects.AMBIENT_IDS`, Intensity (Subtle/Full), and Scope (Panes, Panes and
sidebar, Sidebar only), and the reactive table disables when off. No new settings key; the panel
remembers the last non-off level for the session. `UiWidgets.master_toggle(children)` owns the
disabled sweep and the dimmed labels. Test: off disables every child and saves OFF, on restores the
level and enables them, and a radio selection saves and applies.

## GUI-143

**The Settings rail takes only its labels' width and folds to an icon column** - `RAIL_WIDTH` is 148
px and `RAIL_NARROW_WIDTH` 96 px below a 760 px card (`settings_panel.gd:27-29`), while the widest
label ("Appearance") needs about 70 px plus padding, and the narrow mode still clips labels
(`clip_text`, `:378`). Set one measured text width clamped 96-116 px; add a `SettingsRailModeBtn` at
the top of the rail that swaps the text rows for a 48 px icon column (`ICONS_WIDTH`, the sidebar's),
persisted as `settings_rail` (0 text, 1 icons, default 0, clamped on load and save beside
`sidebar_mode` in `settings_manager.gd:346-390`); each section gets a Phosphor glyph in `Icons`
(gear, terminal-window, palette, brain, tree-structure, command, keyboard, info - use the nearest
existing constant where the font has none) and keeps its accessible name and tooltip. The content
column gains the difference; the preview still hides below `PREVIEW_MIN_CARD_WIDTH`. Test: text rail
at or under 116 px at the design card, icon rail 48 px, the selected glyph is accent, the mode
survives a reload, and every section is keyboard-reachable in both modes.

## GUI-144

**The sidebar's collapse control shows two arrows and one click moves one step** - `Sidebar.WIDTH/ICONS_WIDTH/COLLAPSED_WIDTH`
are 180/48/20 (`godot/scenes/ui/sidebar.gd:34-36`), `_collapse_arrow` draws one `Icons.COLLAPSE`
caret (`:327-339`), and the collapsed handle is a separate 18x22 `Icons.EXPAND` button
(`:1064-1073`) whose `cycle_mode` jumps expanded → icons → collapsed → expanded (`:1094-1106`). Add
`UiWidgets.arrow_pair` drawing two Phosphor caret labels in one button (accent via
`UiTheme.ACCENT_LABEL`, muted via the default `TEXT`): expanded shows two left carets both accent;
icons shows left accent plus left muted when entered from expanded, or right muted plus right accent
when entered from collapsed; collapsed shows two right carets both accent. A click in icons moves
one step in the pointing direction; the collapsed handle goes to icons first, and a second click
expands. Remember the entry direction for the session (default collapse direction on launch and when
the mode is set from Settings). Grow `COLLAPSED_WIDTH` to 24 and the handle to 22x22
(`BUTTON_MIN_WIDTH`, 1 px of margin each side) so the target meets the icon floor, and update the
accessible name/tooltip per state ("Sidebar: icons. Press for collapsed."). Test:
`test_sidebar_modes.gd` widths, cycle and persistence, a glyph-pair colour test, and Ctrl+Shift+B
still cycles expanded → icons → collapsed → expanded.

## GUI-145

**The Shortcuts tab is bordered group cards and sits directly below Appearance** - the Settings >
Shortcuts tab is a `VBox` of a muted caption and a bare two-column `GridContainer` per group
(`settings_panel.gd:1807-1845`), so the groups read as one block; `SETTINGS_SECTIONS` puts
`shortcuts` seventh, just above `about` (`:17-18`), and the section repeats its own "Keyboard
Shortcuts" heading (`:1791-1798`). Wrap each group in `UiWidgets.group_card` (the `RAISED_PANEL`
card the empty guide's groups use) and keep `SHORTCUT_CHORD_WIDTH` alignment; move `shortcuts`
immediately after `appearance` in both `SETTINGS_SECTIONS` and the build order, and update
`test_small_window.gd:64-80`; drop the duplicate heading and keep the immediate-free rebuild
(`remove_child` plus `free`). Test: the group tests in `test_settings_panel.gd` read
`GridContainer`s inside cards (the `_row_chord` descendant search already does), the section order
test in `test_settings_about_tab.gd:95-105`, and the `shortcuts` capture state still opens by name.

## GUI-146

**The app reports its own cost: frame time, CPU, memory and power** - the product claim is graphical
fidelity, and the app measures none of what it costs: `godot/tests/bench/draw_bench.gd` times a
forced repaint, but there is no in-app reading of idle frame time, resident memory, CPU or energy,
so "smooth" and "cheap" are assertions. Fix: a built-in `diagnostics` pane (read-only, no PTY) that
samples on a timer rather than per frame and shows (a) frame time split into idle and repaint, (b)
resident memory and its peak, (c) process CPU, (d) power draw where the platform exposes it, and (e)
per-pane rows - type, grid size, scrollback rows, PTY alive, and the fetch/draw timings the status
bar no longer prints. The pane type joins `PaneTypes.ALL` and the `PaneType` enum in `gpty-core`
spelled by `PaneType::as_str()` like every other type, so `new-pane`, the plugin-manifest
validator's closed set and the did-you-mean list pick it up from the enumeration. Program content
never appears: no captured text, no command lines, no environment values.

## GUI-147

**An idle window keeps rendering at the display's refresh rate and drains the battery** - `godot/project.godot`
sets no `application/run/low_processor_mode`, so the engine's default continuous loop draws frames
while the terminal has no output, the cursor is not blinking and the user is not typing;
`Engine.max_fps` is only a cap and its default is 0 (unlimited) through
`SettingsManager.cfg_max_fps` (`godot/scenes/autoloads/settings_manager.gd:69`, applied at
`godot/scenes/terminal/workspace.gd:416-424`). The engine key is `run/low_processor_mode` under
`[application]` (full name `application/run/low_processor_mode`; the widely cited
`low_processor_usage_mode` is not a 4.7 setting), with `run/low_processor_mode_sleep_usec`
defaulting to 6900 microseconds. The one explicit per-frame redraw found in the audit is
`AgentBadge._process` (`godot/scenes/ui/agent_badge.gd:101-103`), already gated by
`set_process(animated(_state))`, so the render loop, not a GDScript timer, is the cost. Fix: (1) set
`run/low_processor_mode=true` and keep the 6900 microsecond sleep in `project.godot`; (2) prove a
visible animation still draws (cursor blink, the ambient effect when enabled) and an idle window
with no animated agent state drops to a small frame count instead of the display rate; (3) measure
idle CPU (and power where the power-source row exposes it) at zero panes and one idle pane before
and after, record both in the performance budget table, and add idle CPU to the budget gate with a
threshold loose enough for a shared runner. The workspace's per-frame event polling is a second idle
cost and stays with its own row; this row owns the render loop. Tests: an idle run with no input and
no PTY output makes no redraw request and shows the lower frame count; the budget table carries the
before/after figures.

## GUI-148

**The effect frame budgets are borrowed from another shader** - `UiEffects.AMBIENT` declares grain
at 0.29 ms/1080p and 1.02 ms/4K, but those are the measured figures for a different, heavier FBM
tree on an RTX 5070 Ti; the v0.8.6 session could not run `godot/tests/bench/effect_bench.gd` on
hardware (Godot fell back to GL Compatibility on llvmpipe: a 4K full-frame software delta of 2.46 ms
over an 18 ms baseline), so the declaration is an upper bound, not this shader's cost. Fix: run
`effect_bench.gd` for `crt` and `grain` on the renderer bake-off's hardware and on both renderers,
replace the two numbers in the table, and record the run in the budget table this release adds.
Until then no row may claim the shader's own frame cost. Re-run 2026-11-22 on the RTX 5070 Ti at 4K
on both renderers: a 237-249 us frame floor and a 0-13 us delta (one positive sample), so the
frame-interval method still does not isolate the shader and the replacement needs a GPU-timer
measurement, not another subtraction.

## GUI-149

**A partial grid sync still pays for the whole grid on both sides of the FFI** - measured: under
`BENCH_FLOOD=1 --max-fps 60` a flood sync cost 4.7 ms of work at 102x78
(`docs/content/docs/agents/pitfalls.md:43`), against a full repaint of 2.4-3.0 ms and a one-row
repaint of 32-60 µs (`GUI-76`); the fetch half is the Rust update call plus the GDScript merge. Rust
side, code: `TermGrid::get_grid_updates` answers `TermDamage::Partial` by calling `renderable_rows`
(`crates/gpty-core/src/term.rs:414`), which allocates a rows × cols `CellInfo` grid
(`crates/gpty-core/src/term.rs:335`) and converts every visible cell - two `color_to_rgb` lookups
per cell - only to throw all but the damaged cells away (`crates/gpty-core/src/term.rs:420`).
GDScript side, code: each damaged cell rebuilds its row's `String` with two `substr` calls and a
concatenation (`godot/scenes/terminal/terminal_pane.gd:898`), so one damaged row costs O(cols) per
cell instead of once per row; a full-screen flood damages every cell. Fix, two parts. (1) On the
partial branch read the cells at the damage bounds straight from the grid
(`grid[Line(bounds.line as i32 - display_offset)][Column(c)]`) and build the `CellUpdate`s there;
`renderable_rows` stays the full-update path. (2) Replace the partial payload's per-cell `chars`
with `rows` (the damaged row indices) and `row_texts` (one string per damaged row, built once from
that row's cells) in `crates/gpty-gdext/src/grid_api.rs:264`; `terminal_pane.gd` assigns
`cc_chars[row] = row_texts[i]` once per row, then writes fg, bg and attrs per cell as today (the row
index is integer division, `idx / grid_cols`, not `int(idx / float(grid_cols))`). Nothing else reads
the partial `chars` (the only reader is `godot/scenes/terminal/terminal_pane.gd:885`; the other
`["chars"]` reads are the full cache), so the cutover needs no compatibility alias. Tests: the
existing `partial_damage_tracks_fed_cells` and `force_full_returns_all_cells_and_resets_damage` pass
unchanged; add one that a two-cell damage in a 200-column row yields one `row_texts` entry equal to
the row's full text, and a GUT test that the merge assigns the row string once and that a partial
update still renders the damaged glyph. Verification: `draw_bench` with `BENCH_FLOOD=1 --max-fps 60`
and `BENCH_SPARSE=1 --max-fps 60` before and after, reporting `sync_us`, `avg_rows` and `backoff_ms`
(add a mean fetch time to the printed line), and the saved PNGs must be pixel-identical. Land if the
flood `sync_us` drops at least 15%; record the before and after numbers here. Supporting analysis:
`TEMP/simd-opportunities.md`.

## GUI-150

**Typing in the command palette rebuilds every row, and a glyph label costs milliseconds** - code:
`CommandPalette._refresh` (`godot/scenes/ui/command_palette.gd:145`) detaches and frees every result
row on each `text_changed`, then `_make_row` (`:243`) rebuilds a Button + HBox + three Labels, one a
Phosphor glyph Label with a font override; measured on 4.7.2, a Phosphor glyph Label costs 3.3-3.5
ms to enter the tree (`docs/content/docs/agents/pitfalls.md:116`), so ~15 rows is expected ~50 ms
per typed character. `PaletteModel.filter` (`godot/scenes/ui/palette_model.gd:60`) rebuilds its
entries and duplicates ACTIONS rows per keystroke, and `_make_row` calls `ShortcutManager.chord`
(`godot/scenes/autoloads/shortcut_manager.gd:53`) per row, allocating InputMap events. Fix: a row
pool keyed by command (one Button and one heading row per section, reordered with `move_child`,
label/hint/disabled/variation/visible updated in place); build the PaletteModel entry Array once per
open and filter that; cache `chord(action)` per action. Tests:
`godot/tests/integration/test_palette.gd` and `godot/tests/unit/test_palette_model.gd` unchanged,
node count stable across 10 keystrokes, `_refresh` expected <=5 ms for 40 entries. Evidence:
`TEMP/gdscript-opportunities.md`.

## GUI-151

**Closing a pane re-renders every workspace and profile row** - code:
`Sidebar._request_close_confirm` (`godot/scenes/ui/sidebar.gd:732`), `_accept` (`:750`), `_cancel`
(`:772`) and `_request_profile_uninstall_confirm` (`:1200`) all run
`_render_workspaces(); _sync_pane_rows(); _render_profiles()` regardless of the row kind;
`_render_workspaces` (`:622`) and `_render_profiles` (`:1093`) free and rebuild every row, and a
workspace row (`:859`) builds four Phosphor glyph buttons. With one glyph Label measured at 3.3-3.5
ms (`docs/content/docs/agents/pitfalls.md:116`), eight workspaces is expected ~110 ms per pane Close
click on rows that did not change; `_render_*` also calls `queue_free` without `remove_child`, so
old rows stay in the VBox for the frame. Fix: update only the target row's pending state - panes
already have `_apply_row_pending`, workspace rows already build their hidden check/cross pair, and a
plugin-profile row already builds its uninstall confirm pair; set `_pending_close`, flip that row's
action/confirm visibility, focus the check, and drop the three unconditional re-renders. Detach
before `queue_free` in the two render helpers. Tests: `godot/tests/integration/test_sidebar.gd`;
with 8 workspaces + 2 profiles a pane Close calls neither render helper and the handler cost drops
expected >=5x. Evidence: `TEMP/gdscript-opportunities.md`.

## GUI-152

**The workspace asks every terminal for events every frame, and resolves every tile through a NodePath** - code:
every `Workspace._process` runs `_poll_concept_events`; `_poll_concept_events_for`
(`godot/scenes/terminal/workspace.gd:2928`) resolves every tile through `ws.tm._find_body`
(`godot/scenes/terminal/terminal_manager.gd:551`, a `get_node_or_null("BodyVBox/Body")`) and then
calls `drain_concept_events()` + `drain_concept_notices()` on every terminal - at the 96-pane
ceiling 96 NodePath walks + 192 grid-mutex FFI calls per frame, 11,520 FFI calls/s at idle. The same
frame returns a serialized `"[]"` from `drain_agent_events` (`workspace.gd:2706`), allocates the
`panes` group Array in `_prime_new_pane_observers` (`:2789`), and each non-empty agent batch
rebuilds the session map with one `get_terminal_session_id()` FFI per terminal (`:2725`).
`_agent_state_primed` is erased only on a move (`:721`), so close/reset leaves one entry per closed
pane for the session; `_next_label`/`_attachment_id_in_use` (`terminal_manager.gd:115`) scan every
tile through `_find_body` on spawn/restore, making a 96-pane restore O(N^2). Fix: cache the body on
the wrapper in `_build_wrapper_body` (`root.set_meta("pane_body", body)`) and read it in
`_find_body`; add one static `GptyTerminal.drain_all_concept_events()` in Rust over a live
capture/notice queue registry (register on `GptyTerminal.start`, unregister on stop/drop) returning
session-tagged envelopes, routed once per frame; return an empty GString from `drain_agent_events`
when nothing is queued; replace the per-frame `panes` group scan with a dirty queue filled by
`_attach_pane_into`/`retarget_source` plus a 4 Hz fallback; erase `_agent_state_primed` on
kill/reset/workspace close. Tests: `test_agent_event_routing.gd`,
`test_workspace_concept_terminal.gd`, `test_concept_router.gd`, `test_terminal_manager.gd`
unchanged; a kill/reset leaves the primed dict empty; a restore does not walk NodePaths. Probe: 96
quiet panes, concept FFI calls per frame expected 192 -> 1 and `Performance.TIME_PROCESS`
with/without. Evidence: `TEMP/gdscript-opportunities.md`.

## GUI-153

**A settings save repaints every terminal in every workspace, twice on an appearance change** - code:
`SettingsManager.apply_to_terminal` (`godot/scenes/autoloads/settings_manager.gd:256`) pushes 15
keys on every settings change; `TerminalPane.apply_settings`
(`godot/scenes/terminal/terminal_pane.gd:743`) always ends in `_repaint_all()`, even when no
draw-read value changed. `Workspace._on_settings_changed` (`godot/scenes/terminal/workspace.gd:280`)
loops every terminal in every workspace, and `_on_appearance_changed` (`:296-303`) runs the same
loop again on an appearance change. Editing `history_lines` or `shell_env` therefore queues 2 * rows
redraws per pane and rebuilds every text band. Fix: snapshot the draw-read values (cursor
shape/blink/speed, beam/underline widths, focus/selection/scrollback colours, font path/size) in
`apply_settings` and call `_repaint_all` only when one changed; keep both broadcasts, since the
change detection makes the second loop a no-op. Tests:
`test_settings_manager.gd`/`test_workspace_settings.gd`/`test_pane_settings.gd` pass; with 2
workspaces x 4 panes, a non-visual save repaints 0, a font-size change 1 per pane, an appearance
change 1 per pane (not 2). Closed 2026-11-20: `TerminalPane.apply_settings` snapshots
`DRAW_READ_SETTINGS` (cursor shape/blink/speed, beam/underline widths, the three overlay colours)
before and after `super.apply_settings` and calls `_repaint_all()` only when one moved; the setters
that already repack (font path/size, `default_bg`, scheme, padding) stay outside the snapshot so a
font-size change is one repaint, not two, and both broadcasts stay (the appearance listener's loop,
then `_on_settings_changed`'s, now finds nothing the second time). `TerminalPane._full_repaints`
counts full repaints; `test_workspace_settings.gd` proves, across two workspaces of four terminals,
that a non-visual save repaints 0, a font-size change costs exactly 1 from the broadcast (the pane's
minimum size really grows, so the resize that follows repaints for its own reason), and an
appearance change repaints 0 - `SELECTION`, `TERMINAL_FOCUS` and `SCROLLBACK_INDICATOR` are
identical in both palette sets, so both loops now find nothing. Evidence:
`TEMP/gdscript-opportunities.md`.

Commits: b11eb71, 66a986c

## GUI-154

**The accessibility announcement is rebuilt and published every frame while the screen is quiet** - code:
after the 500 ms settle, `_a11y_tick` (`godot/scenes/terminal/terminal_pane.gd:985`) formats
`_last_output_line` (`:973`, allocates `range` and a stripped String per row) and `A11y.one_line`
(`godot/scenes/ui/accessibility.gd:233`, `out += text[i]` per character) and calls `publish`
(`:182`, a NodePath lookup that returns the existing node unchanged) on every frame;
`_push_accessibility_value` (`terminal_pane.gd:1017`) rebuilds `visible_text()` (`:961`, strip each
row + join) every second before comparing. This runs per idle unfocused pane whenever a screen
reader is enabled. Fix: cache the last announced line and the generation behind it and return before
formatting when unchanged; build `one_line` with `substr` slices over whitespace runs; store the
generation behind `_a11y_last_value` and return before `visible_text()` when unchanged. Tests:
`test_accessibility.gd` passes; a quiet pane calls `one_line`/`publish` 0 times over 120 frames; a
new line announces once; a11y-on 10-pane idle `_process` time drops. Evidence:
`TEMP/gdscript-opportunities.md`.

## GUI-155

**The launch log has six "Unicode parsing error … Unexpected NUL character" lines** - closed
2026-11-09: the caller was `knowledge_store.gd` - `note_path_problem` spelled a NUL refusal as
`contains("\u0000")`, and a source `"\u0000"` literal is decoded through the engine's UTF-8 decoder,
which prints three "Unicode parsing error" lines per literal at load (reproduced on a minimal 4.7.2
project; `--check-only -s` names the script alone). The escape is not a NUL either: 4.7.2 replaces
it with U+FFFD, so the clause could never refuse a path - dead code whose only effect was the noise.
The fourth line, after the Phosphor import, was the same literal decoded again (it left with the
same edit; the bundle and the font were never involved, which is why deleting `knowledge.json`'s
NULs or a font-only project changed nothing, and `grep` finds no other NUL escape in the tree).
Removed the clause and named the trap in place; `pitfalls.md` already carried the rule (*Godot
strings cannot hold NUL*), and a JSON `\u0000` decodes to U+FFFD too, so no validator can see one.
Verified: headless `--quit` prints 0 lines (was 4), `--check-only` on the script 0 (was 3), and
`./scripts/gut-check` green. Found 2026-10-19; not a UX finding but queued here because it was found
by the same run.

Commits: d17bac7, 006e43a, 6cecfd6, 22cf21b

## GUI-156

**Every exit leaks 13 instances, the `TerminalManager`/`TileDrag` scripts and 85 StringNames** - found
2026-11-09 in a normal quit's log: one `TerminalManager` (reference count 2) + one `TileDrag` (count
1) per workspace, two `GDScript` resources (count 5), the `RefCounted` native class, "2 resources
still in use" (`tile_drag.gd`, `terminal_manager.gd`), 10 orphaned `Workspace` lambdas and 85
unclaimed StringNames - all one cause, two `RefCounted` cycles. (1) `TerminalManager._init` stored
`TileDrag.new(self)` while `TileDrag._init` stored the manager, so the pair keeps itself alive; the
same leak happened on every closed workspace tab, which frees only the grid
(`ws.grid.queue_free()`). (2) `_wire_tm` set `on_open_pane_settings` to a lambda that captured `tm`
and was stored *on* `tm` - a self-cycle holding one extra reference, which is why the manager read 2
and its drag 1 and why two lambdas per manager outlived the `Workspace` script. Fixed structurally:
`TileDrag` reaches its owner through a `WeakRef` behind a getter-only `_tm` property (measured:
reads null once the target frees), and the three hooks are bound workspace methods, with
`on_open_pane_settings` taking `(manager, body)` so it needs no capture. Regression tests: dropping
a manager frees it and its drag, wiring an unparented `Workspace` and freeing it leaves no reference
to the manager, and the hook still receives `(manager, body)`. Verified on 4.7.2 headless: 0 leaked
instances (was 13, 5 workspace pairs in a fresh launch), 0 resources still in use, 0 unclaimed
StringNames, no "orphaned lambdas" line, full GUT gate green. The exit-log hint about
`remove_child()` is not this case: no leaked object is a `Node`.

Commits: caaae24

## GUI-157

**Decompose workspace.gd into focused subsystems to stop regression churn** - measured in
`defect-classes.md`: 78 of 401 bug fixes (19.5%) touched `godot/scenes/terminal/workspace.gd` (3,954
lines), making it the single largest defect hotspot in the repository. It currently combines window
management, layout geometry, divider dragging, IPC polling and dispatch, security trust dialogs,
agent event routing, command palette and settings navigation. Fix: extract cohesive coordinators
into dedicated scripts: (1) `WorkspaceLayoutCoordinator` for tile tiling, resizing and divider drag;
(2) `WorkspaceTrustGate` for profile consent, plan keys and trust dialogs; (3) `WorkspaceIpcBridge`
for IPC request drain, held answers and `paneWait` polling. Tests: existing integration and unit
suites pass unchanged (`test_ipc_dispatch_contract.gd`, `test_workspace_settings.gd`,
`test_overlay_focus.gd`).

## GUI-158

**Activity and notifications: unread badges, command-finished alerts and OS attention** - today the
sidebar can show agent state, but nothing signals that the build finished in a pane or workspace you
are not looking at, and the code deliberately avoids `OS.alert` (toasts are in-window). Builds on
the v0.9.2 bell badge and the OSC 133 durations. Fix: an unseen-output and unseen-event marker per
pane row and workspace row, cleared on activation; a setting
`Notify when a command finishes after N seconds while the window is unfocused` (requires the marks;
no timing heuristic without them); the agent states already declared through `gpty state`
(`needs-attention`, `failed`) feed the same badge, display only, no orchestration; and an attention
request (taskbar flash or dock bounce) in the first cut. True desktop notifications need a
per-platform shim, since Godot has no native notification API - decide at pickup whether to build
it. A notification never carries terminal output, only the pane label and status, so nothing
sensitive lands on a lock screen. OSC 7501 records (v0.14.2) are the same input one level lower:
they carry `blocked`/`done`/`error` plus a one-line `msg`, so the marker and the alert text come
from the program rather than a screen guess.

## GUI-159

**Pane zoom, duplicate and move** - code: terminal panes have no zoom (the zoom code that exists is
the link graph's). Fix: `Ctrl+Shift+Z` toggles a zoomed pane that fills the grid (the others stay
alive and hidden, the sidebar row marks it zoomed, any new-pane action unzooms, and a saved layout
stores the unzoomed geometry); Duplicate creates the same type with the same settings and cwd under
a fresh `attachment_id`, copying the user's own per-pane env only because the user asked for the
duplicate; Move to workspace re-parents the live pane without touching its PTY. Zoom is pure view
state with no IPC surface. Tests: geometry after unzoom equals geometry before (reusing the
tile-geometry helpers in `test_terminal_manager.gd`), and Duplicate and Move leave ids unique.

## GUI-160

**Move mode: pick a pane up with the mouse and drop it somewhere else** - panes can change place
only through the swap button's menu, and the model is a 60-unit grid of tiles. Fix: a Move mode
toggled from the palette and a chord (the default is chosen at pickup against the registered set;
`Ctrl+Shift+R`, `Ctrl+Shift+M` and the `Alt`+arrow focus keys are taken, and `Ctrl+Shift+arrow`
collides with TUIs), shown in the status bar as `Move - Esc to exit` and off at every launch. In the
mode a grab overlay covers each pane and takes the mouse, so a terminal never sees a click and a
program using mouse reporting is not disturbed; the cursor becomes a drag cursor; a press-and-drag
moves a ghost outline of the pane (not a live terminal) with the target pane highlighted under it.
Dropping on the middle of another pane swaps the two tiles' positions, as the existing swap does.
Dropping on the outer quarter of a pane docks the dragged pane on that side: the tile is removed the
way a close removes it, the freed space goes to its neighbours, and the target splits to make room.
A drop that would leave a tile under `MIN_TILE` is refused with a toast and the layout is unchanged.
Escape cancels a drag in progress, and a second Escape leaves the mode. The panes keep their
processes, `attachment_id` and scrollback; only geometry moves, and a saved layout stores it like
any other. Limits: it works inside one workspace and one window, since a drag cannot leave the
window, and moving a pane to another workspace stays with the item above. It has no IPC, CLI or MCP
surface. Land it in two steps, swap on drop first and edge docking second, since docking needs a
tile-removal and split path that the grid model does not have today. Tests: a swap keeps both panes'
ids and sizes; after any dock the tiles cover the grid exactly once with no overlap (a property test
over random layouts and drops); a refused drop leaves the geometry equal to before; Escape restores
it; the mode is not persisted; and a click in the mode never reaches the terminal.

## GUI-161

**Resize panes from the keyboard** - the only way to move a divider is the mouse. Fix: a Resize mode
on its own chord (the default is chosen at pickup against the registered set, and it becomes
rebindable once the Keybindings item below lands, without waiting for it). In the mode the arrow
keys move the active pane's divider on that side: an arrow grows the pane toward that side,
`Shift`+arrow shrinks it from that side, one grid unit per press and five with `Alt`, and key repeat
works. A side with no divider (the window edge) ignores the key. Enter or Escape leaves the mode,
and the status bar shows `Resize - arrows grow, Shift shrinks, Esc to exit` while it is on. Every
key is taken by the mode and none is sent to the terminal, and the mode ends when the pane closes,
focus moves to another pane or the workspace changes. It reuses the pointer drag's divider-line
geometry (`_tiles_on_divider`, the travel limits and the same unit commit) through a single
`nudge(wrapper, edge, units)` on `TileDrag`, so a divider is a line that moves every tile on it,
whichever side was grabbed, and a keypress emits `tiles_resized` once, like a drag. Tests: a nudge
produces the same tiles as a pointer drag of the same step; it clamps at `MIN_TILE` and at the
window edge; a side without a divider is ignored; a T-junction moves every tile on the line; keys
never reach the PTY while the mode is on; and the mode ends on each of the cases above.

## GUI-162

**A held Down key moves the palette cursor one row and stops instead of auto-repeating** - reported
2026-11-17 in the running app: holding an arrow key through the command palette's results moves the
cursor a single row, so a long list can only be crossed by repeated presses or the mouse, and the
same holds for the link graph's keyboard pan. Cause (code): `CommandPalette._input`
(`godot/scenes/ui/command_palette.gd:250-262`) returns on `key.echo`, and `VaultGraphView` does the
same (`godot/scenes/ui/vault_graph_view.gd:563`); the terminal's history results already repeat
because `_on_search_bar_input` (`godot/scenes/terminal/terminal_pane.gd:1687-1695`) tests `pressed`
only, which is the behaviour to generalise. `_apply_selection` already calls
`_scroll.ensure_control_visible` (`command_palette.gd:245`), so an accepted echo scrolls as it
moves; the GUT test helper never sets `echo` (`godot/tests/integration/test_palette.gd:79`), so the
suite stays green with the defect. Fix: one held-key step in `KeyboardFocus` beside `next_index`
(`godot/scenes/ui/keyboard_focus.gd:151`) that classifies an `InputEventKey` as a cursor move for
both a press and its echo while every action that must not repeat (Enter, Escape, Delete) keeps
refusing echo; `_move_selection`, the graph's `_handle_key` and the history results take their step
through it, and any later keyboard-driven list reuses it rather than testing `event.echo` locally.
The repeat rate is the OS key-repeat rate - no second timer, no new setting. Tests: a unit case for
the press/echo/refused-action policy, and an integration case that sends three `echo` Down events to
an open palette whose list is longer than its viewport, asserting the cursor advanced three rows,
the selected row stays visible, and an echo Enter runs nothing.

## GUI-163

**Keybindings are configurable** - code: `ShortcutManager.register` takes a default bind and nothing
stores or edits it; there is no rebind UI. Fix: Settings → Keys lists every registered action (new
pane per type, close, sidebar, palette, fullscreen, workspace next/previous, focus movement,
search), rebinds by capture, flags conflicts between actions, and resets per row or all; bindings
persist in the settings file with per-entry validation (a corrupt entry falls back to that action's
default only). The v0.8.1 palette and shortcut list read the current binding, making this the single
source of truth, and a short note lists the chords terminal apps commonly use - since `Ctrl+Shift+…`
chords collide with some TUIs - plus the shells' own edit-command binding, the exact way to fix a
typo in a long multi-line command (`Ctrl+X Ctrl+E` in bash, the `edit-command-line` widget in zsh,
`edit_command_buffer` in fish). Bindings are user-owned: profiles and plugin manifests cannot carry
them.

## GUI-164

**A tuned look cannot be kept or shared: chrome is seven settings and the terminal palette is a separate CSV** - `UiPalette`
is two literal sets of 18 tokens (`godot/scenes/ui/ui_palette.gd:22-62`) and the only user overrides
are the seven `CHROME_COLOR_TOKENS` (`godot/scenes/autoloads/settings_manager.gd:14-22`) stored as
flat settings; the terminal side is a 16-value hex CSV read by `terminal_pane.gd:463-474`, which
gains foreground, background and cursor only through the colour-scheme import row in v0.8. Nothing
writes the whole look to one artifact, so a tuned palette cannot be kept as a file, shared, or moved
between machines, and no file ties chrome and terminal together the way an installed theme kit does
(one palette, every app follows). Fix: a theme file on the profiles mould (JSON, closed keys, capped
size, sanitised name, user directory) with a `chrome` object (the 18 tokens) and an optional
`terminal` object (the same 16 entries plus foreground, background and cursor the import row
defines, inline or a path); Import and Export in Settings → Appearance; the active theme resolves
inside `apply_appearance()` so `UiPalette.active()` stays the single read site and
`check-theme-tokens` stays green, and an unset token falls back to the active set. An imported theme
that puts body text below the WCAG floor the palette already guarantees is refused with the measured
ratio rather than shipping an unreadable look. Non-goals: per-workspace chrome themes (every read
site is global) and arbitrary styling. Tests: export/import round-trip equality, unknown keys
rejected by name, a chrome-only theme leaves the terminal scheme untouched, and a sub-floor contrast
theme is refused.

## GUI-165

**The Settings card changes height with every tab, so paging through tabs makes the panel jump** - reported
2026-11-17: moving between Settings tabs changes the card's height on almost every switch, so the
tab bar, header and rows shift under the pointer and the centred overlay re-lays out each time.
Cause (code): `SettingsPanel._fit_settings_card` (`godot/scenes/ui/settings_panel.gd:71-99`)
measures the current tab's inner `ScrollContainer` and sizes the card to it through
`fit_card_content`, `_tabs.tab_changed` is wired straight to that function (`:155`), and the About
tab is a second special case asking for `FILL_TAB_SIZE` 720x640 (`:21`) instead of `CARD_SIZE`
720x560 (`:17`). This is the deliberate behaviour of the v0.8.4 row *Settings cards and the command
palette keep a fixed height their content does not fill* (`GUI-103`), which removed the dead band
below a short tab at the cost of the jump this row now removes; the palette's content sizing is a
separate surface and stays. Fix: one rect for all eight tabs - raise the design to 720x640 (the
current `FILL_TAB_SIZE`, which leaves the Terminal tab's form fully visible), delete `FILL_TAB_SIZE`
and the About branch so `_fit_settings_card` only applies the window clamp, and drop the
`tab_changed` connection so a tab switch performs no relayout; each tab's `ScrollContainer` already
scrolls, so a taller tab scrolls inside the fixed body and the About document viewer keeps its own
scrollbar. State a floor as well as the ceiling: the card is never larger than the design size,
never smaller than 560x400 (the width is what the eight-tab bar needs - ~490 px plus the card's 32
px margins, `settings_panel.gd:127-131`) unless the window itself is smaller, where the existing
clamp still wins and the card fills the window less `CARD_EDGE` per side; re-clamp in `_before_open`
and `NOTIFICATION_RESIZED` only (`:59-61`, `:114-117`). Tests: replace the two cases that pin the
jump (`godot/tests/integration/test_small_window.gd:69-76`, `:109-121`) and the
`_select_settings_tab` helper comment (`:60-66`) with one test that opens Settings at 1200x800,
walks all eight tabs and asserts `_card.size` is byte-identical on each and inside the window; keep
the 800x500 and 560x340 clamp cases (`:78-94`) and add one asserting the 560x400 floor holds when
the window has room for it. Closed 2026-11-20: `CARD_SIZE` is 720x640 for all eight tabs,
`FILL_TAB_SIZE` and the About fill branch are gone, `_fit_settings_card` is `fit_card` (the window
clamp) alone, and `tab_changed` is no longer connected;
`test_every_settings_tab_keeps_one_card_size` walks the eight at 1200x800 and asserts one
byte-identical rect, and the scrollbar-column test moved to the Appearance tab because the Terminal
form now fits. The 800x500 (484) and 560x340 (544x324) clamps are unchanged.

Commits: 6368c74, 66a986c

## GUI-166

**The Settings rail has no search, so a setting is found by memory** - found 2026-11-21 while
planning the rail: even with the eight sections the card has, a user who wants "History lines" or
"Beam width" has to remember its section, and the rail makes the list longer as sections grow. Fix:
a search field at the top of the rail that indexes the panel's own row titles and keywords (one
table owned by the panel, built from the labels and a per-row keyword list, not a copy of the
controls, so a row a builder adds appears without a second list to update); a query filters the rail
to matching sections and lists the matching rows across sections; Enter jumps to the row, scrolls it
into view, highlights it, focuses its control and moves the rail's selected section and its shared
Back/Forward history, so search and manual navigation cannot disagree; `/` focuses the field, Escape
clears, an empty query restores the rail; the content is not rebuilt per keystroke (the jump
highlights the existing control). Tests: a query finds a row by title and by keyword, Enter lands on
the control, an empty query restores the rail, no results says so, and the field is a keyboard stop
before the rail.

## GUI-167

**Project workspaces: a workspace bound to a directory and a profile** - gPTY's own take on opening
a project, and the feature that gives the daemon a daily-use story. `gpty open <dir>` (and `gpty .`)
creates or focuses a workspace named for the folder, spawns its profile's panes with that directory
as cwd, and persists the binding in `WorkspaceStore`; with the v0.10.0 daemon the workspace also
survives GUI close and reattaches. The cwd is user-originated (the command line or the file picker),
never a profile or plugin field. It goes to the running GUI through the single-instance IPC path as
a new `workspaceOpen` method; like `pluginInstall` it is routed but not an MCP tool by default,
since an agent opening a workspace in a chosen directory is a spawn surface (decide explicitly at
pickup). Depends on the v0.9.2 cwd item; layout restore works without the daemon, survival across
GUI close needs it. **Workspace directory editing landed 2026-10-21:** each workspace row has a
folder button that picks an absolute directory (the file picker; `Use default` clears it), the cwd
persists in `workspaces.json`, and every terminal spawned or restored in that workspace starts there
- so the same lazygit plugin profile can be activated into different repositories. That is this
item's file-picker half; `gpty open` and the profile binding remain.

## GUI-168

**Workspaces can be restored: reopen a closed one, return one to its profile** - code: closing a
workspace (`_close_workspace`) asks only when a pane is busy, then `_close_workspace_now` resets its
terminals and frees it, so a whole arranged workspace is gone and nothing keeps it. Session
auto-save brings the open workspaces back on launch and is no help once one is closed. A workspace
also does not know which profile it came from: `_active_profile` is one app-wide string used for the
sidebar accent, set by the last activation and not persisted, so after panes have been added, closed
and resized the only way back to the starting arrangement is to find and activate the profile by
hand. Fix, two actions over the same saved-layout machinery. (1) *Reopen closed workspace*: on
close, keep the workspace's saved layout state (the tiles session auto-save already writes, so there
is no new schema) in a bounded list in the user-owned `WorkspaceStore`, the last 5 with the oldest
dropped; a workspace marked sensitive is never added, because nothing from it may be persisted. The
workspace's sidebar actions and the palette offer `Reopen "<name>"`, which restores through the
normal restore path: the trust gate and the user-owned per-pane environment apply exactly as at app
restart, each terminal starts a fresh shell in its last directory (the v0.9.2 OSC 7 item) with its
scrollback reloaded from `HistoryStore` by `attachment_id`, and no process is resumed, which the
entry says. Retention: a closed workspace's scrollback is kept while it is on the list and deleted
at the first of these: it falls off the list, 7 days pass since it was closed, or the user chooses
`Forget` on the entry. The closing time is stored in the list entry, because stored lines carry no
timestamps, and is checked at launch and at each close. Reopening deletes nothing, since the panes
reuse their ids. The launch sweep counts the list's pane ids as open, otherwise it would delete them
at the next launch, and a pane's environment entry follows the same rule. This is the one exception
to the immediate deletion on close in the v0.9.5 scrollback item. (2) *Restore to profile*: a
workspace activated from a profile records the profile's name in `WorkspaceStore`, the same binding
the project-workspaces item above adds, and `Restore to <profile>` re-activates it through the
existing ask-then-activate walk, so every busy pane is named in one dialog before anything closes; a
binding whose profile has been deleted or renamed hides the action. Neither action is reachable from
IPC, the CLI or MCP, a layout or profile cannot carry the closed list or the binding, and the
existing rule that an untrusted profile is refused over `layoutLoad` is unchanged. Tests: close then
reopen round-trips the tiles in order; the list is capped at 5 and dropping the oldest deletes its
scrollback; an entry older than 7 days is deleted at launch; the launch sweep keeps the listed
panes' rows; `Forget` deletes them; a sensitive workspace is not kept; reopening a layout that needs
trust still prompts; restoring to a profile names busy panes first and is refused when the profile
is gone. The profile binding also closes a consent gap left by v0.7.1's **A profile file can claim
to be built in or plugin-provided**: a restored workspace has no provenance, so its gate is
`TrustedStore.approved_plan_keys` (builtin approvals only) and a workspace saved from an approved
plugin profile re-prompts on every restore; with the binding recorded, the restore can consult that
profile's record (id + revision + plans) the way activation does.

## GUI-169

**Recent directories in the palette: insert a `cd` into a place you have been** - the saved-commands
item (v0.8.1) covers the directories you chose to save, and this covers the ones you did not. The
first command after a launch is usually a `cd`, and where you actually worked is already known once
the v0.9.2 OSC 7 item gives each terminal a working directory. Fix: record each terminal's reported
directory in a user-owned store (`recent_dirs.json`, the `BasePersistenceManager` pattern,
owner-only): at most 20 distinct absolute paths, most recent first, a path already listed moves to
the top. After the v0.8.1 palette and saved-commands items land, the palette gets a Recent
directories section listing `cd <path>` entries, filterable by any part of the path. Choosing one
writes `cd` and the path, quoted for the active pane's shell, to that terminal and never sends
Enter; there is no `run` flag here, and a saved command is how you opt in to that. A `Pin` action on
an entry copies it into the saved commands, where `run` can be switched on. Quoting is one helper
shared with the file-drop item above (POSIX single quotes, PowerShell `'…'`, cmd `cd /d "…"`),
whichever lands first, and the text goes through the bracketed-paste path so a directory name
containing a newline cannot submit a line. Trust: a program can emit OSC 7 for any path, so an entry
can be forged. The worst case is a misleading entry, which is why the full path is always shown,
nothing is sent until the user chooses it, and nothing is executed. Paths with a non-local host (an
ssh session), a control byte or a relative form are never recorded, and a directory that no longer
exists when the palette opens is not shown. The store is not readable over IPC, the CLI, MCP, a
profile or a plugin, and a workspace marked sensitive (the v0.9.5 item above) records nothing into
it, since a root shell's directories are what that flag exists to keep out. When the active pane is
not a terminal the entries are disabled with a reason, as for saved commands. Tests: the cap and the
move-to-top order, each rejected form above, the quoting table (a space, a single quote, a double
quote, a newline, non-ASCII), the exact bytes written with no Enter, and the sensitive-workspace
exclusion.

## GUI-170

**The GUI runs under XWayland in a Wayland session, so window opacity stays unavailable** - probed
2026-11-20 on Godot 4.7.2 / KDE Wayland: `DisplayServer.is_window_transparency_available()`
(`godot/scenes/ui/window_chrome.gd:27`) answers false under the X11 driver the session actually runs
(`DisplayServer.get_name()` = `X11`) and true with `--display-driver wayland`, so
`Settings -> System -> Window opacity` stays disabled for a Wayland user even though the compositor
could show it. The driver is the engine's choice: no project setting names one, `gpty-gui.sh`
forwards arguments, and `daemon::spawn_gui` (`crates/gpty-cli/src/commands/daemon.rs:355`) passes
none. Preferring Wayland is a decision, not a default: it moves `scripts/screenshot-gpty`,
`scripts/record-demo` and `scripts/accessibility-probe` off XWayland, and the v0.9.5 IME row's
Wayland probe should land first. Fix: pick the driver at launch when `WAYLAND_DISPLAY` is set (or
expose the switch), after those three tools run on Wayland.

## GUI-171

**A game host contract every game implements** - A small `GameBody` interface behind `PaneBody`
(`start`, `pause`, `resume`, `reset`, `score`, `state`) with a fixed-timestep tick that is
independent of the frame rate, so a game runs at the same speed on a 60 Hz and a 144 Hz display and
under a busy GUI. The game draws through the pane's own control and has no access to terminals, the
IPC layer or the file system; per the pane request contract it never spawns a pane. Tests: with an
injected clock a game advances the same number of ticks over the same wall time at 30 and at 144
frames per second; a game script has no reference to `TerminalManager`.

## GUI-172

**Snake** - The first game, and the one that proves the host: a grid sized from the pane's own
dimensions (clamped to a minimum and maximum), arrow keys and WASD, growth, wall and self collision,
a speed that rises with the score, a pause key, game over with restart, and an optional wrap-around
mode. Tests: collision rules, growth, food never spawns on the snake, and a resize mid-game keeps
the game valid (it rescales or restarts with a notice) instead of leaving the snake off the grid.

## GUI-173

**Keyboard focus is explicit and does not leak** - A game takes keys only while its pane is focused;
a key a game uses never reaches a workspace shortcut, and Esc hands focus back to the workspace (the
same consume-the-event discipline as the terminal's copy chord). Losing focus pauses the game.
Tests: a key consumed by a focused game does not trigger a workspace shortcut; an unfocused game
ignores keys; focus loss pauses.

## GUI-174

**A game that is not visible does not run** - A hidden workspace, a minimised window and an obscured
pane all stop the tick (processing is disabled, not merely ignored), so a game costs nothing while
the agent work beside it is what the machine should be doing. Measure and record the CPU use of a
paused pane and of a running Snake at the default size. Tests: switching workspace pauses the game
and its tick count does not move while away; no process callbacks fire while the pane is hidden.

## GUI-175

**Second game: Minesweeper** - Pointer-driven (click, flag, chord) so the host is shown to handle
the mouse as well as keys, sized from the pane, with a difficulty setting; the first click is never
a mine. Tests: first-click safety, flood reveal, flag and chord counts, and win and loss detection
on a seeded board.

## GUI-176

**Third game: falling blocks** - A timer- and rotation-driven game (hard drop, line clears,
next-piece preview), named generically, so the tick contract is exercised at a different rhythm from
Snake. Tests: seeded piece order, rotation against walls, line-clear scoring, and game over when a
spawn is blocked.

## GUI-177

**Game picker and per-game settings** - The new-pane menu and the command palette offer each game by
name, and a fresh `game` pane shows the picker. Pane Settings change the game and its options
(speed, wrap, difficulty), validated like every other pane setting; switching games mid-run asks
first. Games use the shared theme and colour tokens, follow UI scale, and never carry information by
colour alone (Minesweeper numbers and flags have glyphs). Tests: the picker lists exactly the
registered games; an invalid option falls back to its default only; switching games with a game in
progress asks before resetting.

## GUI-178

**A running game steps aside when something needs attention** - When another pane's agent state
becomes `needs-attention` or a command-finished alert fires, a running game pauses and shows a
banner naming that pane, so playing while an agent works never means missing the prompt. It listens
to the workspace's existing state signal and does not read or poll other panes (observe and display,
never orchestrate). A setting turns it off. Tests: a state change on another pane pauses the running
game and names the pane; with the setting off nothing happens; a paused or finished game is
untouched.

## GUI-179

**An X11 `BadMatch` from `X_SetInputFocus` is logged after an overnight run or suspend/resume** - observed
2026-10-28 while gPTY was hosted by `godot -e` and left running overnight (a sleep cycle is
suspected but unconfirmed):
`ERROR: Unhandled XServer error: BadMatch (invalid parameter attributes)`, major opcode 42
(`X_SetInputFocus`), serial 0, current serial 86239367, at `default_window_error_handler`
(`platform/linuxbsd/x11/display_server_x11.cpp:1335`). Unknown and to establish: whether the app
stayed usable or lost focus, whether it repeats per resume, and whether the failing request came
from the editor window or the project window - `-e` puts both on one X connection, so the first
split is editor-only versus project-only overnight runs. Repro: a real X11 session (not headless)
with a VM suspend/resume or lock/unlock, the project run both from the release GUI and through
`godot -e`, with `xtrace`/an Xlib error handler and Godot `--verbose` capturing the request; then
check gPTY's focus and window paths (`window_chrome.gd`, `grab_focus`,
`DisplayServer.window_request_attention`, `window_set_mode`) and whether focus is restored on
`NOTIFICATION_WM_WINDOW_FOCUS_IN`/`NOTIFICATION_APPLICATION_FOCUS_IN` before the window is mapped.
If the request is Godot's, check the 4.7 upstream and document or pin a workaround; if it is gPTY's,
defer focus restoration until the window is viewable and do not call
`grab_focus`/`window_move_to_foreground` on a stale window. Impact: log noise and possible focus
loss after resume; no crash observed. Low priority, platform robustness; a suspend/resume checklist
is the test (a GUT notification-level test covers a gPTY-side guard, but an X error needs the real
display).

## GUI-180

**A blocked pane's title bar never says what it is waiting for** - the badge shows one of four
silhouettes and a fixed label, so a `blocked` pane cannot say whether it needs permission, an
answer, or a sign-in, and a `working` job cannot show 40 percent even though OSC 7501 supplies both.
Fix: the badge gains `set_detail` and a pure `detail_text` - kind words for `needs-attention`
("Needs permission", "Needs an answer", "Needs sign-in"), then `app`, then `title`, then the
one-line `msg`, truncated at 200 chars and used as both tooltip and accessible name - and a new
`StateStrip` (`godot/scenes/ui/state_strip.gd`) draws a 2 px determinate bar on the titlebar's
bottom edge (`ACCENT` working, `WARNING` blocked, hidden without a `progress`). `TerminalPane` reads
`get_program_status` in its existing 250 ms poll (`godot/scenes/terminal/terminal_pane.gd:1048`),
applies detail only when the primary record's state equals the displayed badge state (a Tier 1 state
must never be captioned with a stale message), and exposes `agent_state()`/`program_detail()` on
`PaneBody` for the workspace surfaces. A compact 16×16 badge mode serves the sidebar. Tests: detail
composition, kind labels, truncation, compact geometry, strip visibility and width, accessibility
names.

## GUI-181

**A pane waiting on the user is invisible once it is not the active pane** - the only agent-state
indicator is the tile's titlebar badge, so a blocked or failed pane in a hidden workspace, or one
whose titlebar is turned off, is found only by scanning every tile; `v0.14.1`'s Inbox row assumes a
queue that does not exist yet and `v0.9.5`'s notification row assumes a marker. Fix: the sidebar
pane row gains a compact `StateDot` at child index 1 (the label button stays 0, actions move to
2/3/4 and the confirm to 5, with the index-sensitive `_apply_row_pending`/`_update_pane_row`
updated); workspace rows gain a `StatusChip` at index 1 (warning glyph plus blocked count, visible
only when blocked, full sentence in the tooltip and accessible name); the status bar gains the
active pane's `state — msg` detail plus the workspace summary (`1 blocked · 2 working · 1 done`);
the app titlebar and the OS window title gain the cross-workspace suffix (`N need attention`, else
`N failed`). `Workspace._process` scans every workspace's tiles on a 0.25 s accumulator
(`godot/scenes/terminal/workspace.gd:2661`), reads the cached `agent_state()` with no FFI, and
dedupes on a joined signature; `Sidebar.update_agent_status` updates dots and chips in place.
Contrast adds `WARNING`/`SUCCESS` on `SIDEBAR` to `UiPalette.CONTRAST_PAIRS`
(`godot/scenes/ui/ui_palette.gd:68`) with a 16×16 `SURFACE_RAISED` pill as the pre-decided fallback
if either fails. Tests: sidebar row indices and chip visibility, status-bar detail/summary, a
two-workspace aggregation, the window-title suffix, and a capture state showing all four surfaces.

## GUI-182

**The palette's Save Command… seeds from the terminal's own selection** - evidence: the selection
already lives in the grid (`TerminalPane._get_selected_text`), and the add form opens empty, so
saving a command you just ran means retyping it from memory - the same friction the saved-commands
row was filed for. Fix: when the active terminal holds a selection, the form's Command field starts
from it, one line through `SavedCommandStore.clean_command` and capped at the same 1024 characters;
with no selection the field stays empty, so the common case is unchanged. Not built with the v0.8.1
row because that row's contract is the store and the palette section, and the palette takes the
keyboard as it opens - the grid's selection is the only thing that survives it, so this needs its
own seam and its own test.

## GUI-183

**A hidden workspace's streaming agent is unmeasured on the main thread** - `Workspace._route_agent_events`
fans every drained envelope out to the receivers in the *source's* workspace, hidden workspaces
included (their PTYs stay alive by design), so an OMP session streaming reasoning into `omp` while
the user sits in `git` is work the visible workspace pays for: the Reasoning pane appends each delta
and hands the accumulated turn to `MarkdownView.set_markdown`, which coalesces at `RENDER_DELAY` but
still re-parses the turn (up to `reasoning_max_turn_bytes`, 64 KiB by default). Not measured - the
2026-11-09 workspace-switch investigation timed the switch only, and the reasoning-pane costs that
were measured are the ones already fixed (the cap checks and the per-delta UTF-8 encoding). Evidence
to start: a per-frame `Time.get_ticks_usec()` histogram over ~10 s while sitting in a second
workspace with an OMP session streaming in the first, routing on against off, using the windowed
timing recipe in `skill://gpty-live-gui-smoke`; any frame over the pane's work budget with the
workspace hidden makes this a fix (drop hidden receivers from the per-event fan-out and deliver a
coalesced turn on show, or drive them at the pane's own cadence), and a clean histogram closes it
with a number instead of a guess.

## GUI-184

**The agent badge's four tints are only contrasted against the shipped title-bar colour** - found
2026-11-10 while giving `working` a painted ring: `UiTokens.CONTRAST_PAIRS` (and `test_ui_palette`)
check `ACCENT`, `SUCCESS`, `DANGER` and `WARNING` against `SURFACE_RAISED`, which is only the
*default* `title_bar_bg` (`SettingsManager.cfg_title_bar_bg`, a free colour in the Appearance tab),
so a user-set mid-tone or light bar can drop a badge below 4.5:1 with nothing noticing - the row
that closed the badge's colour-only defect measured 4.80:1 as the tightest shipped pair and assumed
the default bar. The badge also reads its own role from `UiPalette.active()` at draw time, so it has
no idea what is behind it. Evidence to start: a configured bar colour that measurably hides a state
(the pair falls under 4.5:1 and the capture shows it), or a report of one. Fix direction, undecided
by design: either paint the badge on a small `SURFACE_RAISED` plate so its contrast is
self-contained, or derive a fallback tint from the bar's actual luminance - the plate costs 22x18 of
chrome and keeps the palette contract, the fallback keeps the transparency the title bar has today.

## GUI-185

**Optional event sounds, synthesized and off by default** - evidence: an agent-driven workspace is
often unattended, so completion, failure and needs-attention are the events worth hearing when the
window is not focused; gPTY already emits them (`agent.*`, `state.declared`) and the v0.9.5
notifications row owns the visual half, while the app owns no chrome audio today (the media pane's
sound is pane content). The study book's sound chapter supplies the recipe with no assets: one short
envelope per event (a falling square for failure, an arpeggio for completion), synthesized into an
`AudioStreamGenerator` or a cached PCM buffer - never a per-keystroke blip. Fix direction, design at
pickup: `Settings → Notifications → Sounds`, default off, with completion and completion-plus-errors
as the two opt-in sets and an optional "only while the window is unfocused"; bounded duration, a cap
on concurrent voices, no files, no network, a silent or headless device is a no-op, and no sound
carries terminal output. Tests: the default is off; a setting change plays only its events; headless
constructs no stream.

## GUI-186

**The scheme backdrop and an ambient effect cannot combine** - found 2026-11-24 while shipping the
v0.8.7 backdrop: the gradient is the terminal's own ground, and `PaneEffects` paints an opaque
ground of its own (`set_ground`, then the static quad or the half-resolution buffer's `ColorRect`),
so with an effect on the Effects picker the backdrop setting draws nothing. Evidence to start: a
user asks for both. Fix direction: hand `PaneEffects` the two stops; the static shaders already read
the quad's interpolated `COLOR.rgb` as `base`, so a per-vertex-coloured quad carries the gradient
through CRT, while the animated grain path renders into a `SubViewport` whose ground is a single
`ColorRect` and needs the gradient drawn in that buffer.

## GUI-187

**A borderless embedded dialog cannot cast a page shadow** - found 2026-11-24 while shipping the
v0.8.7 elevation rule: `AcceptDialog`'s panel is the elevated box (an 8 px shadow at (2, 4)), but a
borderless dialog is an embedded `Window` and its panel is drawn inside that window's own
sub-viewport, so the part of the shadow outside the panel rect is clipped; the `file-dialog` capture
shows the dialog's surface and top rim and no halo on the page, while the palette, cards and toasts
are ordinary Controls and do cast it. Evidence to start: a user or a screenshot review finds dialogs
still reading as pasted on. Fix direction: size the window with a transparent margin and hold an
inner elevated card (a `PanelContainer` inset by 10 px, the window's own panel set to
`StyleBoxEmpty`), or draw the shadow from an overlay behind the window's rect; both need a check
that a transparent embedded window composites the page behind it.
