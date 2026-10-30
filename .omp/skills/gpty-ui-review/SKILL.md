---
name: gpty-ui-review
description: "Observe, capture and judge gpty's real UI: sandboxed fresh-state launch, app-viewport PNG evidence, the defect classes the audits keep finding, and demo re-record checks. Use for UX audits/re-baselines, release or issue screenshots, and \"does this UI look right\" questions."
---

# gpty UI review

A router plus the operational recipe. The method is normative in `docs/content/docs/agents/testing.md` ("UI/UX assessment method"); release sequencing and image naming are in `skill://release` step 6; the demo recorder documents itself in the `scripts/record-demo` header; runtime/crash/perf checks belong to `skill://gpty-live-gui-smoke`.

## Do not

- **Do not write a UI inventory** ("the sidebar lists X, the palette offers Y", every control and its behaviour). Every v0.8.0 GUI row changes the UI, so a written inventory is stale the moment it is committed and an agent trusting it is worse off than one that looks. Enumerate the surface by running the app and reading `godot/scenes/`: `ui/sidebar.gd`, `ui/status_bar.gd`, `ui/settings_panel.gd`, `ui/window_chrome.gd`, `ui/palette.gd` (colours), `panes/pane_types.gd` (pane types and palette commands).
- Do not commit an audit report or a design review. Findings and outcomes become roadmap rows (repo rule); only the captures a row points at are kept.
- Do not modify project files while assessing. The one exception is the staging scene below, deleted after the capture.

## Launch a deterministic instance

Fresh first-run state, private everything — a live GUI on the desktop owns the control socket and the sandboxed app renders "Another gPTY window is already running — this one will close." instead of the app:

```bash
RT=$(mktemp -d); ST=$(mktemp -d); chmod 700 "$RT" "$ST"
XDG_DATA_HOME="$RT/data" XDG_CONFIG_HOME="$RT/config" XDG_RUNTIME_DIR="$RT" \
XDG_STATE_HOME="$ST" GPTY_SOCKET="$RT/gpty.sock" env -u GPTY_SECRET <app-command>
```

`scripts/screenshot-gpty` sandboxes only data/config, so this outer wrapper is still required (queued fix: v0.8.0 BUILD row). Build first (`cargo build --workspace`): panes spawn `target/debug/gpty`.

## Capture

- **Evidence is the app's own viewport**, never a desktop grab: `root.get_texture().get_image().save_png(path)` after `await RenderingServer.frame_post_draw`. Working precedent: `godot/tests/bench/draw_bench.gd:112`.
- Needs a real display driver (`DisplayServer.get_name() != "headless"`). Under `--headless` there is no redraw pass: `frame_post_draw` never fires and a script awaiting it hangs. Pass `--disable-vsync` so a vsync-locked present cannot block on a window the compositor never shows.
- This path is the portable one — it does not need XWayland. `scripts/screenshot-gpty` (x11grab) and `scripts/record-demo` are X11/XWayland-only and fail on a pure Wayland session.
- Desktop grabs are only for release/blog images, where the OS window itself is the point.
- Small windows (800×500, 560×340) go in an embedded viewport: accurate for layout, **not** for OS window behaviour. Say so when the finding is about window managers.
- Stage a state that needs clicks with a temporary scene inside the project (`godot/tmp_capture.tscn` + `.gd`: a `Control` whose `_ready` seeds state through the real autoloads, opens the overlay, idles). Never stage through GUT — a non-headless GUT run captures GUT's runner panel instead of the app. Delete both files afterwards.
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

## Output contract

- Findings → roadmap rows in the owning release, each naming the evidence and the severity word; the release's Screenshots section carries the captures.
- `docs/static/images/issue-v<build>-<slug>.png` for a finding (a recapture adds a new file, never overwrites); `v<ver>_<n>.png` for the finished release state.
- Scratch drivers are not committed unless promoted into the terminal fidelity suite. The capture harness row in v0.8.0 is what removes that step.

## Demo re-records

`scripts/record-demo hero|tour` — the header is the usage source (sandbox, seeded workspace, CLI-driven, no synthetic input). Judgment the header does not carry:

- Verify the **encoded** output (GIF frames, not the raw capture): legibility at `GIF_WIDTH`, caption pacing, no frame where a pane is mid-repaint.
- Re-record whenever a UI change lands in the recorded workspace — the README embeds the GIF.
- The queued "one video per workflow" item wants one scenario per workflow, each end to end, plus an OMP-specific cut; extend the scenario table in the script rather than adding a second recorder.

## Maintenance

- **The scratch-driver step is temporary.** When v0.8.0's *The UI audit has a committed capture harness* row lands, replace the staging-scene and viewport-capture bullets with the committed driver (`godot/tests/bench/ui_capture.gd`, `scripts/screenshot-gpty --state`). The defect classes, the severity vocabulary and the vision-pass limits stay as written.
- **The sandbox wrapper is temporary too.** *The release screenshot script captures a doomed second instance* moves the runtime/socket sandbox into `scripts/screenshot-gpty`; when it lands, the wrapper above shrinks to "the script sandboxes itself".
- **The defect classes are dated October 2026.** Re-derive them from the current audit once the v0.8.0 rows close, instead of trusting this list as a description of the current UI.
