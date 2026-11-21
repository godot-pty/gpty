---
name: gpty-add-effect
description: "Adding a built-in terminal effect to gPTY: an ambient shader behind the text or a reactive concept cue - the closed table, pane schema mirror, settings UI, capture state and bench."
---

# Adding a terminal effect

An effect is code, so it is a closed-table entry - never a path from a profile, settings file or plugin. The table is `godot/scenes/ui/ui_effects.gd`; a pane never holds a shader path, only an id.

## Ambient (a shader behind the terminal text)

1. `godot/scenes/ui/ui_effects.gd` - add the entry to `AMBIENT` and its id to `AMBIENT_IDS`: `label`, `shader` (`preload("res://shaders/effects/<id>.gdshader")`), `animated`, `hz` (0 static, at most 30 animated), `budget_ms_1080p`, `budget_ms_4k`, `hint`. A static entry's budgets are 0 because it is not evaluated per frame; an animated one renders in the half-resolution `SubViewport` at its `hz`.
2. `godot/shaders/effects/<id>.gdshader` - `canvas_item` with `strength`, `rows` and `quad_px` (plus `phase` only on the animated half). Never `TEXTURE` or `SCREEN_PIXEL_SIZE`: the pane issues one `draw_rect` carrying the ground in `COLOR`, and a material on the grid itself would run once per band and per glyph run with the font atlas as its texture. Add the comb additively so it reads on a black ground; a multiply-only term is invisible there.
3. `godot/scenes/panes/pane_types.gd` - add the id to `TERMINAL_SETTINGS["effect"]["values"]`. That literal is the `-s` entry-point-safe copy of the table (naming `UiEffects` in that script would pull `SettingsManager` into a pre-autoload compile); `file` and `ipc` stay false. `test_ui_effects.gd`'s seam test fails if the two lists drift.
4. Tests: `test_ui_effects.gd` covers the table shape; `test_pane_effects.gd` covers the layer order, the skipped default-background run, the static material and the half-resolution buffer. A new animated effect needs its own buffer assertion.
5. `godot/tests/bench/ui_capture.gd` - a state setting `cfg_effect`/`cfg_effect_intensity`. An animated one is pinned by the driver's `_pin_effects` (it calls `pin_effects()` on every state's bodies, untyped because the driver is a `-s` script). Commit the PNG as `docs/static/images/v<release>_<state>.png` and add it to the chain page's Screenshots with a caption that names the row.
6. `godot/tests/bench/effect_bench.gd` - run `BENCH_EFFECT=<id>` at 1080p and 4K on real hardware and put the medians in the table. A session on llvmpipe measures software cost only and must not replace a declared budget.

## Reactive (a cue for a concept event)

1. `UiEffects.REACTIVE` and `REACTIVE_IDS` - `label`, a palette `tone` token and a `hint`. The tone is read at draw time (`UiEffects.tone_color`), so a palette switch reaches the next flash.
2. `godot/scenes/terminal/pane_effects.gd` - draw it in `_draw`, or allocate a `CPUParticles2D` pool once and re-emit it, and start it from `_start_cue`. Everything goes through `flash_at`, which owns the 334 ms per-pane ceiling and the hidden-pane skip; a trigger inside the window is dropped, never queued.
3. The mapping table is `Settings -> Appearance -> Effects -> Reactive effects`; no new settings key is needed (`cfg_reactive_effects` is a concept -> id map, sanitized by `UiEffects.sanitize_reactive`). `Off` means the key is absent.
4. Tests: `test_pane_effects.gd` (rate limit, tone, pin, particle pool) and `test_settings_panel.gd` (row add, remove, Off, the cap). A screenshot state pins the cue through the driver's `effects_cue` key (`pin_effect_cue`).

## Traps

- Freeing the row that emitted a signal is an engine error; defer the rebuild (`_sync_reactive_rows.call_deferred()`), as the cue picker and its remove button do.
- A capture driver is a `-s` entry point compiled before autoloads: call `pin_effects`/`pin_effect_cue` through `has_method`, never by naming `TerminalPane` or `PaneEffects`.
- `effect_bench.gd` preloads the shaders by path because of the same compile order; keep its two paths in step with `UiEffects.AMBIENT`.
