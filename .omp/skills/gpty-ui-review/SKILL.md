---
name: gpty-ui-review
description: "Observe, capture and judge gpty's real UI: sandboxed fresh-state launch, app-viewport PNG evidence, the defect classes the audits keep finding, and demo re-record checks. Use for UX audits/re-baselines, release or issue screenshots, and \"does this UI look right\" questions."
---

# gpty UI review

A router plus the operational recipe. The method is normative in `docs/content/docs/agents/testing.md` ("UI/UX assessment method"); release sequencing and image naming are in `skill://release` step 6; the demo recorder documents itself in the `scripts/record-demo` header; runtime/crash/perf checks belong to `skill://gpty-live-gui-smoke`.

## Do not

- **Do not write a UI inventory** ("the sidebar lists X, the palette offers Y", every control and its behaviour). Every v0.8.0 GUI row changes the UI, so a written inventory is stale the moment it is committed and an agent trusting it is worse off than one that looks. Enumerate the surface by running the app and reading `godot/scenes/`: `ui/sidebar.gd`, `ui/status_bar.gd`, `ui/settings_panel.gd`, `ui/window_chrome.gd`, `ui/palette.gd` (colours), `panes/pane_types.gd` (pane types and palette commands).
- Do not commit an audit report or a design review. Findings and outcomes become roadmap rows (repo rule); only the captures a row points at are kept.
- Do not modify project files while assessing. A surface that needs a capture becomes a `STATES` entry in the committed driver; nothing is staged in a temporary scene any more.

## Launch a deterministic instance

`scripts/ui-capture <state> <out-dir>` stages a committed state in a private sandbox and writes the app's own viewport (`scripts/ui-capture --list` prints the states). `scripts/screenshot-gpty --state <name>` stages the same state behind a desktop grab. Both source `scripts/ui-sandbox`, which creates a 0700 temp root and exports `HOME`, the `XDG_*` directories, `GPTY_TEST_USER_DIR` and `GPTY_SOCKET`, and clears `GPTY_SECRET` plus login/prompt variables — without the runtime/socket parts, a live GUI on the desktop owns the control socket and the sandboxed app renders "Another gPTY window is already running — this one will close." instead of the app. Build first (`cargo build --workspace`): panes spawn `target/debug/gpty`.

## Capture

- **Evidence is the app's own viewport**, never a desktop grab: the driver (`godot/tests/bench/ui_capture.gd`) saves `root.get_texture()` after `await RenderingServer.frame_post_draw`. A real display driver is required (`--headless` has no redraw pass: `frame_post_draw` never fires and a script awaiting it hangs); `--disable-vsync` keeps a vsync-locked present from blocking on a window the compositor never shows.
- This path is the portable one — it does not need XWayland. `scripts/screenshot-gpty` (x11grab) and `scripts/record-demo` are X11/XWayland-only and fail on a pure Wayland session.
- Desktop grabs are only for release/blog images, where the OS window itself is the point.
- Small windows (800×500, 560×340) resize the root viewport, so the image is the layout at that size, **not** OS window behaviour. Say so when the finding is about window managers.
- **A state that needs clicks or keys is a `STATES` entry, not a temporary scene.** The table seeds through `WorkspaceStore` (real restore path), drives the visible controls with synthetic input, and waits for grid generations, pane titles and the toast queue to settle; overlays are opened through their real controls (the sidebar Settings button, the pane title bar's settings button, Ctrl+Shift+P, the Concepts tab's Open Visual Editor). The five surfaces the October 2026 pass missed are states now (`wiki-vault`, `wiki-graph`, `concept-editor`, `plugin-review`, `workspace-trust`). Never stage through GUT — a non-headless GUT run captures GUT's runner panel instead of the app.
- **Keyboard reachability is measured, not eyeballed.** `scripts/ui-capture --audit-focus <state>` stages the same state and prints the focus owner, the visible dialog's own focus owner, whether Escape closes the surface, every visible `FOCUS_NONE` button, and the Tab order. A control with no key path is a finding even if a shortcut exists for one of its siblings; a modal that focuses its OK button and closes on Escape is a pass, so say that too.
- Two runs of one state are pixel-identical: the status bar's clock and FPS are pinned, cursor blink is off, and the pointer is parked. `scripts/ui-capture-check` proves that and that a perturbed control changes exactly one image; run it after touching the driver, the state table or a widget the states show.
- Size the window to something that fits a *physical* screen (`DisplayServer.screen_get_size()` can report a multi-monitor desktop much larger than any single screen; an off-screen window captures clipped).

## Judge

- The vision pass is advisory: ask for defects only (giant overlays, clipped controls, overlapping sections), and treat every text reading as unverified until checked in source.
- Vision misses thin 1 px wires and gaps, small text, subtle contrast, and off-by-one clipping — prefer objective probes for geometry (connection counts, `Rect2` intersection, sampled pixels). `godot-graph-edit-canvas` learned this the hard way.
- Contrast is a WCAG ratio computed from `ui/palette.gd` constants or sampled pixels, not an impression.
- Back styling claims with a count: `add_theme_*_override` calls, hard-coded `Color(...)` literals, font sizes outside the scale.
- Mark every finding **verified** / **observed** / **code** (+ *not tested*, *measured* for probes). List what was not examined and queue it as a row instead of dropping it.

## Defect classes the October 2026 audit kept finding

Check all ten on every pass; each maps to at least one v0.8.0 row:

1. Translucent `Panel` defaults — content bleeding through overlays.
2. Empty states: project clear colour, no guidance, no CTA.
3. Overlay focus: focus never grabbed (type-cast, not `find_child("*")`), list empty until typed, Escape not handled once focused, Enter only runs the first match, no arrow selection.
4. Small-window clipping: panels spilling over the sidebar, titles running under their own buttons, lists cut after one row.
5. Stock-Godot `Window`/`AcceptDialog`/`ConfirmationDialog` styling, clipped form fields, jargon labels.
6. Discoverability: icon-only controls, tooltip-only names, shortcuts listed nowhere, dropdowns that read "OS".
7. Icon semantics: one glyph for destructive and benign actions, five duplicated buttons per pane row, current state unmarked in the type-swap menu.
8. State feedback: no search match count or next/prev, toasts stating the obvious, unset values rendered as unexplained checkerboards.
9. Padding/alignment: text touching pane edges, inconsistent empty-state quality across panes.
10. Keyboard-only reachability for everything above.
11. App-chrome keyboard reachability: pane title bars, the Wiki toolbar and the vault graph are `FOCUS_NONE` (`--audit-focus` measures it).
12. Overlay canvases that inherit the theme's translucent `Panel` (Settings, Pane Settings, the concept editor's `GraphBg`).
13. State signalled by colour alone (the agent-state badge's failed vs needs-attention).
14. Graph label collisions at density (labels drawn for every node).

## Output contract

- Findings → roadmap rows in the owning release, each naming the evidence and the severity word; the release's Screenshots section carries the captures.
- `docs/static/images/issue-v<build>-<slug>.png` for a finding (a recapture adds a new file, never overwrites); `v<ver>_<n>.png` for the finished release state.
- A capture surface is a `STATES` entry in `godot/tests/bench/ui_capture.gd`; the driver is committed, so no scratch script or temporary scene is written for an audit. Only the captures a row points at are kept.

## Demo re-records

`scripts/record-demo hero|tour` — the header is the usage source (sandbox, seeded workspace, CLI-driven, no synthetic input). Judgment the header does not carry:

- Verify the **encoded** output (GIF frames, not the raw capture): legibility at `GIF_WIDTH`, caption pacing, no frame where a pane is mid-repaint.
- Re-record whenever a UI change lands in the recorded workspace — the README embeds the GIF.
- The queued "one video per workflow" item wants one scenario per workflow, each end to end, plus an OMP-specific cut; extend the scenario table in the script rather than adding a second recorder.

## Maintenance

- **A new audited surface is a new state.** Add it to `STATES` in `godot/tests/bench/ui_capture.gd` (a window size, a pane count, the interaction its `open`/`close_all` keys name) and run `scripts/ui-capture-check`: two runs must be pixel-identical, and perturbing one state must change that state's image only. A state that needs a control no other state shows can use the same `_perturb` branch.
- **The defect classes are dated October 2026.** Re-derive them from the current audit once the v0.8.0 rows close, instead of trusting this list as a description of the current UI.
