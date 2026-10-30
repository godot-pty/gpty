---
name: gpty-settings
description: "Pattern for adding new settings to gpty's SettingsManager, settings_panel.gd, workspace.gd, and sidebar.gd."
---

# Adding a new setting to gpty

When adding a new user-facing setting to the gpty terminal emulator, follow this checklist:

## 1. SettingsManager (`godot/scenes/autoloads/settings_manager.gd`)

- Add `var cfg_NEW_SETTING := DEFAULT_VALUE` with the other `cfg_*` vars
- Add `cfg_NEW_SETTING = d.get("new_setting", DEFAULT_VALUE)` in `load_settings()`
- Add `"new_setting": cfg_NEW_SETTING` to the dictionary in `save_settings()`

**Critical**: Always add the load + save lines as a pair. Missing `load_settings` means the value silently defaults on restart. Missing `save_settings` means it never persists.

## 2. Settings Panel (`godot/scenes/ui/settings_panel.gd`)

- Add a control function (e.g., `_add_NEW_control(v: VBoxContainer) -> ControlType`)
- In `_build_ui()`, call it to get the control reference
- In the debounce timer callback, add: `SettingsManager.cfg_NEW_SETTING = name_of_control.value`
- Connect the control's changed signal to `_debounce_timer.start()`
- In `_add_reset_button`, add a reset line
- Update `_add_reset_button` call with the new control parameter

## 3. Workspace (`godot/scenes/terminal/workspace.gd`)

- In `_on_settings_changed()`, add logic to apply the new setting
- If the setting affects window state, use `DisplayServer` APIs (see window mode patterns)
- For visual changes, call `_apply_layout()` if needed

## 4. Sidebar (`godot/scenes/ui/sidebar.gd`)

- If the setting has a sidebar control, wire it to emit a request signal
- Connect `SettingsManager.settings_changed` to sync the sidebar control when settings change externally

## 5. Persistence notes

- On exit, `_exit_tree()` must call `SettingsManager.save_settings()` — `NOTIFICATION_WM_CLOSE_REQUEST` does NOT fire in Godot editor play mode
- Window mode changes in `_ready()` should use `call_deferred()` to let the window fully initialize first
- After `_restore()` loads panes, call `_sync_pane_titlebars()` to apply visibility settings to restored tiles
