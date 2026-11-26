---
title: "Roadmap details - TERM"
weight: 900
build:
  list: never
---

Every TERM row, by ID and in allocation order. The queue and its priority live on the release chain pages; this page is the evidence behind each row.

## TERM-1

**Multi-PTY terminal emulator** - spawn and manage multiple shell sessions in a tiling grid. Each
session is an independent PTY with its own shell process, environment, and working directory.

Commits: d17bac7

## TERM-2

**ANSI/vte parsing** - full SGR color and cursor positioning via alacritty_terminal. Handles
16-color, 256-color, and true color (24-bit) sequences. Strips escape sequences for concept
matching.

Commits: d17bac7

## TERM-3

**Control-based renderer** - terminal grid drawn in GDScript via `_draw()`. Rust packs cell data
(chars, foreground, background, attributes) into flat arrays; GDScript unpacks and renders them
line-by-line with damage tracking for incremental updates.

Commits: d17bac7

## TERM-4

**Scrollback restore on restart** - reload persisted history lines by `attachment_id` when a pane
reopens, so scrollback survives restarts (builds on the v0.5.0 stable public pane IDs).

Commits: d17bac7

## TERM-5

**History full-text search** - surface the FTS5 store's `search()` in the terminal search UI so old
output stays findable after restart.

Commits: d17bac7

## TERM-6

**History retention setting** - `cfg_history_lines` (default 10 000) clamping the per-pane cap.

Commits: d17bac7

## TERM-7

**Render batching** - the text pass issues one `draw_string` per run of consecutive cells sharing
font, color, and underline state instead of one per non-space cell (backgrounds were already
merged). A run stops at a space, so an underlined space keeps its own segment - the old pass
underlined every attributed cell, spaces included, and a first cut of the batching silently dropped
that segment until a pixel diff caught it. Measured with the new `godot/tests/bench/draw_bench.gd`
harness (forced full repaint vs idle frame, X11 + `--disable-vsync`): 90×30 1813 µs → 1388 µs,
200×60 4482 µs → 3867 µs (idle frame ≈ 300 µs, so ~20 % off the repaint at a realistic pane size),
and both sizes render **pixel-identical** to the per-cell pass. Baseline from the v0.5.3 prep work:
idle panes no longer repaint at all (the repaint is gated on the grid generation - measured 48–49
gate ticks/s per pane against 0 generation changes), so this item is only about cost *under load*.

Commits: d17bac7

## TERM-8

**UI Thread DoS mitigation** - a pane whose grid work (fetch + repaint) exceeds
`PANE_WORK_BUDGET_MS` (4 ms, a quarter of a 60 Hz frame) now looks at the grid less often: the
cadence stretches geometrically to `MAX_SYNC_INTERVAL` (0.1 s ≈ 10 Hz) and walks back as soon as a
sync finds nothing new, so nothing is lost - the damage tracker coalesces everything into the newest
grid state, and a flooding pane is unreadable at 60 Hz anyway. View changes the user drives (wheel,
PageUp/Down, search jump) are exempt for 500 ms, so scrolling a large pane is never pushed into the
flood cadence. Measured with `BENCH_FLOOD=1` in `godot/tests/bench/draw_bench.gd` (a pane repainting
its whole screen in a loop, median of 3 runs): 200×60 costs 2.47 ms/frame → 1.46 ms/frame (≈400 →
≈690 fps in a 2100×1300 window), while a pane that fits its budget (90×30, ~1.5 ms/frame) is not
throttled at all. 5 GUT cases pin growth, the budget floor, the exemption, the ceiling, and
recovery. (Deferred from v0.5.0.)

Commits: d17bac7

## TERM-9

**Terminal mouse reporting** - `TermGrid::mouse_mode()` exposes alacritty's DECSET 1000/1002/1003
tracking bits plus 1006 (SGR) as a bitmask over the FFI (`get_mouse_mode`), and the pane forwards
only what the enabled mode covers: clicks always, drags under 1002, buttonless motion under 1003,
wheels whenever the app tracks at all. Reports are SGR when 1006 is on and legacy X10 otherwise,
encoded from the same cell mapping selection uses, and the report is dropped (never clamped) past
cell 223 where the legacy form cannot address it. Selection and scrollback are untouched while the
bits are zero, and `Shift` bypasses reporting so text selection stays reachable in an app that
grabbed the mouse (the manual checklist covers nvim/lazygit/htop). Verified end to end: a real child
that enables 1000+1006 receives a synthesized click at cell (5,3) and its own echo of `ESC[<0;5;3M`
lands in the grid; 12 GUT cases cover routing and encoding, plus a grid test for the mode bits.

Commits: d17bac7

## TERM-10

**Grid geometry ceiling** - `start_shell`/`resize_grid` clamped dimensions only from below, and
`PaneTypes.sanitize_tile` never bounded a stored `rows`/`cols`, so a crafted tile allocated a
10¹²-cell grid at spawn. Both boundaries now clamp (500 × 2000).

Commits: d17bac7

## TERM-11

**Live-search result cap** - a one-character pattern over 100k scrollback lines materialised every
match on every keystroke and walked them each frame; `TermGrid::search` stops at
`MAX_SEARCH_RESULTS` (10 000).

Commits: d17bac7

## TERM-12

**Bracketed paste** - a paste went to the PTY verbatim, so every newline submitted a line and any
control byte in the clipboard was injected raw (a pasted `ESC[201~` closed the application's own
paste bracket, `^C` interrupted). The grid now reports DECSET 2004 (`TermGrid::bracketed_paste`,
exposed as `is_bracketed_paste()`), and `TerminalPane.build_paste_payload` wraps the text in
`ESC[200~`/`ESC[201~` when the child asked for it, keeping the bytes untouched (corrected under
v0.7.1: untouched text let a clipboard close the bracket early, so both branches now run one control
filter - see **Pasted text can close the bracketed-paste bracket early, and the rest reaches the
shell as typed input**). When it did not, the guard runs the other way: C0 controls and DEL are
dropped - escape sequences above all, and a bare CR, which the PTY turns into Enter - while newlines
and tabs survive, because a multi-line paste into a plain shell is a normal thing to want. Verified
live: `is_bracketed_paste()` follows a real child's own output
(`printf`\033[?2004h`/`2004l` then `exec cat
-v`) in `godot/tests/integration/test_bracketed_paste.gd`, and `test_paste_payload.gd` drives the real Ctrl+Shift+V branch through a stub-FFI probe (9 cases: both branches, the guard, bare CR, empty clipboard). One finding from writing that test: an interactive shell's **readline enables 2004 by itself**, so panes running a shell already take the bracketed path and the guard is what covers everything else. (Deferred from v0.5.3.)

Commits: d17bac7, 93f77cb

## TERM-13

**Killing a pane does not kill its process group** - `PtyHandle::drop` killed only the shell, and a
shell's descendants do not always follow it: the kernel's SIGHUP on session-leader exit reaches the
*foreground* group, so a background job under job control (what an interactive pane produces) or a
process that ignores SIGHUP is orphaned until its own writes fail. The drop path now SIGKILLs the
child's process group first (the child is a session leader, so pgid == pid, and the group is not
ours); `dropping_a_pane_kills_its_process_group` starts a SIGHUP-immune grandchild, reads its pid
off the PTY, and probes it until ESRCH - it fails without the group kill and passes with it. (Found
while moving input writes to a writer thread.)

Commits: d17bac7

## TERM-14

**Unbounded PTY-output channel** - `pty_rx` was an `mpsc::unbounded_channel`, so a pane whose output
outran the terminal task grew the process without limit. Measured before the fix: a `yes` pane added
~70 MiB/s to the GUI (194 → 1248 MiB in 15 s) and ~110 MiB/s in a bare `gpty-core` harness (2.2 GiB
after 20 s). Backpressure, as designed, at `pty::OUTPUT_QUEUE_CHUNKS` (256 × 4 KiB = 1 MiB per
pane): `PtyHandle::spawn` takes a bounded `Sender` and the reader thread blocks in `blocking_send`,
so a full queue stops the reads, the kernel PTY buffer fills, and the child's `write` blocks - the
backpressure a terminal emulator has always applied. Dropping chunks was never an option: the bytes
carry ANSI state, not independent records. Measured after: GUI RSS flat at 216 MiB across 15 s of
`yes` (delta 0) and flat at 30 MiB in the harness, with the drain rate unchanged (29.5 k lines/s
before, 31.1 k after - the ceiling is the consumer, not the channel), and the pane recovers:
`seq 1 300000` finished, the prompt returned, `kill-pane` reaped the child.
`a_full_output_queue_throttles_the_child_without_losing_bytes` pins the invariant that a full queue
throttles rather than truncates (it reads 216 of 4000 lines against a `try_send` reader);
`crates/gpty-core/examples/flood_probe.rs` reproduces the harness numbers.

Commits: d17bac7

## TERM-15

**Bracketed-paste tests never exercise the child on Unix** - measured while fixing `windows-smoke`:
with the fixture's command line replaced by a bare `sleep 30` (it prints nothing at all),
`godot/tests/integration/test_bracketed_paste.gd` still passes 3/3 in 1.3 s, and a probe taken once
the shell is up reads `mode=true` *before* anything is typed - bash's readline sets DECSET 2004 by
itself (`bash -i` under a pty emits `?2004h` and `?2004l`; `bash --noediting -i` emits neither), so
the fixture's own bytes are only load-bearing on Windows, where `cmd.exe` has no readline. The file
therefore covers the parser and the wrap/guard halves on both platforms, but "the child's bytes
decide the mode" only on Windows - which is also the only place a cold `powershell.exe` start
matters (a fixed 10 s wait here is what reported a cold start as "the mode never arrived" and turned
`windows-smoke` red). Fix: run the paste tests under a shell that does not set the mode itself - the
pane's own `shell_args` (`bash --noediting`) on a pane the test spawns through
`TerminalManager.spawn_pane`, since `SettingsManager` carries no global args - and assert the mode
is **false** once the shell is ready, before the fixture's `2004h` is typed. That assertion is the
one that fails today on Unix, so it pins the masking. **Closed:** the pane is spawned with
`ShellFixtures.no_line_editing_args()` (`bash --noediting`, nothing on Windows - `cmd.exe` has no
line editor) and the helper asserts the mode is **false** once the shell is printing, before any
fixture bytes; `test_resetting_the_mode_reaches_the_pane` became a real transition the child drives
(on, hold, off in one line - `ShellFixtures.print_text_pair()`, because a holding fixture cannot be
typed into twice), so both directions are now the child's doing on every platform. Two things had to
be measured rather than assumed: spawning through `TerminalManager.spawn_pane` leaves the wrapper
unparented, so `_ready` never runs and `_terminal` is null - the pane has to come from
`Workspace._spawn_pane`; and dropping the args reproduces the masking exactly (`mode=true` against a
bare prompt, 3/3 failing), which is what makes the new assertion load-bearing. Verified: integration
suite 172/172 with the file at 3/3, and the mutation above.

Commits: d17bac7

## TERM-16

**A pane whose terminal task died looks like a running one** - fixed: liveness is now part of the
status document instead of being assumed from the exit code. `SpawnedTerminal::task_finished()` is
`is_finished()` on the task's `JoinHandle`, which nothing used to look at, and it is the only signal
that notices a task which ended **without** recording an exit code - a panic inside it, or a child
that closed its pty and outlived the pane. `running` is now
`exit_code.is_none() && !task_finished()`, and `exit_reason` (`exited` / `task_ended` / `null`) says
which of the two stopped it, so nothing has to guess from a null exit code. The document is built in
core (`SpawnedTerminal::status_json`, following `history_store_stats`), which makes the bytes the
pane API returns the bytes under test:
`a_task_that_ends_without_an_exit_code_is_reported_as_stopped` drives a real pane whose child
detaches (`exec 0<&- 1>&- 2>&-; sleep 30` - closing the fds ends the read side while the child keeps
running, the same state a panicked task leaves) and asserts `running: false`, `exit_code: null`,
`exit_reason: "task_ended"`; `a_live_pane_reports_running` pins the live branch (`running: true`, no
reason); and `a_shell_that_exits_while_the_pty_is_held_open_is_still_reported` gained the third
(`exited` with its code, which is the case `paneRun` promises). Reverting the derivation to
`exit_code.is_none()` fails the first test with the pre-fix document printed in the assertion. The
item's second half is closed as well: `with_grid`/`with_grid_mut`/`with_grid_mut_ret` now lock
through `lock_or_warn(&spawned.grid, "pane grid")` - the same name the engine uses for that mutex -
so a poisoned grid is reported once per process instead of once per frame from the renderer's poll.

Commits: d17bac7

## TERM-17

**A failed `resize_grid` desyncs the pane's size permanently** - fixed in three parts, all of which
are needed. (a) The grid+PTY resize is now one all-or-nothing operation in core,
`SpawnedTerminal::resize`: it takes the grid lock once, returns `false` without touching anything at
all when that lock is poisoned, and sends the PTY resize only after the grid took the size - the
child can no longer reflow (and take a SIGWINCH) at a width the emulator never applied. (b)
`GptyTerminal.resize_grid` returns `bool` - the honest half of the contract the pane records from; a
pane with no shell answers `true`, because there is no grid to refuse and a caller that retried
would never converge. (c) `terminal_pane.gd` records `cols`/`rows` only after the backend reports it
took the size, and re-arms the debounce *before* the call, so both a refusal (`false`) and a panic
(the VM aborts the calling function at the FFI boundary, so nothing after the call runs) leave the
old dimensions in place for the next pass instead of rendering at a size the grid never had.
Verified live: `a_resize_reaches_the_grid_and_the_child` has the child report its own window size
through the pty (`stty size`), so the PTY half is observed rather than assumed, and
`a_refused_resize_leaves_the_child_where_it_was` poisons a real pane's grid the way a panic does and
asserts the child still reports the size it was spawned at (the grid cannot be read through a
poisoned lock, so the child reports to a file - the pty is the only channel back, and it is the
channel under test). Both were mutation-checked: moving the PTY resize before the lock check fails
the first, deleting the success path's PTY resize fails the second.

Commits: d17bac7

## TERM-18

**Screen-reader accessibility is a product surface, not a flag** - closed 2026-11-05. One owner,
`godot/scenes/ui/accessibility.gd` (`A11y`): `enabled()` is true when an accessibility driver is
loaded or a reader reports itself attached (the export's `AccessibilityServer.is_supported()` is
true, the editor build's is false, and `accessibility_screen_reader_active()` reads 0 on this
desktop even with `org.a11y.Status.IsEnabled` set), `set_text` records the visible text and pushes
it as the element value, `publish(host, slot, text, live)` replaces a hidden text node, and
`announce_host` returns the tile's title bar. Names are enforced at the choke point:
`Icons.icon_button(btn, name)` requires the words (a `Button` is named from its text before its
tooltip, and that text is a PUA codepoint), `PaneBody` names every pane (`"T1: Terminal"`, or the
user's name for it), and the window controls, sidebar, settings, pane-settings and concept-editor
glyphs all carry explicit names. Measured limit, left in place on purpose: the engine composes the
exposed name as `"<accessibility_name>: <button text>"`, so a glyph-only button still reads its
codepoint after the words - moving the glyph out of `Button.text` into a child `Label` is **Pane
chrome: one icon-button treatment, signed off by the owner**'s work, not this row's. The terminal
publishes its visible grid (`visible_text()` from the damage-tracked cell cache, scroll offset
included) and, while unfocused, its last settled output line at most once a second; the vault graph
names itself, describes its shape and announces the crosshair's node on keyboard pans; media names
its video surface and seek slider; the concept editor names the graph, its rules and its nodes.
Verified: `godot/tests/unit/test_accessibility.gd` (59 asserts),
`scripts/ui-capture --audit-accessibility first-launch` (glyph-buttons=16, unnamed=0, every name
printed) and `scripts/accessibility-probe` against a rebuilt export, which asserts the exposed
AT-SPI tree - application `gpty`, window `gPTY`, `T1: Terminal`, `Close All`, `Settings`,
`New workspace (max 8)` and terminal text carrying a marker injected through the control socket.
Adapter facts the design is built around (4.7.2, measured 2026-11-05): names arrive as the `Name`
property, not `GetName`; a `PaneBody` is a leaf, so published text lives on the bar; a name is a
snapshot, so dynamic text is a fresh node per change. Element values and descriptions do not reach
AT-SPI from GDScript - queued as **Element values do not reach the AT-SPI adapter**. No
`accessibility/*` project setting and no launch flag: the engine's `AUTO` remains the policy.

Commits: f460c31, 6cecfd6, 547df56, 3754288, 8cb09fd, 35a219f

## TERM-19

**Element values do not reach the AT-SPI adapter** - closed 2026-11-06 with the answer this engine
can have. 4.7.2 is the newest release, so there is nothing newer to re-test on: the measurement
stands (value and role writes never reach the node, a node's name is the creation snapshot, and the
adapter serves `Name` as a property with no role method and no `Text`/`Value` interface on a custom
`Control`), and the app-side cost is removed - `A11y.publish` now returns an unchanged slot as it
is, so `TerminalPane._a11y_tick`'s once-a-second republish of the same line no longer takes the node
a reader is on (`test_publish_leaves_an_unchanged_slot_alone`; a changed live mode still replaces
it, `test_publish_replaces_when_the_live_mode_changes`). `scripts/accessibility-probe` prints a
report-only `a11y-values:` line (`text-interfaces`, `value-interfaces`, `marker-in-value`,
`role-names`), which grades any later engine in one command; the engine-gated half is
`docs/content/docs/roadmap/future.md` *Re-test the AT-SPI element-value mapping when an engine
release carries it*.

Commits: 8cb09fd, 6918477

## TERM-20

**A fresh pane's child starts at 80×24 and only learns its real size 50 ms later** - fixed
2026-11-08: a pane spawns its child on its first layout pass, at the size the pane is drawn at.
`TerminalPane._start_child_if_ready` is the only `start_shell` call site and takes the fitted grid
from `_grid_for_size(size)` - one helper, the same `(size - PADDING) / cell` threshold the resize
debounce now uses, so a child is born at the size the debounce would settle on and the debounce
never resizes a child by its own creation. `crates/gpty-core/src/pty.rs` opens the pty at that size
(`openpty(PtySize { rows, cols })`; it used portable-pty's 24×80 and resized afterwards, which is
why the child's own first read was 80×24 whatever the grid said). `Workspace._apply_layout` tells
each tile's pane it holds the rect it is drawn at (`PaneBody.mark_tile_laid_out` via
`TerminalManager.mark_tile_laid_out`), so a pane the grid has never positioned spawns nothing and a
tile too small to hold the minimum grid (8×3) still gets a shell at its configured `rows`/`cols`;
`_process` covers the tile whose size never changes, one frame after the mark. Input that reaches a
pane before its child exists is buffered (`_pending_input`, 64 KiB - `inject`/`broadcast` now go
through the pane's own `_send_line_to_term` instead of writing to a terminal with no session) and
flushed at start. A terminal with no session answers the documented nine-key `paneStatus` document
(the new `gpty_core::engine::unstarted_status_json`, one builder shared with `status_json`) instead
of `{}`, because every pane now reports one frame without a session. Measured: pre-fix the test's
`bash -c 'stty size'` printed `24 80` where its pane was drawn at `43 59`, post-fix it prints
`43 59`; in the app, a startup pane at 1738×1030 answers `60 205` and a split pane at 868×1030
answers `60 102`, unchanged three seconds later, and the capture below (1280×760) shows the child's
own `41 rows, 129 cols`. Tests: `test_pane_spawn_size.gd` (born at the fitted size through a real
`stty size`; input in the spawn frame survives; a never-positioned pane has no child; a sized pane
starts at its own size),
`test_pane_settings.gd::test_apply_settings_rows_cols_never_resizes_a_live_grid`,
`pty::tests::the_childs_first_view_of_its_size_is_the_requested_size`,
`engine::tests::the_unstarted_status_document_has_the_keys_a_live_one_has`. Two behaviour changes: a
pane in a workspace that has never been shown starts its child when the workspace is first shown,
and a stored or live `rows`/`cols` no longer resizes a grid (the fields are the pre-layout fallback;
the pixel fit owns the size). Screenshot ([captures](../screenshots/v0.8.md#screenshots)): *Pane spawn size*.

Commits: e81de90, 01d5859

## TERM-21

**A scrolled-back pane returns to live output in one click** - closed 2026-11-10: `TerminalPane`
carries a floating chevron (`Button` named `ScrollToBottom`, 24x24, anchored to the pane's
bottom-right at offsets -30..-6, `Icons.CARET_DOWN` U+E136) whose tooltip and accessible name read
**Return to live output**. It is shown exactly while `get_scroll_offset() > 0`
(`_sync_scroll_end_button`), and the sync sits on every path that moves the view rather than only in
the frame sync: the wheel branch, PageUp/PageDown, `_snap_to_bottom` (typing, Enter, the click) and
a search jump - the frame-sync call alone left the control up to a sync interval stale after a wheel
(measured while staging the capture: offset 15, button still hidden four frames later). The click
calls `_snap_to_bottom()`, then `_refresh_selection()`; the selection is grid-space, so the jump
carries the highlight with its text and copy still works, and the existing `[Scroll: N/M lines]`
readout stays the position. It is a real `Button` child, so Godot's picking delivers the click
before `_handle_mouse` reaches the mouse-reporting branch: in a TUI that owns the mouse the chevron
stays pane chrome rather than becoming a click report. It never takes focus or sends input -
`FOCUS_NONE` with a declared reason ("PageDown, the wheel or typing return to live output"), which
the focus audit counts as answered (`unaccounted=0`), and `Ctrl+End` parity can ride the
configurable-keybindings item in v0.9.5. Tests: `test_scrollback_return.gd` - the chevron follows
the offset through the frame sync (shown above 0, hidden at the bottom), a click resets the offset
to 0 with the selection text unchanged, and a `ScrollProbe` pane reporting DECSET 1000 keeps
`MOUSE_FILTER_STOP`/`FOCUS_NONE`, sends nothing (`sent == []`) and keeps its selection. Screenshot
([captures](../screenshots/v0.8.md#screenshots)): *Scrollback return*.

Commits: 02343a4, 6cecfd6, d6a67a7

## TERM-22

**The typed-line repaint test counts paint calls across syncs** - fixed 2026-11-14: the test diffed
`_cell_cache` between the settle and the end of the test but asserted against the *last*
`_repaint_rows` call, so a typed line whose echo and command output land in two syncs failed - 3 of
3 runs of that file alone on 2026-11-13 (row 0 changed while `_painted_rows` held [1, 2]), and on
`windows-smoke` in run 43533705570, which put `main` red with row 3 changed against [4, 6]. It now
samples every frame: a sync is a frame whose generation moved, the rows it changed are the diff
against the previous sample, and the paint set is `_painted_rows` as that sync left it, so every
changed row is judged against the sync that changed it and the four-row budget holds per sync (a
full repaint still fails the run). Measured after the fix: 5 of 5 in that file on three consecutive
runs, where it used to fail 3 of 3.

Commits: 7178999, 42496c5

## TERM-23

**Input latency and throughput are measured and gated** - `godot/tests/bench/draw_bench.gd` measures
draw cost, but nothing measures keystroke-to-pixel latency or sustained throughput, so "feels fast"
is unevidenced. Fix: a harness that records (a) key event to grid change to the first frame that
draws it, (b) MB/s through a flood with the flood throttle active (`cat` of a large file, `yes`),
and (c) memory and SQLite size with 16 panes at full scrollback; record the numbers in this item and
the CHANGELOG, add a loose CI regression gate (thresholds generous enough not to flake on shared
runners, the lesson of the parallel-test item), and publish the figures in the docs. Make no claim
about other terminals unless they are run under the same method.

## TERM-24

**The escape-string guard scans every PTY byte by hand, twice** - code: `EscapeStringGuard::feed`
(`crates/gpty-core/src/escstring.rs:68`) walks the chunk with `bytes.iter().enumerate()` and matches
a terminator byte per iteration, and it is the only hand-rolled scan left on the output path:
`LineParser::feed` (`crates/gpty-core/src/parser.rs:71`) and `TermGrid::feed`
(`crates/gpty-core/src/term.rs:290`) each put it in front of their vte parser, and
`run_terminal_task` feeds both for every 4 KiB read (`crates/gpty-core/src/engine.rs:854`,
`crates/gpty-core/src/engine.rs:962`; `crates/gpty-core/src/pty.rs:139`), so a byte is guarded twice
and parsed twice. vte 0.15 already finds ground-state text with `memchr(0x1B)` and memchr resolves
to AVX2, SSE2 or NEON at runtime with a scalar fallback, which is the shape the guard is missing.
Measured before any of this: the gated matcher moved a `yes` flood at 81.9 MB/s with no concepts and
73.9 MB/s with 128 typical triggers (`concept_probe`, v0.5.4). Fix: add `memchr = "2"` to
`crates/gpty-core/Cargo.toml` (2.8.3 is already in `Cargo.lock` through `regex` and `vte`; MIT and
Unlicense are allowed by `deny.toml`), then make `feed` skip: in the ground state
`memchr(0x1b, ...)` to the next introducer and sink the run whole; inside an OSC, find the earliest
of `0x1b`, `0x07`, `0x18` and `0x1a` with one `memchr3` plus one bounded `memchr`, and compute the
budget cut arithmetically from the bytes still allowed instead of counting each byte. Keep the
current scalar loop as the `#[cfg(test)]` reference and prove equivalence with a deterministic LCG
corpus over every chunk split and budgets 0 through 8. Probe: a new
`crates/gpty-core/examples/scan_probe.rs` (no PTY) reports guard MB/s on 1 MiB of plain text and on
1 MiB of OSC payload, plus `TermGrid::feed` MB/s on a synthetic ANSI stream. Land only if the guard
scan is at least 5x faster and `TermGrid::feed` at least 3% faster; record both numbers here, and if
either misses, revert the code and close this row with the number. Supporting analysis:
`TEMP/simd-opportunities.md`.

## TERM-25

**A row's text band is rebuilt one character at a time, and every row re-reads the same cache** - code:
`TerminalPane._draw_row_text` (`godot/scenes/terminal/terminal_pane.gd:1218`) reads
`var ch: String = line[c]` (`:1234`), a fresh one-character String per cell, and extends a run with
`text += nch` (`:1270`), a copy per character; a 200x60 repaint is 12,000 cells; the probe measured
87 ns per indexed+appended character (34,857 us for 2000 x 200), so ~1.0 ms of the repaint is this
loop. Each band also calls `_font.get_ascent(font_size)` (`:1227`), `_grid_offset()` (`:1225`), and
`_cell_cache.get("cols"/"rows")` (`:1220-1221`) per row, with `_draw_row_background` repeating the
cache reads (`:1197-1198`). Measured before the row split: full repaint 1388 us at 90x30 and 3867 us
at 200x60, idle ~300 us (`TERM-7`); the row split landed, the per-cell String work is what remains.
Fix: test spaces with `line.unicode_at(c) == 32` (guard `c < line.length()`) and build each run once
with `line.substr(c, run_end - c)`; cache `_ascent` in `_recompute_cell_metrics`, cache
`_grid_origin` and the row/col counts on the pane (invalidate on full sync, resize and
`_recompute_cell_metrics`), and use them in both bands and the overlay instead of repeated
`_grid_offset()`/`_cell_cache.get`. Tests: `test_terminal_repaint.gd`/`test_inverse_paint.gd` pass;
`draw_bench` at `BENCH_COLS=200 BENCH_ROWS=60` records forced/row before and after, down >=15%, PNG
byte-identical; if the gate misses, revert and close with the number (the Future row **The terminal
still segments a row's text runs in GDScript** owns the next step). Evidence:
`TEMP/gdscript-opportunities.md`.

## TERM-26

**Every keystroke takes the grid lock five times to learn nothing changed** - code: every printable
key path (`godot/scenes/terminal/terminal_pane.gd:1654-1662`) calls `_clear_selection` (`:1482`),
which always calls `selection_clear()` and `_repaint_overlay()`, then `_snap_to_bottom` (`:1526`),
which always calls `scroll_reset()` and `_sync_scroll_hints()`; `ScrollHints.sync`
(`godot/scenes/ui/scroll_hints.gd:135`) calls two "can move" callables, each doing
`get_scroll_offset()` + `get_history_size()`, and the pane's own sync re-reads. That is 5-6
grid-mutex FFI calls plus an overlay repaint per typed character in the common case (no selection,
view at live). The same pattern runs on every damage sync (`terminal_pane.gd:926-927`, with
`_refresh_selection` at `:1518` building an empty `PackedInt32Array`), overlay repaint (`:1290`
reads offset/cursor separately), and search highlights call `UiPalette.active()` inside the match
loop (`:2018`). Fix: early-out `_clear_selection` on empty `_sel_cells`; call `scroll_reset` only
when a cached view offset is non-zero (return whether it moved) and sync hints only then; early-out
`_refresh_selection` with no selection; pass offset/history into `ScrollHints.sync`; add
`GptyTerminal.get_grid_metrics()` (`cursor_row`, `cursor_col`, `scroll_offset`, `history_size`),
read once in `_draw_overlay`; hoist the palette read. Tests: `test_keyboard.gd`,
`test_scroll_hints.gd`, `test_scrollback_return.gd`, `test_copy_routing.gd` pass; a 1000-key probe
sees no `selection_clear`/`scroll_reset` on the empty/live path; `draw_bench overlay_us` with a
search open down expected >=30%. Evidence: `TEMP/gdscript-opportunities.md`.

## TERM-27

**A pane cannot spawn when `$HOME` names no directory, and an empty workspace directory silently means `$HOME`** - found
2026-11-04 while running the GDScript suite: every pane failed with
`Failed to spawn PTY for '/bin/bash': No such file or directory (os error 2)` although `/bin/bash`
existed and ran, because the environment carried a `HOME` whose directory had been removed. Cause
(code, portable-pty 0.9.0 `CommandBuilder::as_command`): the workspace directory is passed as `cwd`,
and portable-pty substitutes `$HOME` whenever that is absent -
`self.cwd.filter(is_dir).unwrap_or(home)` then `cmd.current_dir(dir)` - so an unusable `$HOME`
becomes a `chdir` failure whose errno surfaces as "the program does not exist". Its `get_home_dir`
falls back to `getpwuid` only when `$HOME` is unset, never when it is set and missing, and the gdext
`cwd` sanitizer (which does drop a stale workspace directory) has no equivalent floor for the
fallback. Two consequences: a launch whose `$HOME` is a stale mount, a deleted home or a container
path that is not there fails every pane with a message naming the shell; and the documented meaning
of an empty workspace directory ("Empty inherits gpty's" cwd, `gpty-gdext/src/lib.rs`) is wrong -
the pane starts in `$HOME` (the prompt in the `agent-badges` capture reads `~` while the app's own
cwd is the repository). Fix: resolve the start directory in one place before the spawn - the
workspace directory when it is a directory, else gpty's own cwd when that is one, else `/` - pass it
explicitly so portable-pty's `$HOME` substitution is never reached, and correct both comments.
Tests: `HOME` set to a nonexistent path still spawns, and a pane with an empty workspace directory
starts where the resolver says.

## TERM-28

**The default shell is the user's shell, not `/bin/bash`** - verified: on a machine whose login
shell is `/bin/fish` (`$SHELL` and `getent passwd` agree), every pane ran `bash`
(`ps -p $$ -o comm=`), so the user's prompt, aliases and plugins were missing with no hint why.
`SettingsManager.default_shell_command()` returns the literal `/bin/bash` on every non-Windows
platform; on Windows it returns `%COMSPEC%`, i.e. `cmd.exe`, which is not what a Windows user opens
a terminal for. Fix: resolve the fresh-install default from `$SHELL`, validated by the same rule
`validate_executable` applies (absolute path, regular executable file), falling back to `/bin/bash`
then `/bin/sh`; on Windows prefer `pwsh.exe`, then `powershell.exe`, then `%COMSPEC%`, found by
absolute path. Settings → Terminal lists the detected shells (including installed WSL distributions)
as choices beside the free-text path, and shows what the default resolved to. A saved
`shell_command` is never overwritten. Two knock-on points to handle in the same item: the GUT suites
that rely on `default_shell_command()` for a POSIX shell (AGENTS.md "Testing") stop being
bash-by-construction, so they must pin a POSIX shell through a fixture helper; and the Workspace
Trust comparison is made against the user's configured default, so confirm a built-in or plugin
profile that names no program still never prompts.

## TERM-29

**A pane whose shell has exited says so and offers Restart or Close** - verified: after `exit` the
pane stays on screen with a cursor and no message, and `gpty list-panes` still counts it, so a
crashed shell, a dropped `ssh` or a finished command looks like a hung pane. The exit code is
already tracked (`TermStatus.exit_code`, `paneStatus`) but never shown. Fix: when the child has
exited, draw an unobtrusive footer ("Process exited (code N) - Enter to restart, Ctrl+Shift+W to
close") from the status the engine already reports; Restart re-spawns the pane's own spawn plan
(program, args and the user's own per-pane env) through the same `validate_executable` path and
keeps the pane's `attachment_id`; a Settings choice `On exit: keep / close` (default keep, so
scrollback stays readable). Tests: exit 0 and non-zero, Restart re-runs the same plan, and the pane
list and IPC state agree in both.

## TERM-30

**Text attributes the emulator parses are drawn: strikethrough, dim, hidden, curly/dotted/dashed/double underline and underline colour** - verified:
in a probe row of `ESC[1m` (bold), `[3m` (italic), `[4m` (underline), `[4:3m` (curly), `[9m`
(strike) and `[2m` (dim), bold, italic and underline render and the other three do not. Cause
(code): `CellInfo` in `term.rs` carries only `bold/italic/underline/inverse/wide`, so alacritty's
strikeout, dim, hidden and underline-variant flags (and the SGR 58 colour) are dropped before the
packer and the GUI never sees them; the exact flag set to carry is confirmed against
`alacritty_terminal`'s `Flags` at pickup. These are not exotic: nvim draws diagnostics with
undercurl, and many CLIs use dim for secondary text and strike for removed lines. Fix: replace the
bool fields with a small attribute bitfield packed into the existing flat arrays (no per-cell
`Dictionary`, per the AGENTS.md rendering note), thread it through the renderer-facing packer and
`terminal_pane.gd`'s run batching (a run breaks on an attribute change, as it already does for
underline), and draw strike as a rect, dim as the blended foreground, and undercurl as a
pixel-aligned zig-zag. **Must land before v0.10.0's grid wire protocol freezes the packed layout.**
Tests: a pixel diff against the current render for plain text and the three working attributes (the
v0.5.3 batching technique), plus one assertion per new attribute.

## TERM-31

**Box-drawing, block and braille characters are drawn by gPTY, not taken from the font** - verified:
`┌─┐│└┘` renders at the default 14 px with visible gaps and a missing corner; block elements and
braille are the same class. Font glyphs for these ranges are sized to the font's advance and ascent,
not to the cell, which has a fractional pixel size, so neighbours neither join nor tile. `htop`,
`btop`, `lazygit`, `tmux` borders and every TUI frame are built from them. Fix: draw U+2500–U+257F
(box drawing), U+2580–U+259F (blocks) and U+2800–U+28FF (braille) procedurally as pixel-snapped
rects in the cell's own rect, the approach Alacritty and kitty take, bypassing the font and leaving
the text-run batching untouched for everything else. Powerline separators rendered correctly from
the bundled DejaVu Sans Mono in the probe and stay font-drawn. Tests: a golden-pixel assertion that
horizontally adjacent `─` and vertically adjacent `│` cells meet with no gap at several font sizes,
including fractional cell sizes and the UI scale from the v0.8.0 theme item.

## TERM-32

**Fonts: a chosen family with a fallback chain, so Nerd Font icons and combining marks render** - verified
(symptoms), code (cause): Nerd Font private-use icons (`\uF015`, `\uF07B`, `\uF121`) rendered as
small placeholder shapes instead of icons, and `e` + U+0301 lost its accent; CJK, colour emoji and
Powerline separators rendered fine. Settings → Appearance offers a single font file (default
`DejaVuSansMono.ttf`), the code sets no explicit fallback list, and `CellInfo.ch` is a single
`char`, so a zero-width combining mark has nowhere to live (alacritty keeps them per cell; confirm
at pickup). Fix: a font picker over system monospace families plus a file, an ordered fallback list,
an optional bundled symbols-only fallback (a Nerd Fonts "Symbols Only" build - licence review at
design time, as in the Rust media backend item), and combining-mark support (carry the marks through
the packed grid and draw them on the base cell's origin). **Security coupling:** the typed,
extension-gated font loader this item builds on shipped in v0.7.1 as `TerminalFonts` (`FontFile`
from bytes, an absolute regular file, extension + magic + face checks; `.ttf`, `.otf`, `.ttc`,
`.woff`, `.woff2`, never a resource loader), so the picker, the ordered fallback chain (the loader
takes one path today) and combining-mark support are built on top of it.

## TERM-33

**A per-pane font is saved but overwritten on every restore, so a chosen font only survives in-session** - found
while closing the v0.7.1 resource-loading item: `Workspace._restore_into` applies a tile's settings
and then `SettingsManager.apply_to_terminal`, so the saved `font_path` loses to `cfg_font_path`; a
per-pane colour scheme no longer round-trips at all (the v0.7.1 fix made it runtime-only and stopped
saving it). Decide with the font picker and fallback chain above: either the tile wins for that pane
(the value is already validated by the closed settings table and `TerminalFonts`) or the global wins
and the pane panel stops offering a per-pane choice. Add the save → restore test for a chosen font,
which the fallback chain will need anyway.

## TERM-34

**A terminal pane spawned with `-c` can show an empty body after its command finishes** - found
2026-11-06 while recording `demo-panes`: two panes were spawned in one run -
`gpty new-pane -t terminal -c 'ls' --title files` (output rendered) and
`gpty new-pane -t terminal -c 'git log --oneline --graph' --title log`, whose body stayed blank for
the four seconds until the next cue, while the pane existed, was focused and drew its title, so the
spawn answered. The same `git log` injected into an interactive shell after spawn rendered at once,
which is what the shipped clip now does. Cause not measured: either the child's output raced the
pane's grid attach (spawn, write and exit inside one frame) or the pane clears its grid when the
child exits in the frame the first update is applied. Fix: capture
`-c 'echo one; sleep 0.2; echo two'` and `-c true` at spawn to separate the two, then keep the
grid's scrollback instead of resetting it on child exit; a regression test drives `-c` through
`newPane` and asserts the text is in `pane-read`.

## TERM-35

**A program's palette change is stored by the parser and then ignored by the renderer** - the set
half of the OSC colour family is already implemented one layer down: alacritty's `set_color` and
`reset_color` (in the `alacritty_terminal` 0.26.0 crate) write OSC 4/10/11/12 into `Term.colors` and
clear them for 104/110/111/112, exposed by `colors()`, whose `Colors([Option<Rgb>; COUNT])` type
indexes by `usize` and `NamedColor`, so a program's `ESC]11;rgb:08/08/08` parses cleanly. gPTY then
resolves every cell from its own 16-entry table instead: `TermGrid.palette`
(`crates/gpty-core/src/term.rs:175`) through `CellInfo::from_cell` (`:344`) and `color_to_rgb`
(`crates/gpty-core/src/color.rs:36`), where `Background` is `palette[0]`, `Foreground` is
`palette[7]` (`:47-48`) and the cursor colour comes from settings rather than `NamedColor::Cursor`.
So per-window theming - a shell writing its palette on start and resetting it on exit - is a silent
no-op, and that is how whole-environment theme kits bind one theme to one window without editing
terminal config. `TitleListener` (`term.rs:107`) drops every other `TermEvent`, which is the query
half covered by the row below. Fix: resolve Named and Indexed colours through `term.colors()` first
and the pane scheme second, draw the cursor from `Colors[NamedColor::Cursor]`, raise the same
full-damage flag `set_palette` raises, bound indices to the table, and keep it display-only and
session-scoped (a reset session starts from the pane's scheme, nothing is persisted). Tests: a shell
fixture emits OSC 4/10/11/12 then asserts packed cell RGB and the cursor colour, and 104/110/111/112
restore the scheme.

## TERM-36

**Answer the terminal-state queries the emulator raises: OSC 4/10/11/12 colours and text-area size** - code:
`TitleListener` in `term.rs` handles `Title` and `PtyWrite` and drops every other `TermEvent` into
`_ => {}`. alacritty raises colour-request and text-area-size-request events for OSC 4/10/11/12 and
`CSI 14/18 t` and expects the frontend to write the reply, so a program that asks for the terminal's
background or palette never gets an answer. nvim, `bat`, `delta` and `lazygit` use the background
query to pick a light or dark theme, and some wait out a timeout on every start. Not tested against
a specific program yet - the first step is to run those four and record which ones stall. Fix: reply
with fixed templates built from the pane's resolved palette (`TermGrid.palette` now carries
`.foreground`/`.background` beside the 16 ANSI entries, filled from the active scheme - 2026-11-20 -
so the reply reads them instead of assuming slots 7/0) and the cell and pixel size - the same class
as the cursor-position and mode reports already forwarded, so nothing from the stream reaches the
reply except the requested index - with a cap on pending replies per frame. Test: a real child (the
`ShellFixtures` pattern) sends the query and reads back `ESC]11;rgb:…` from the pane.

## TERM-37

**The bell is seen** - code: alacritty's bell event also falls into `_ => {}`, so `BEL` does nothing
(the probe's frame diff was too noisy to add evidence). Fix: a brief accent on the pane's title bar,
a badge on the pane's sidebar row and, when the pane is not in view, on its workspace row;
`DisplayServer.window_request_attention()` when the window is unfocused; an optional system sound; a
Settings choice `Bell: off / visual / visual + attention`, and a rate limit, because `cat` of a
binary rings thousands of times. No full-screen flash (reduced-motion friendly). Display only, and
nothing returns to the engine. The unseen-event marker introduced here is the one v0.9.5's activity
item reuses, so build it as a shared sidebar badge rather than a bell-only one.

## TERM-38

**The shell's working directory is known: OSC 7 as display, "new pane here" as the default** - verified:
after `cd /usr/share` in one pane, a new terminal started in `$HOME`, and no pane shows its
directory anywhere (title, status bar, pane list). Code: alacritty ignores OSC 7, so this needs a
bounded tap on the byte stream; the `gpty_state` OSC in `LineParser` is the precedent, and the tap
must obey the same alt-screen, capture-replay and resize suppression (confirm the right place at
pickup). Fix: parse `file://host/path`, accept only an empty or local host and an absolute path,
percent-decode with a length cap, reject control bytes, and expose the result as a display field in
`paneStatus` (like the exit code); show it in the pane title and status bar; make New Pane default
to the active terminal's cwd (a setting turns it off). For shells that never emit OSC 7 (bash and
zsh need a one-line hook, documented; fish emits natively), a Linux/macOS fallback from the shell's
pid. Restoring each pane's last cwd on app restart rides on this using only user-owned
`WorkspaceStore` state; layouts, profiles and plugin manifests stay unable to carry a cwd (the tile
schema is closed), and a cwd is only ever used as a spawn directory, never as a program or argument.
Tests: the parser accepts and rejects the forms above, the pane status carries the value, a new pane
inherits it.

## TERM-39

**Verify and fill the modern-TUI protocol set: kitty keyboard, focus reporting, synchronized output** - not
tested; code: `keymap.rs` cites the kitty keyboard protocol in its header, but no mode negotiation
or focus-reporting (DECSET 1004) or synchronized-output (DECSET 2026) handling turned up in the
crates. Start by measuring: a probe child that sends the keyboard-mode query and DECRQM for 1004 and
2026 and prints the replies, run with nvim, helix and lazygit; record what `alacritty_terminal`
already implements and what the pane drops. Then close the gaps in order of value: focus in/out
events on pane activation (nvim `autoread`, tmux), synchronized output (no tearing under flood,
which lines up with the flood cadence), and kitty keyboard disambiguation so `Ctrl+Shift` and
`Ctrl+Enter` chords reach TUIs distinctly. Document the supported set in the docs and AGENTS.md. **S
to measure, M to close.**

## TERM-40

**A terminal fidelity regression suite** - the probes behind this release (the attribute row, the
box/braille/CJK/emoji/combining row, `$SHELL`, exit, cwd, colour query, bell, OSC 52 denied by
default) were one-off scratch scripts; commit them as tests. Rust `TermGrid` tests assert the
per-cell attribute bits and combining marks; GUT integration tests drive a pane through
`ShellFixtures` and assert rendered pixels (the `draw_bench.gd` pixel-diff technique) for the
attribute and box-drawing cases, and read back the reply bytes for the query round trips. Add a
supported-sequences table to the docs: what is interpreted, what is deliberately ignored, and why.
Reference for that table, so the expected behavior is not invented from our own implementation:
[xterm Control Sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html) for what each
sequence means, iTerm2's `esctest` and `vttest` as conformance suites whose cases can be borrowed,
and UAX #11 (East Asian Width), UAX #29 (grapheme clusters) and UTS #51 (emoji) for cell advance and
cursor movement.

## TERM-41

**Close the loop: re-run the probes on the v0.9.2 build** - same sandbox, synthetic-input and
viewport-capture method, same fixtures; save the captures under `docs/static/images/`
(`v0.9.2_<n>.png` for the finished state, `issue-v0.9.2-<slug>.png` for anything still open, listed
under a Screenshots section in `screenshots/v0.9.md`); every item above is
closed or explicitly deferred with evidence, and the capture is the release's visual record.

## TERM-42

**Scrollback can be deleted: clear a pane, delete closed-pane history, delete everything** - code:
scrollback is plaintext on disk (SECURITY.md) and the app has no way to remove it.
`HistoryStore::clear()` deletes one pane's rows but only a test calls it. The only deletion in the
app is one sweep, 2 seconds after launch, of rows whose pane id is not open (`prune_missing_panes`),
so a closed pane's output stays on disk until the next launch. The `lines` table holds only the pane
id, the line number and the text, with no timestamps. Fix, in order. (1) *Clear scrollback and
history* for the active terminal, as a palette command (and what the v0.9.5 context menu's
`Clear scrollback` calls): it clears the pane's on-screen scrollback and deletes its stored rows.
Each pane's writer thread queues lines for up to about 200 ms, so the clear goes through that writer
or flushes it first, otherwise lines written just before the clear come back. (2) *Settings →
History*: shows the store size (`history_store_stats` already reports it) and offers
`Delete history of closed panes now`, which runs the launch sweep on demand, and
`Delete all history`, which asks first, states how many panes and how much it will remove, and says
that a live pane keeps what it shows on screen. (3) *Closing deletes*: an explicit GUI close of a
pane (titlebar X, `Ctrl+Shift+W`, the palette, the sidebar) deletes its rows at once instead of
leaving them for the next launch. Quit, a reset or layout load that restores panes under the same
`attachment_id`, and a type swap do not delete, and the launch sweep still reclaims whatever is
left. IPC `killPane` leaves its rows to that sweep too, so a program in a pane cannot erase history.
The v0.9.5 workspace-restore item changes the whole-workspace close, whose rows are then kept for a
bounded time. Not included: deleting by age for a live pane, which would need a timestamp on every
stored line, and the per-pane line cap already bounds the size. None of it is reachable over IPC,
the CLI or MCP. Tests: clear removes the pane's rows and nothing else, and a line queued before the
clear does not come back; the on-demand sweep keeps open panes; Delete all asks first and removes
every row; an explicit close deletes while quit and a same-id restore do not; the empty-list guard
in `prune_missing_panes` still holds.

## TERM-43

**International input works in a terminal pane: AltGr, dead keys and IME composition** - not tested;
first in the queue because it is a hard blocker for anyone who needs it and invisible to a developer
on a US layout. Probe first on Linux (X11 and Wayland), Windows and macOS: type `é` through a dead
key, `@` and `€` through AltGr on a German or Czech layout, and compose CJK through an IME into a
pane. Check that `key_event_to_bytes` (`keymap.rs`) does not swallow composed text, that AltGr is
not treated as Ctrl+Alt, and that the IME candidate window is positioned at the cursor cell. Fix
whatever the probe finds and add keymap unit cases for the layouts; the platform half goes into the
release verification, like the v0.8.0 assessment's platform note. **S to probe, M–L to fix depending
on findings.**

## TERM-44

**Mouse and clipboard basics: context menu, primary selection, copy-on-select, file drop** - code: a
terminal pane has no right-click menu, no primary-selection use (`clipboard_get_primary` /
`clipboard_set_primary`, i.e. Linux middle-click paste) and no `files_dropped` handler; the popup
menus that exist belong to pane swap and position. Fix: a right-click menu on terminal panes - Copy,
Paste, Select All, Search, Clear scrollback, Open link (when over one), and the pane actions (Zoom,
Duplicate, Settings, Close) - that respects mouse reporting exactly as today (Shift bypasses); there
is no Cut or Delete item: Copy reads the grid selection (`get_selection_text`) and Paste rides
`build_paste_payload`, so both are deterministic, while deleting text would have to synthesize
keystrokes into the child - see the future row *Deleting a double-clicked word from the shell's
input line* for why that cannot be made truthful today, and Copy already ends the selection, so a
copy-and-clear Cut would only add a misleading label; on Linux, selecting sets PRIMARY and
middle-click pastes it (a no-op elsewhere); a `Copy on select` setting whose default follows
platform convention (on for Linux, off elsewhere); dropping a file on a terminal inserts its path,
quoted for the pane's shell (POSIX single quotes, PowerShell `'…'`, cmd `"…"`), through the
bracketed-paste path so a newline or control byte in a file name cannot submit a line, and never
executes anything. Tests: a quoting table covering spaces, single and double quotes, a newline, a
leading `-` and non-ASCII names.

## TERM-45

**A double-click selects one cell and a triple-click cannot select a line** - code: `_handle_mouse`
(`godot/scenes/terminal/terminal_pane.gd:1369-1373`) starts a drag on every left press and ignores
`InputEventMouseButton.double_click`, so the second click lands on `_select_at` (`:1488-1495`) and
replaces the drag with a one-cell selection; the Rust side only ever builds `SelectionType::Simple`
(`crates/gpty-core/src/term.rs:658-664`), and `selection_extend` rebuilds the selection as Simple
too (`:671-694`), so the selection has no type to extend by. The engine already implements both
gestures: alacritty 0.26 has `SelectionType::Semantic` and `SelectionType::Lines`, and its
`range_semantic` expands over the default escape set (punctuation, quotes, brackets, space and tab)
and, for a single cell, runs `bracket_search` first, so a double-click on a bracket selects the
matched pair (the dependency at `crates/gpty-core/Cargo.toml:20`); gpty-core builds
`Config::default()` (`term.rs:221-223`), so that word set needs no new setting. Fix: store the
selection type beside `selection_anchor_at_start`; keep `selection_start` Simple so the drag is
unchanged; add `selection_select_word(row, col)` and `selection_select_line(row, col)` on the same
viewport-point path; make `selection_extend` rebuild with the stored type, so a drag after a
double-click extends by whole words and after a triple-click by whole lines (the xterm convention).
Export both through `crates/gpty-gdext/src/grid_api.rs:100-121` beside `selection_start`. Pane:
count presses in `_handle_mouse` (2 = word, 3 = line) using Godot's `double_click` plus the pane's
own count, reset on a click outside the pair so an unrelated later press is not a multi-click. The
highlight and copy need no new code: `get_selection_cells` returns ranges whatever the type
(`_refresh_selection`, `:1516-1520`), and `Ctrl+Shift+C` and the context menu's Copy read
`get_selection_text` (`:1617-1625`). A blank cell double-clicks to itself (space is an escape char),
and mouse reporting keeps today's rule: without Shift the app owns the click (`:1359-1368`), with
Shift the pane selects. Tests: Rust unit cases for a word across spaces, a tab and punctuation, the
bracket-pair case, a word start dragged left and right (whole words either way), a line selection's
text, and a semantic selection following output the way the Simple case already does
(`term.rs:1344-1400`); a new `godot/tests/integration/test_terminal_selection.gd` on the
`test_scrollback_return.gd` fixture (`:39-55`) prints a known line, sends double-click and
triple-click events to `_gui_input` with `InputEventMouseButton.double_click`, and asserts
`get_selection_text()` and that Shift is still required while the child reports the mouse.

## TERM-46

**A multi-line paste asks first when the shell cannot tell it from typing** - code: `Ctrl+Shift+V`
sends `build_paste_payload(clipboard, _is_bracketed_paste())` straight to the PTY. With bracketed
paste (DECSET 2004, which zsh, fish and current bash enable at the prompt) the shell holds the text
for review. Without it, which covers a plain `sh`, many SSH targets and any program that has not
asked for it, every newline in the text is Enter, so a pasted block of commands runs before the user
has read the last line. The existing guard strips control bytes and keeps newlines on purpose,
because a multi-line paste into a plain shell is a normal thing to want, so this item adds a pause
and does not remove the capability. Fix: when the pane is not in bracketed-paste mode and the
payload contains a newline, show a confirmation with the line count, the byte count and a preview
(at most 8 lines of 120 characters, control characters escaped, under the Workspace Trust text
rules) and two buttons, Paste and Cancel. Cancel has focus and Escape cancels, so the Enter that
habitually follows a paste cannot approve it. It covers every GUI paste route, so the middle-click
PRIMARY paste added by the mouse item above arrives with the guard and not before it; this item
lands no later than that one. Settings → Terminal gets
`Confirm multi-line paste: when the shell has no bracketed paste (default) / always / never`. A
single-line paste never asks. Nothing here touches `inject`, `pane-run` or any IPC path: those are
not pastes and are governed by their own targeting rules, so the sensitive-workspace rule is
unaffected. Tests: a table over bracketed or plain, one line, a trailing newline and several lines,
and the three settings, for whether the dialog appears; Cancel sends no bytes; Paste sends exactly
the bytes `build_paste_payload` returns; the default focus and the Escape behaviour.

## TERM-47

**Links: URLs, OSC 8 hyperlinks and `path:line` open from the terminal** - code: the terminal pane
has no URL handling and OSC 8 is not surfaced. Fix: detect `http(s)://` and `mailto:` in the visible
rows (underline on hover, Ctrl+click) and surface OSC 8 hyperlinks; open through the Markdown view's
existing confirm-then-`ExternalLink` path with the same scheme allow-list and nothing else (plugin
`[[link_handlers]]` stay unconsulted, per the 2026-10 decision). A `path:line[:col]` that resolves
to an existing regular file opens in a Code Viewer pane, scrolled to the line, through the file
tree's in-app route (`ViewableFiles`), resolved against the pane's cwd from the v0.9.2 OSC 7 item.
Detection runs Rust `regex` (linear time) over visible rows only. Because an OSC 8 label can differ
from its target, the confirmation shows the real target, escaped and capped under the Workspace
Trust text rules.

## TERM-48

**Shell integration: prompt marks (OSC 133), last-output actions and command status** - the
highest-leverage item in the release: output is one undifferentiated stream today. Fix: a bounded
tap for OSC 133 (`A` prompt start, `B` command start, `C` output start, `D;<exit>` end) records
marks against grid rows, persisted with scrollback in `HistoryStore` so they work after a restart
and, with v0.10.0, after a reattach; opt-in snippets for bash, zsh and fish in the docs, and
`gpty shell-integration <shell>` that prints the snippet and never installs it. Features: jump to
the previous or next prompt, select or copy the last command's output, an exit-status marker in the
gutter with the command's duration, and a user-initiated "Send last output to Inspector" using the
existing capture-to-Inspector route (display only; it never injects input). Security: marks are
display metadata and a program can forge them, so the worst case is a wrong highlight (state it in
`SECURITY.md`) and nothing may make a decision from them, the same rule as `paneStatus`; the `D`
field parses as a bounded integer; the tap obeys the alt-screen, capture-replay and resize
suppression; a security review is required before merge.

## TERM-49

**The pane settings' Foreground colour is settable and never drawn** - fixed 2026-11-20 with the
colour-scheme row: `GptyTerminal.set_default_colors(foreground, background)` writes
`Palette::foreground`/`background`, `CellInfo::from_cell` resolves
`NamedColor::Foreground`/`Background` through them, and `TerminalPane._apply_palette` now runs
unconditionally after `start_shell` (it used to run only when a scheme path was set, which is why
neither `default_fg` nor `default_bg` ever reached a no-scheme grid). `default_fg`'s default is
`Color8(229,229,229)`, the engine palette's white, so the no-scheme look is pixel-identical. Tests:
`a_cell_with_the_default_foreground_uses_the_palette_foreground`,
`palette_resolve_separates_foreground_from_white`, `test_the_ground_is_the_grid_background` (its
native-scheme half asserts the scheme's background and cursor).

Commits: 66a986c, 9571f98

## TERM-50

**A colour-scheme file edited in place is not picked up until restart** - `SchemeLibrary` caches a
parse by path and `TerminalPane` caches by path too, so editing `user://schemes/<id>.json` (the
natural workflow after importing and tweaking) changes nothing until the pane re-seats the path or
the app restarts; an import always writes a new file, so only hand edits are affected. Fix: key the
cache on `(path, size, mtime)` or add a Reload action on the picker, and a GUT test that rewrites a
file and re-reads it.

## TERM-51

**ConPTY passthrough mode** - `PSEUDOCONSOLE_PASSTHROUGH_MODE` (0x8, Windows 11 22H2+) makes ConPTY
relay the child's VT stream instead of re-rendering its own model, which would recover the
`gpty_state` OSC (see v0.5.4) and raw-sequence fidelity generally - cursor shapes, unrecognized SGR,
private sequences, and the repaint artifacts that come with a translated stream. Surfaced by the
Tier 2 Windows work, which measured the loss (a DECSET arrives, the OSC does not) and found the flag
defined-but-unused in portable-pty 0.9.0, which does not expose the creation flags at all: this
means gpty owning `CreatePseudoConsole` (raw externs, build-gated the way `pin_library` is) plus a
full Windows fidelity and regression pass over the pane lifecycle the v0.5.4 items just hardened
(spawn, resize, exit detection, process-group kill, mouse reporting). The flag also makes creation
fail on pre-22H2 builds, so it needs a fallback path. Not started: no evidence yet that the fidelity
gain justifies the spawn-path risk on the platforms the project still supports.

## TERM-52

**Program status reports (OSC 7501) are parsed, bounded and projected onto the badge** - the Program
Status Protocol (spec rev 0.4, `superlogical.com/rex/docs/build/program-status`) is the generic
terminal answer to "what is this program doing": `idle`/`working`/`done`/`blocked`/`error`/`clear`,
a `kind` with `blocked`, a `progress`, an `app` slug, a base64 `title`/`msg`, and a tree of records
under hierarchical ids. Both parsers drop it today: the line parser interprets only `gpty_state`
(`crates/gpty-core/src/parser.rs:239`) and alacritty's vte Performer ignores every OSC number it
does not know, so no program can reach the badge with the protocol. Fix: a new
`crates/gpty-core/src/program_status.rs` (grammar, record store, projection; no `vte` dependency)
plus one `osc_dispatch` branch and a `program_status` field on `TermGrid` beside the tracker
(`crates/gpty-core/src/term.rs:192`). Enforce the spec's limits before touching a record - 4096-byte
sequence, 16-byte key, 32-byte `app`, 128-byte id with 32 per segment and 8 levels, 2732/2048 `msg`
encoded/decoded, 256/192 `title`, 64 records with least-recently-updated eviction; skip a malformed
pair but discard the whole report on a limits break, undecodable base64, or a control character in
decoded text. Each report replaces its record completely; `clear` removes a subtree or everything;
RIS (`ESC c`) clears every record while DECSTR does not; OSC 133 `A` and child exit drop
`working`/`blocked`/`idle` and keep `done`/`error`; gate application on capture only, never on
alt-screen or the post-resize window, because agent TUIs live on the alt screen; strip
bidi/invisible formatting from `msg`/`title` before display. Project attention-first `blocked` >
`error` > `working` > `done` > `idle` onto `AgentState` at Tier 2, and ignore `gpty_state` for that
terminal from its first 7501 report until RIS. This is the second OSC the parser interprets, so the
row carries the security review `docs/content/docs/agents/security.md:41` requires: display only, no
report field ever written back or logged, limits checked first. Tests in the note (discard-vs-skip
rules, id grammar, base64 caps, lifetimes, LRU, projection, a 4096/4097-byte boundary) plus the
existing `gpty_state` tests unchanged.

## TERM-53

**A program that asks whether gPTY speaks OSC 7501 gets no answer** - the spec says a supporting
terminal MUST reply to `OSC 7501;?` with `?` and MAY list its `states` and `kinds`; a reply without
them means exactly the five states and three kinds. Nothing answers today, so a probing program
treats gPTY as unsupported and shows no status at all even though the parser work lands. Fix:
`OSC 7501;?` queues
`\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\x1b\\`
(byte-exact, pinned in the note), coalesced to one reply per `feed` and one per 100 ms per terminal.
The line parser has no PTY writer, so the reply must ride the existing emulator-reply queue
(`crates/gpty-core/src/term.rs:167`): the parser collects it, the engine queues it, and the existing
tail drain writes it with the rest of the DSR/mode replies (`crates/gpty-core/src/engine.rs:1034`);
a new `TermGrid.queue_reply` bounds the queue at 32. Tests: BEL and ST forms, one query in a
multi-report feed, the reply bytes and rate limit at parser+grid level; no report field is ever
written back.

## TERM-54

**Primary device attributes go unanswered, so the protocol's fallback probe waits out its timeout** - the
spec's detection recipe tells a program to send primary device attributes (`CSI c`) right after the
7501 query and treat a DA reply that arrives first as "protocol unsupported", so a program that
cannot read replies still gets a bounded answer. vte 0.15's Performer has no `c` arm and alacritty
does not answer DA1, so nothing comes back and a probing program spends its full timeout before
falling back - the terminal is the one part of the recipe that is missing. Fix: answer a bare
`CSI c` (and `CSI 0 c`) with `\x1b[?1;2c` (VT100 with advanced video) from
`LineParser::csi_dispatch` through the same bounded reply queue as the 7501 query. Tests: one
raw-grid feed of `CSI c` yields exactly one reply; the existing CSI handling is untouched.
Contingency in the note: if a future alacritty starts answering DA1, the one-reply test fails and
the parser's arm is deleted, so the terminal never double-answers.

## TERM-55

**Re-test the AT-SPI element-value mapping when an engine release carries it** - the v0.8.0 row
measured 4.7.2 (2026-11-05, the newest release): `AccessibilityServer.update_set_value` and
`update_set_role` never reach the exposed node, an element's name is the snapshot taken when it was
created, and the adapter serves `Name` as a property with no role method and no `Text`/`Value`
interface on a custom `Control`, so `A11y.set_value`/`set_text` only record a value AT cannot read.
The call side is fixed since v0.8.3: 4.7.2's server refuses `update_set_role`/`update_set_value`
outside `NOTIFICATION_ACCESSIBILITY_UPDATE` (two engine errors per launch before), so `A11y` queues
the pair and its host writes it from that notification - the re-test now grades the adapter's
mapping rather than a refused call. The app-side cost is closed (an idle pane no longer republishes
the node a reader is on, see the v0.8.0 row), so what remains is engine-gated. Evidence to start: an
engine newer than 4.7.2 whose adapter exposes a value or role path - `scripts/accessibility-probe`
prints an `a11y-values:` line (`text-interfaces`, `value-interfaces`, `marker-in-value`,
`role-names`) that grades it in one command. If it changes, the follow-up is to stop publishing text
nodes where the value now reaches AT, not to keep both. Re-measured 2026-11-13 on 4.7.2: the role
write now reaches - a terminal pane's element answers `GetRole` and exposes `org.a11y.atspi.Text` -
while `Text.GetText(0, -1)` on that element still answers `""` for a screen the app pushed, so an
element value carries nothing and the published name remains the only channel that works.

## TERM-56

**Terminal graphics protocols and font ligatures** - sixel and the kitty graphics protocol (image
previews in `yazi`, `chafa`, `timg`) and programming-font ligatures. Evidence-gated: none of these
is in any release, and the October 2026 assessment found no user demand for either, only that they
are absent. Graphics decode untrusted image data, so the media stance applies (memory-safe decoders
only, size caps, no sandboxing claim), and the grid's packed-array wire format has no image channel,
so it is a protocol addition for after v0.10.0. Ligatures need shaping across cell runs, which
conflicts with the per-cell run batching and the procedurally drawn box characters from v0.9.1.
Revisit with a concrete tool or user asking for either.

## TERM-57

**Translucent, optionally blurred window backgrounds** - evidence: the whole-environment theme kits
the colour work targets pair their palette with a background opacity near 0.97 and compositor blur,
and only the host window can honour either (a program in a pane can set an opaque colour, never an
alpha or a blur). gPTY paints the terminal background in Godot, so the background half is an alpha
on the palette background (the palette is `[u8;3]` through the FFI -
`set_background_color`/`palette[0]` in `crates/gpty-gdext/src/lib.rs` drop alpha - so it is a
representation change, not just a draw-time alpha; the window flag itself shipped with v0.8.6's
whole-window opacity); blur is platform-native (a compositor rule behind a Wayland/X11 window, DWM
acrylic on Windows, a visual effect view on macOS) and would sit behind a capability check with an
opaque fallback. The palette-background half is not started because no row needs it and the cost is
unmeasured; the probe that starts it: a transparent Godot window with the terminal drawn at 0.97
alpha on each platform, measuring text contrast on the composited result (WCAG, not the token's own
ratio) and cost per frame. The whole-window half shipped in v0.8.6 (**Window fit: opacity and inner
padding**): `Window.transparent` plus a faded `Workspace` root, hidden where the display server
reports no transparency. What remains here is the palette background's own alpha (the `[u8;3]`
representation change above, so the grid fades to the desktop without fading text and chrome) and
compositor blur.

## TERM-58

**Instanced-quad renderer (alacritty-style glyph atlas + per-instance color)** - evidence-gated: the
0.9.0 instrumentation is the measurement that would start it - revisit only if render batching plus
flood rate-limiting still shows frame-time pain. Godot already GPU-composites the canvas; a full
Rust-side texture pipeline is deep custom work (atlas management, eviction, per-cell truecolor
uploads) for a small incremental gain.

## TERM-59

**The view cannot reach scrollback older than the grid's 10,000 lines** - the new chevron jumps to
the oldest line the alacritty grid holds, and the grid is always built by `TermGrid::new`
(`crates/gpty-core/src/engine.rs:341`, `scrolling_history: 10_000`), so rows past that cap exist
only in the SQLite store (bounded by `History lines`, up to 100,000) and only the History search
reads them; a restore feeds the newest `history_lines` rows back into the same 10k grid and drops
the rest. Fix direction: a paged, read-only history surface that queries `HistoryStore` by line
number - not a larger grid cap, which is the per-pane memory bound the cap exists to keep. Evidence
to start: a user needs a line FTS finds but the viewport cannot scroll to.

## TERM-60

**Deleting a double-clicked word from the shell's input line** - requested 2026-11-17: double-click
a word inside the command being typed, then delete it, instead of reaching for the shell's own
`Ctrl+W` / `Alt+Backspace`. The idea is useful, but the terminal has no model of the line editor's
buffer, so the naive "move the cursor to the selection's end, send Ctrl+W" has four correctness
holes. (1) *No prompt boundary*: the grid knows the cursor cell (`get_cursor_row`/`get_cursor_col`,
`crates/gpty-gdext/src/grid_api.rs:15-30`) but not where the command starts, and OSC 133 is not
parsed (`crates/gpty-core/src/parser.rs:19-21` interprets only `gpty_state`), so a word highlighted
in the prompt - which is not in readline's buffer - would send the edit to the command instead,
deleting text the highlight never covered. (2) *Cells are not characters*: the grid stores a char
per cell plus `wide` and zero-width spacers (`crates/gpty-core/src/term.rs:50-60`, `:368`), so an
arrow count derived from columns lands in the wrong place in CJK, combining-mark or emoji text. (3)
*Ctrl+W is the child's widget, not the highlighted span*: readline's `\C-w` is `unix-word-rubout`,
which stops at whitespace (measured with `bind -p` on bash), while alacritty's semantic word splits
on commas, colons, quotes, brackets, spaces and tabs but not on `/`, `.`, `-` or `_` - so a
highlighted `foo:bar` and a kill-word disagree, and vi mode, fish and zsh widgets differ again. (4)
*The child may not be a line editor*: `cat`, `read`, a REPL, a TUI, an SSH target or a password
prompt takes the same bytes as data, so a "delete" can write a `^W` into a file or send it to a
remote host - the first UI action that would synthesize control input from screen contents, which
the paste filter in `docs/content/docs/agents/security.md:11` exists to prevent. Nothing verifies
the result either: the app cannot tell whether the child removed the highlighted span or a different
one, and there is no undo. A right-click `Delete word` item is the right form of the risky version -
explicit, with no accidental-chord risk - but it is the same synthetic edit and inherits all four
holes, so the context-menu row in v0.9.5 deliberately carries no Cut or Delete; Copy and Paste there
are unaffected because neither edits the child's buffer. Clicking in the command to place the cursor
is the same class with a lower risk - a move is non-destructive - but it still needs the command
boundary and it must send Up/Down, whose meaning in a multi-line buffer is the child's binding, not
a protocol, so a click can land the edit in a recalled history entry; it is not queued because the
shells' edit-command binding (see the v0.9.5 Keybindings row) already edits the exact buffer. What
would start it: the v0.9.5 shell-integration row's OSC 133 marks, plus a design where the action is
explicit (a context-menu `Delete word`, not a bare chord), the selection lies wholly inside the
command span, and the primitive is Backspace times the selected *characters* rather than a shell
kill word - then a probe across bash, zsh and fish in emacs mode showing the delete removes exactly
the highlight. Even then a program can echo the marks itself, so the action stays a heuristic and
must be described as one.

## TERM-61

**Windows foreground-job detection** - the close confirmation's `foreground_job` is exact on Unix
(`tcgetpgrp`) and `null` on Windows/ConPTY, so the GUI treats every live shell as possibly busy:
closing or quitting with any terminal open raises the confirmation even at an idle prompt (the
v0.7.0 item's documented fallback). If that proves noisy in use, the fix is a Windows-side
direct-child snapshot (`CreateToolhelp32Snapshot` + `Process32NextW`, the raw-extern pattern
`pin_library`/`win_peer` already use) compared against the shell pid - conservative in the other
direction (a background child counts) but far closer than "any live shell". No change until it is
observed to annoy; the safe half is already in place.

## TERM-62

**The PTY feed parses every output byte twice** - code: `run_terminal_task` calls
`line_parser.feed(&bytes)` for concepts, Tier 3 failure patterns and scrollback
(`crates/gpty-core/src/engine.rs:854`), then `feed_grid(&grid, &bytes)` for the rendered grid
(`crates/gpty-core/src/engine.rs:962`), and each parser runs vte over the same 4 KiB chunk (with the
escape-string guard in front of each until the scan row above lands). The second parse exists
because the line parser must commit lines the grid does not expose as text (bare-CR stashes, ConPTY
cursor-row moves, the `gpty_state` declaration), so removing it means deriving lines from the grid's
damage and history, or tapping one parser, and the replacement has to pass the existing `LineParser`
tests. Evidence to start: the v0.9.0 hot-path timers, or a profile that attributes the `engine.rs`
feed span between the two parses; act only if the line parser is more than a quarter of the feed.
Supporting analysis: `TEMP/simd-opportunities.md`.

## TERM-63

**The terminal still segments a row's text runs in GDScript** - evidence: the v0.9.0 row **A row's
text band is rebuilt one character at a time, and every row re-reads the same cache** gates on
`draw_bench` `forced_us` down 15% at 200x60; if that gate misses, the next step is
`get_row_runs(row)` in Rust returning flat `starts`/`texts`/`fg`/`flags` per damaged row, so
GDScript keeps only `draw_string`/`draw_rect`. Do not start without that number: the current
per-cell work is a known, bounded cost and moving run segmentation adds an FFI payload to every
damaged row. Supporting analysis: `TEMP/gdscript-opportunities.md`.
