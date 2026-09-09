extends GutTest
# Integration tests: layout save/restore cycle.
# Verifies that tiles can be persisted and restored with correct types and settings.

var _tm: TerminalManager

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = "/bin/sh"
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80
	_tm = TerminalManager.new()

func after_each():
	_tm.reset()
	MockAutoloads.teardown()

# ── Helper: gather tiles in WorkspaceStore format ──────────────────────

func _save_tiles(tiles: Array[Dictionary]):
	WorkspaceStore.save(0, [{"name": "Workspace 1", "layout": tiles}])

func _load_tiles() -> Array[Dictionary]:
	var store = WorkspaceStore.load()
	var wss: Array = store.get("workspaces", [])
	if wss.is_empty():
		return []
	var first: Dictionary = wss[0]
	var out: Array[Dictionary] = []
	for td in first.get("layout", []):
		if td is Dictionary:
			out.append(td)
	return out

func _gather_tiles() -> Array[Dictionary]:
	var ts: Array[Dictionary] = []
	for t in _tm.tiles:
		var body = _tm._find_body(t.wrapper)
		var settings = body._get_layout_state() if body and body.has_method("_get_layout_state") else {}
		ts.append({
			"col": t.col, "row": t.row,
			"cspan": t.cspan, "rspan": t.rspan,
			"settings": settings,
		})
	return ts

# ── Round-trip tests ───────────────────────────────────────────────────

func test_save_restore_terminal():
	var body = _tm.spawn()
	assert_not_null(body)
	var saved = _gather_tiles()
	assert_eq(saved.size(), 1)
	assert_eq(saved[0].get("settings", {}).get("type"), "terminal")

	_save_tiles(saved)
	var loaded = _load_tiles()
	assert_eq(loaded.size(), 1)
	assert_eq(loaded[0].get("settings", {}).get("type"), "terminal")

func test_save_restore_mixed_types():
	var t1 = _tm.spawn_pane("terminal", {"pane_name": "Term1"})
	assert_not_null(t1)
	var t2 = _tm.spawn_pane("code_viewer", {"pane_name": "Code1"})
	assert_not_null(t2)

	var saved = _gather_tiles()
	assert_eq(saved.size(), 2)

	_save_tiles(saved)
	var loaded = _load_tiles()
	assert_eq(loaded.size(), 2)

	var types := []
	for td in loaded:
		types.append(td.get("settings", {}).get("type"))
	assert_true(types.has("terminal"), "loaded tiles should include terminal")
	assert_true(types.has("code_viewer"), "loaded tiles should include code_viewer")

func test_restore_preserves_settings():
	var body = _tm.spawn_pane("terminal", {"pane_name": "Custom", "rows": 30, "cols": 100})
	assert_not_null(body)

	var saved = _gather_tiles()
	_save_tiles(saved)
	var loaded = _load_tiles()

	var settings = loaded[0].get("settings", {})
	assert_eq(settings.get("pane_name"), "Custom")
	assert_eq(settings.get("rows"), 30)
	assert_eq(settings.get("cols"), 100)

func test_restore_legacy_no_type_key():
	# Simulate legacy layout data without "type" key
	var legacy: Array[Dictionary] = [{
		"col": 0, "row": 0, "cspan": 12, "rspan": 12,
		"settings": {"shell": "/bin/bash", "pane_name": "OldPane"},
	}]
	_save_tiles(legacy)
	var loaded = _load_tiles()
	assert_eq(loaded.size(), 1)
	# No "type" key: workspace defaults to "terminal"
	assert_eq(loaded[0].get("settings", {}).get("type", "terminal"), "terminal")

func test_load_tiles_empty_when_no_file():
	var loaded = _load_tiles()
	assert_eq(loaded, [], "should return empty when no file exists")

# ── Per-tile command field (ecosystem presets) ─────────────────────────
# Tests mirror the _do_restore / _do_activate restore logic and verify
# that profile data is untrusted — commands are sanitised before use.

func test_command_field_survives_sanitize_tile():
	# A tile with settings.command should pass sanitize_tile and
	# keep the field intact for the restore path to consume.
	var td := {
		"col": 0, "row": 0, "cspan": 12, "rspan": 12,
		"settings": {"type": "terminal", "command": "lazygit", "attachment_id": "lazygit"},
	}
	var st = PaneTypes.sanitize_tile(td, 12)
	assert_false(st.is_empty(), "lazygit tile should pass sanitize_tile")
	assert_eq(st["settings"].get("command"), "lazygit",
		"command field must survive sanitize_tile")

func test_valid_command_used_as_shell_command():
	# Mirror the restore-path logic: command > shell > default.
	var settings := {"type": "terminal", "command": "herdr", "attachment_id": "herdr"}
	var raw = settings.get("command", settings.get("shell", ""))
	var sh = PaneTypes.sanitize_shell(raw, SettingsManager.cfg_shell_command)
	assert_eq(sh, "herdr", "valid command should be returned by sanitize_shell as-is")

func test_empty_command_falls_back_to_shell_default():
	# If command is absent, the restore path should produce the default shell.
	var settings := {"type": "terminal", "attachment_id": "myterm"}
	var raw = settings.get("command", settings.get("shell", ""))
	var sh = PaneTypes.sanitize_shell(raw, SettingsManager.cfg_shell_command)
	assert_eq(sh, SettingsManager.cfg_shell_command,
		"missing command should fall back to the default shell")

func test_oversized_command_falls_back_to_shell_default():
	# A command exceeding sanitize_shell's 1024-char cap must not reach the shell.
	var big_cmd := "x".repeat(1025)
	var settings := {"type": "terminal", "command": big_cmd}
	var raw = settings.get("command", settings.get("shell", ""))
	var sh = PaneTypes.sanitize_shell(raw, SettingsManager.cfg_shell_command)
	assert_eq(sh, SettingsManager.cfg_shell_command,
		"oversized command must fall back to the default shell")

func test_command_with_fffd_falls_back_to_shell_default():
	# U+FFFD (Godot's decoded-NUL replacement) must be rejected.
	var bad_cmd := "evil\uFFFDcmd"
	var settings := {"type": "terminal", "command": bad_cmd}
	var raw = settings.get("command", settings.get("shell", ""))
	var sh = PaneTypes.sanitize_shell(raw, SettingsManager.cfg_shell_command)
	assert_eq(sh, SettingsManager.cfg_shell_command,
		"command containing U+FFFD must fall back to the default shell")

func test_each_preset_tile_passes_sanitize_tile():
	# Every ecosystem preset tile must survive PaneTypes.sanitize_tile so that
	# the restore path can process it.  Also verifies that command survives.
	var preset_tiles := [
		{"col": 0, "row": 0, "cspan": 12, "rspan": 12,
		 "settings": {"type": "terminal", "pane_name": "Herdr",      "attachment_id": "herdr",   "command": "herdr"}},
		{"col": 0, "row": 0, "cspan": 12, "rspan": 12,
		 "settings": {"type": "terminal", "pane_name": "Lazygit",    "attachment_id": "lazygit", "command": "lazygit"}},
		{"col": 0, "row": 0, "cspan": 12, "rspan": 12,
		 "settings": {"type": "terminal", "pane_name": "Neovim",     "attachment_id": "nvim",    "command": "nvim"}},
		{"col": 0, "row": 0, "cspan": 12, "rspan": 12,
		 "settings": {"type": "terminal", "pane_name": "Claude Code","attachment_id": "claude",  "command": "claude"}},
		{"col": 0, "row": 0, "cspan": 12, "rspan": 12,
		 "settings": {"type": "terminal", "pane_name": "OMP",        "attachment_id": "omp",     "command": "omp"}},
	]
	for td in preset_tiles:
		var cmd: String = td["settings"]["command"]
		var st = PaneTypes.sanitize_tile(td, 12)
		assert_false(st.is_empty(), "%s preset tile must pass sanitize_tile" % cmd)
		assert_eq(st["settings"].get("command"), cmd,
			"command must survive sanitize_tile for %s" % cmd)

func test_six_builtins_in_default_profiles_file():
	# Read profiles.default.json directly (bypasses the mock) to confirm
	# exactly six built-in profiles are shipped, with the expected names.
	var f := FileAccess.open("res://profiles.default.json", FileAccess.READ)
	assert_not_null(f, "res://profiles.default.json must be present")
	if f == null:
		return
	var j := JSON.new()
	assert_eq(j.parse(f.get_as_text()), OK, "profiles.default.json must be valid JSON")
	var data = j.get_data()
	assert_true(data is Dictionary)
	var raw = data.get("profiles", [])
	assert_eq(raw.size(), 6, "profiles.default.json must contain exactly 6 built-in profiles")
	var names: Array = []
	for p in raw:
		if p is Dictionary:
			names.append(p.get("name", ""))
	for expected in ["Agent Workspace", "Herdr", "Lazygit", "Neovim", "Claude Code", "OMP"]:
		assert_true(expected in names, "\"%s\" must be a built-in profile" % expected)
