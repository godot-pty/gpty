---
name: gpty-settings
description: "Pattern for adding new settings to gpty's SettingsManager, settings_panel.gd, workspace.gd, and sidebar.gd."
---

# Adding a new setting to gpty

When adding a new user-facing setting to the gpty terminal emulator, follow this checklist:

## 1. SettingsManager (`godot/scenes/autoloads/settings_manager.gd`)

- Add `var cfg_NEW_SETTING := DEFAULT_VALUE` with the other `cfg_*` vars
- Add `cfg_NEW_SETTING = _as_<type>(d, "new_setting", DEFAULT_VALUE)` in `load_settings()`
  (`_as_int`/`_as_bool`/`_as_float`/`_as_string`; a raw `d.get()` assigned to a typed var raises on a
  wrong-typed JSON value and aborts the loader, dropping every key after it). Clamp a bounded value
  in the same line with `clampi`/`clampf` - the store is a hand-editable file.
- Add `"new_setting": cfg_NEW_SETTING` to the dictionary in `save_settings()`

**Critical**: Always add the load + save lines as a pair. Missing `load_settings` means the value silently defaults on restart. Missing `save_settings` means it never persists.

## 2. Settings Panel (`godot/scenes/ui/settings_panel.gd`)

- Add a control function (e.g., `_add_NEW_control(v: VBoxContainer) -> ControlType`); the house
  shape is `_add_fps_control` (label row + `OptionButton` with a `name`, a presets array, and a
  trailing `"(custom)"` entry when the stored value is not a preset - `find()` returns -1 and
  `selected = -1` leaves the dropdown blank)
- In `_build_ui()`, call it from the owning tab to get the control reference
- Delayed settings: write `SettingsManager.cfg_NEW_SETTING = name_of_control.value` in the
  `_debounce_timer.timeout` callback and connect the control's changed signal to
  `_debounce_timer.start()`. Immediate settings (anything the user judges by looking at the window,
  like the UI scale) write the `cfg_` and call `SettingsManager.save_settings()` on selection -
  `settings_changed` is what applies it - and need no debounce line
- A control whose default is not a fixed value takes a *provider* instead of a captured colour:
  the seven chrome-colour rows reset through `func() -> Color: return UiPalette.active().color(token)`,
  and `appearance_changed` re-points their swatches. A captured default silently restores the
  palette the panel was built under
- Add the reset to the owning tab's `_add_tab_reset(tab, func(): ...)` lambda **and** set the
  control's own value/selection there: the lambda restores the `cfg_` values, and the visible
  control does not follow by itself

## 3. Workspace (`godot/scenes/terminal/workspace.gd`)

- In `_on_settings_changed()`, add logic to apply the new setting
- A setting that switches a whole surface (the chrome palette) gets its own signal and listener
  rather than living in `_on_settings_changed`: `SettingsManager.apply_appearance()` resolves the
  mode and emits `appearance_changed`, and `Workspace._on_appearance_changed()` rebuilds the
  `Theme`, the clear colour and every pushed colour. `save_settings()` resolves the appearance
  *before* it emits `settings_changed`, so a listener never reads the previous palette
- If the setting affects window state, use `DisplayServer` APIs (see window mode patterns)
- For visual changes, call `_apply_layout()` if needed

## 4. Sidebar (`godot/scenes/ui/sidebar.gd`)

- If the setting has a sidebar control, wire it to emit a request signal
- Connect `SettingsManager.settings_changed` to sync the sidebar control when settings change externally

## 5. Persistence notes

- On exit, `_exit_tree()` must call `SettingsManager.save_settings()` — `NOTIFICATION_WM_CLOSE_REQUEST` does NOT fire in Godot editor play mode
- Window mode changes in `_ready()` should use `call_deferred()` to let the window fully initialize first
- After `_restore()` loads panes, call `_sync_pane_titlebars()` to apply visibility settings to restored tiles
