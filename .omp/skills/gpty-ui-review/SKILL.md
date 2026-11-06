---
name: gpty-ui-review
description: "Observe, capture and judge gpty's real UI: sandboxed fresh-state launch, app-viewport PNG evidence, the defect classes the audits keep finding, and demo re-record checks. Use for UX audits/re-baselines, release or issue screenshots, and \"does this UI look right\" questions."
---

# gpty UI review

A router plus the operational recipe. The method is normative in `docs/content/docs/agents/testing.md` ("UI/UX assessment method"); release sequencing and image naming are in `skill://release` step 6; the demo recorder documents itself in the `scripts/record-demo` header; runtime/crash/perf checks belong to `skill://gpty-live-gui-smoke`.

## Do not

- **Do not write a UI inventory** ("the sidebar lists X, the palette offers Y", every control and its behaviour). Every v0.8.0 GUI row changes the UI, so a written inventory is stale the moment it is committed and an agent trusting it is worse off than one that looks. Enumerate the surface by running the app and reading `godot/scenes/`: `ui/sidebar.gd`, `ui/status_bar.gd`, `ui/settings_panel.gd`, `ui/window_chrome.gd`, `ui/ui_palette.gd` (every colour, in a complete dark and a complete light set, read through `active()`), `ui/ui_tokens.gd` (sizes, spacing and the WCAG maths), `ui/ui_theme.gd` (what the theme does to each type, and its colour roles), `ui/app_dialog.gd` (modals), `panes/pane_types.gd` (pane types and palette commands).
- Do not commit an audit report or a design review. Findings and outcomes become roadmap rows (repo rule); only the captures a row points at are kept.
- Do not modify project files while assessing. A surface that needs a capture becomes a `STATES` entry in the committed driver; nothing is staged in a temporary scene any more.

## Launch a deterministic instance

`scripts/ui-capture <state> <out-dir>` stages a committed state in a private sandbox and writes the app's own viewport (`scripts/ui-capture --list` prints the states). `scripts/screenshot-gpty --state <name>` stages the same state behind a desktop grab. Both source `scripts/ui-sandbox`, which creates a 0700 temp root and exports `HOME`, the `XDG_*` directories, `GPTY_TEST_USER_DIR` and `GPTY_SOCKET`, and clears `GPTY_SECRET` plus login/prompt variables — without the runtime/socket parts, a live GUI on the desktop owns the control socket and the sandboxed app renders "Another gPTY window is already running — this one will close." instead of the app. Build first (`cargo build --workspace`): panes spawn `target/debug/gpty`.

## Capture

- **Evidence is the app's own viewport**, never a desktop grab: the driver (`godot/tests/bench/ui_capture.gd`) saves `root.get_texture()` after `await RenderingServer.frame_post_draw`. A real display driver is required (`--headless` has no redraw pass: `frame_post_draw` never fires and a script awaiting it hangs); `--disable-vsync` keeps a vsync-locked present from blocking on a window the compositor never shows.
- This path is the portable one — it does not need XWayland. `scripts/screenshot-gpty` (a desktop grab) and `scripts/record-demo` are X11/XWayland-only and fail on a pure Wayland session.
- Desktop grabs are only for release/blog images, where the OS window itself is the point.
- Small windows (800×500, 560×340) resize the root viewport, so the image is the layout at that size, **not** OS window behaviour. Say so when the finding is about window managers.
- **A state that needs clicks or keys is a `STATES` entry, not a temporary scene.** The table seeds through `WorkspaceStore` (real restore path), drives the visible controls with synthetic input, and waits for grid generations, pane titles and the toast queue to settle; overlays are opened through their real controls (the sidebar Settings button, the pane title bar's settings button, Ctrl+Shift+P, the Concepts tab's Open Visual Editor). The five surfaces the October 2026 pass missed are states now (`wiki-vault`, `wiki-graph`, `concept-editor`, `plugin-review`, `workspace-trust`). Never stage through GUT — a non-headless GUT run captures GUT's runner panel instead of the app.
- **Keyboard reachability is measured, not eyeballed.** `scripts/ui-capture --audit-focus <state>` stages the same state and prints the focus owner, the visible dialog's own focus owner, whether Escape closes the surface, every visible `FOCUS_NONE` button, and the Tab order. A control with no key path is a finding even if a shortcut exists for one of its siblings; a modal that focuses its OK button and closes on Escape is a pass, so say that too. The walk reports every traversal component, not the first ring: `tab-order` is the component the keyboard starts in (the focus owner first), `ring[n]`/`flow[n]` are the rest, and `components=/rings=/reached=` says whether the whole surface was reached (`reached` should equal `focusable` when every focusable control has a key path). A component printed as a `flow` is one that never closes on its own first member — a ring leaking into a neighbour's stops. Read the `mouse-only` lines too, and stage a state whose first focusable control is the surface you mean. The accessible half is its own mode: `scripts/ui-capture --audit-accessibility <state>` prints every named control with its description and live mode, any recorded value, and each glyph-only button with no name (`unnamed=0` is the pass - a name is words, not the codepoint a `Button`'s text would announce). The exposed AT-SPI tree is not visible from the editor build (no AccessKit driver): it needs `./scripts/build` and `scripts/accessibility-probe`, which asserts the names and the terminal's published text against the running export and prints a report-only `a11y-values:` line (Text/Value interfaces, whether the typed marker reaches either, the adapter's role names) - the value/role answer, which on 4.7.2 is nothing at all, so that line is the re-test on a newer engine.
- Two runs of one state are pixel-identical: the status bar's clock and FPS are pinned, cursor blink is off, and the pointer is parked. `scripts/ui-capture-check` proves that and that a perturbed control changes exactly one image; run it after touching the driver, the state table or a widget the states show.
- Size the window to something that fits a *physical* screen (`DisplayServer.screen_get_size()` can report a multi-monitor desktop much larger than any single screen; an off-screen window captures clipped).

## Judge

- The vision pass is advisory: ask for defects only (giant overlays, clipped controls, overlapping sections), and treat every text reading as unverified until checked in source.
- Vision misses thin 1 px wires and gaps, small text, subtle contrast, and off-by-one clipping — prefer objective probes for geometry (connection counts, `Rect2` intersection, sampled pixels). `godot-graph-edit-canvas` learned this the hard way.
- Contrast is a WCAG ratio computed from `ui/ui_palette.gd` (its `CONTRAST_PAIRS` table, graded against both sets by `tests/unit/test_ui_palette.gd`) and `ui/ui_tokens.gd`'s `contrast_ratio()`, or sampled pixels, not an impression. A palette claim is checked in **both** sets: a colour that only passes on dark is a light-theme defect.
- Back styling claims with a count: `add_theme_*_override` calls, hard-coded `Color(...)` literals, font sizes outside the scale. `grep -rn "add_theme_color_override" godot/scenes` must print nothing: a colour role is a `Theme` type variation (`UiTheme.MUTED_LABEL`/`DANGER_LABEL`/`WARNING_LABEL`/`ACCENT_BUTTON`), because an override pins the palette the widget was built under.
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
11. App-chrome keyboard reachability: pane title bars, the Wiki note toolbar and the vault graph each need a key path (`--audit-focus` measures it). The three rings are the current answer — `Ctrl+Shift+E` for a title bar, `Ctrl+Shift+K` for the note toolbar, arrows/`+`/`-`/Enter on the graph canvas — so a control added to any of them that is `FOCUS_NONE`, or a `FOCUS_NONE` canvas that is the whole surface, is a finding.
12. Overlay canvases that inherit the theme's translucent `Panel` (Settings, Pane Settings, the concept editor's `GraphBg`).
13. State signalled by colour alone. The report's own example - the agent-state badge's failed vs needs-attention - is closed: every state has its own glyph, the state word is both its tooltip and its accessible name, and its live region announces a change (v0.8.0 row with the same title). Do not re-report it; a new status surface must carry a second channel (shape, text, position) plus a text form an assistive technology can read.
14. Graph label collisions at density: every node labelled at the fitted zoom prints titles on top of each other — `VaultGraphView.label_placements` culls them now, so a new label source (or a new canvas) must go through that placement, and a label outside the fitted view is a finding (`fit_to_view` reserves their width).

## Output contract

- Findings → roadmap rows in the owning release, each naming the evidence and the severity word; the release's Screenshots section carries the captures.
- `docs/static/images/issue-v<build>-<slug>.png` for a finding (a recapture adds a new file, never overwrites); `v<ver>_<n>.png` for the finished release state.
- A capture surface is a `STATES` entry in `godot/tests/bench/ui_capture.gd`; the driver is committed, so no scratch script or temporary scene is written for an audit. Only the captures a row points at are kept.

## Demo re-records

`scripts/record-demo <showcase|panes|agents|concepts|wiki|media|cli-view>` - the header is the usage source (sandbox, seeded workspace, CLI-driven, no synthetic input). One scenario is one workflow: `showcase` is the README's always-visible clip, the rest sit behind `<details>` there and under one homepage section each. Judgment the header does not carry:

- Verify the **encoded** output (GIF frames, not the raw capture): legibility at `GIF_WIDTH`, caption pacing, no frame where a pane is mid-repaint.
- A cue that prints an error, or a pane that renders blank, is a finding - not something to crop or caption around: fix the cue, and queue what the product did as a roadmap row. Three cues in the 2026-11-06 set surfaced exactly that way (an unregistered vault root, a `cli_view` child in the wrong directory, a `-c` pane with an empty body).
- Re-record whenever a UI change lands in a recorded workspace - the README and the homepage embed the clips.
- Add a workflow by adding a `LAYOUTS` entry, a cue arm and a `case` name, never a second recorder. A pane whose settings the CLI cannot pass (no `--settings` on `new-pane`) is seeded in the layout instead of spawned by a cue, or the cue spawns a terminal that runs the command.

## Maintenance

- **A new audited surface is a new state.** Add it to `STATES` in `godot/tests/bench/ui_capture.gd` (a window size, a pane count, the interaction its `open`/`close_all` keys name, and a `ui_scale` percentage when the surface is the scale itself - `_run` applies it before the scene exists, because the workspace lays itself out against the window's content scale on its first frame) and run `scripts/ui-capture-check`: two runs must be pixel-identical, and perturbing one state must change that state's image only. The check perturbs `settings` when the list has it and the first named state otherwise (`--perturb` overrides), and a state with neither an overlay nor a pane cannot be the target - the harness fails naming that reason instead of leaving the images identical. Anything the harness itself varies must be pinned the same way: a state that renders a per-run path (the sandbox's `HOME` under `/tmp/gpty-ui.<random>`) is never identical twice, so `file-dialog` points the picker at `/` after it opens. A state that needs a control no other state shows can use the same `_perturb` branch. A state that *stages an animation* must pin it in the staging code, because a wall-clock animation never repeats: `agent-badges` declares its four states through the engine (`set_agent_state`), waits for the badges to paint, then re-applies the state and stops the pane's per-frame work, which pins the spinner and the attention pulse to the frame a user sees when the badge appears.
- **The defect classes are dated October 2026.** Re-derive them from the current audit once the v0.8.0 rows close, instead of trusting this list as a description of the current UI.
