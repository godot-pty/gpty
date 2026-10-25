extends GutTest
# Integration tests: layout save/restore cycle.
#
# A layout is gathered from live panes, written through WorkspaceStore, read
# back, and rebuilt by the *real* `Workspace._restore_into` — the function the
# app restores through. The assertions are about the panes that come out of
# it. (This file used to replay the restore logic inside the test bodies and
# assert on the replay, which keeps passing when the real path changes.)

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _tm: TerminalManager
var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80
	_tm = TerminalManager.new()

func after_each():
	_tm.reset()
	_free_workspace()
	MockAutoloads.teardown()

func _free_workspace():
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null

# ── Helpers ────────────────────────────────────────────────────────────

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

## Tiles in WorkspaceStore format, gathered from the source manager's panes.
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

## A real Workspace, ready (the same two-frame settle the pane-env tests use).
## A test that restores twice reads the first result before the second call:
## the previous workspace (and its bodies) is freed here.
func _make_workspace() -> Control:
	_free_workspace()
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	return ws

## Restore `tiles` through the real restore path; return the rebuilt bodies in
## tile order.
##
## The store is cleared first: `Workspace._ready` restores its own entry, and a
## tile naming a non-default program would stop there on the trust dialog
## (leaving `_workspaces` empty) — this test is about `_restore_into`, so it
## starts from a plain workspace.
func _restore(tiles: Array[Dictionary], cwd := "") -> Array:
	WorkspaceStore.save(0, [])
	var ws = await _make_workspace()
	ws._workspaces[0]["cwd"] = cwd
	ws._restore_into(ws._workspaces[0], tiles)
	var bodies := []
	for t in ws._tm.tiles:
		bodies.append(ws._tm._find_body(t.wrapper))
	return bodies

func _one_tile(settings: Dictionary) -> Array[Dictionary]:
	return [{
		"col": 0, "row": 0, "cspan": PaneTypes.GRID, "rspan": PaneTypes.GRID,
		"settings": settings,
	}]

## A shell that exists on this platform and is not the configured default —
## a test proving "the tile's program became the pane's program" needs both
## halves: a name that does not exist fails the spawn (an engine error GUT
## counts), and the default would pass even if the tile were ignored.
func _other_shell() -> String:
	return "cmd.exe" if OS.get_name() == "Windows" else "/bin/sh"

# ── Round trip: gather → store → load → real restore ───────────────────

func test_save_restore_terminal():
	var body = _tm.spawn()
	assert_not_null(body)
	var saved = _gather_tiles()
	assert_eq(saved.size(), 1)
	assert_eq(saved[0].get("settings", {}).get("type"), "terminal")

	_save_tiles(saved)
	var restored = await _restore(_load_tiles())
	assert_eq(restored.size(), 1)
	assert_true(restored[0] is TerminalPane, "the saved terminal comes back as a terminal")
	assert_eq(restored[0]._pane_type(), "terminal")

func test_save_restore_mixed_types():
	assert_not_null(_tm.spawn_pane("terminal", {"pane_name": "Term1"}))
	assert_not_null(_tm.spawn_pane("code_viewer", {"pane_name": "Code1"}))
	var saved = _gather_tiles()
	assert_eq(saved.size(), 2)

	_save_tiles(saved)
	var restored = await _restore(_load_tiles())
	assert_eq(restored.size(), 2)
	# Each saved tile maps to a rebuilt pane of the same type and name, in the
	# same order — not merely "a terminal and a code viewer exist somewhere".
	for i in 2:
		var want: Dictionary = saved[i]["settings"]
		assert_eq(restored[i]._pane_type(), want["type"], "tile %d keeps its type" % i)
		assert_eq(restored[i].pane_name, want["pane_name"], "tile %d keeps its name" % i)

func test_restore_preserves_settings_and_geometry():
	var body = _tm.spawn_pane("terminal", {"pane_name": "Custom", "rows": 30, "cols": 100})
	assert_not_null(body)
	var saved = _gather_tiles()
	_save_tiles(saved)

	var loaded := _load_tiles()
	WorkspaceStore.save(0, [])  # see `_restore`
	var ws = await _make_workspace()
	ws._restore_into(ws._workspaces[0], loaded)
	var tile = ws._tm.tiles[0]
	var restored = ws._tm._find_body(tile.wrapper)

	assert_eq(restored.pane_name, "Custom")
	assert_eq(restored.rows, 30, "the saved row count reaches the rebuilt pane")
	assert_eq(restored.cols, 100, "the saved column count reaches the rebuilt pane")
	assert_eq([tile.col, tile.row, tile.cspan, tile.rspan],
		[saved[0]["col"], saved[0]["row"], saved[0]["cspan"], saved[0]["rspan"]],
		"the tile keeps its place in the grid")

func test_set_workspace_cwd_persists_and_rejects_missing():
	WorkspaceStore.save(0, [])
	var ws = await _make_workspace()
	var dir := OS.get_user_data_dir()
	ws._set_workspace_cwd(0, dir)
	assert_eq(ws._workspaces[0].get("cwd"), dir)
	var saved: Array = WorkspaceStore.load().get("workspaces", [])
	assert_eq(saved[0].get("cwd"), dir, "the directory must reach the store")

	ws._set_workspace_cwd(0, dir + "/gpty-missing-directory")
	assert_eq(ws._workspaces[0].get("cwd"), dir,
		"a missing directory must not replace the current one")

	ws._set_workspace_cwd(0, "")
	assert_eq(ws._workspaces[0].get("cwd"), "", "Use default clears the directory")

func test_restore_applies_workspace_cwd():
	# The workspace owns the directory; a profile/tile cannot carry one.
	var dir := OS.get_user_data_dir()
	var restored = await _restore(_one_tile({
		"type": "terminal",
		"workspace_cwd": "/tmp/from-the-file",
	}), dir)
	assert_eq(restored.size(), 1)
	assert_eq(restored[0].workspace_cwd, dir,
		"the restored terminal must take the workspace's directory")

func test_restore_legacy_no_type_key():
	# A layout written before tiles carried a pane type: the restore path must
	# rebuild it as a terminal and honour the legacy `shell` key.
	var shell := _other_shell()
	var legacy: Array[Dictionary] = [{
		"col": 0, "row": 0, "cspan": PaneTypes.GRID, "rspan": PaneTypes.GRID,
		"settings": {"shell": shell, "pane_name": "OldPane"},
	}]
	_save_tiles(legacy)
	var restored = await _restore(_load_tiles())
	assert_eq(restored.size(), 1)
	assert_true(restored[0] is TerminalPane, "no type key restores as a terminal")
	assert_eq(restored[0].pane_name, "OldPane")
	assert_eq(restored[0].shell_command, shell,
		"the legacy shell key is still honoured (and differs from the default)")

func test_restoring_nothing_usable_still_leaves_a_terminal():
	# Every tile in the file is junk (not a dict, unknown pane type): the
	# restore must not leave the user with an empty workspace.
	var junk: Array[Dictionary] = [{
		"col": 0, "row": 0, "cspan": PaneTypes.GRID, "rspan": PaneTypes.GRID,
		"settings": {"type": "no_such_pane_type"},
	}]
	var restored = await _restore(junk)
	assert_eq(restored.size(), 1, "the fallback is exactly one pane")
	assert_true(restored[0] is TerminalPane, "and it is a terminal")

# ── Per-tile command field (ecosystem presets) ─────────────────────────
# Profile data is untrusted: the restore path runs `command`/`shell` through
# sanitize_shell. These drive the real `_restore_into` and read the spawned
# pane's `shell_command`, so a change to the real command > shell > default
# order — or to where sanitising happens — fails here.

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

func test_valid_command_becomes_the_panes_shell_command():
	var command := _other_shell()
	var bodies = await _restore(_one_tile(
		{"type": "terminal", "command": command, "attachment_id": "restored-command"}))
	assert_eq(bodies[0].shell_command, command, "a valid command is what the pane runs")

func test_command_outranks_the_legacy_shell_key():
	var command := _other_shell()
	var bodies = await _restore(_one_tile(
		{"type": "terminal", "command": command, "shell": "/bin/zsh"}))
	assert_eq(bodies[0].shell_command, command, "command > shell")

func test_empty_command_falls_back_to_shell_default():
	var bodies = await _restore(_one_tile({"type": "terminal", "attachment_id": "myterm"}))
	assert_eq(bodies[0].shell_command, SettingsManager.cfg_shell_command,
		"a tile naming no program runs the user's default shell")

func test_oversized_command_falls_back_to_shell_default():
	# A command exceeding sanitize_shell's 1024-char cap must not reach the shell.
	var bodies = await _restore(_one_tile(
		{"type": "terminal", "command": "x".repeat(1025)}))
	assert_eq(bodies[0].shell_command, SettingsManager.cfg_shell_command,
		"an oversized command must not reach the spawned pane")

func test_the_command_length_cap_is_1024_exactly():
	# The boundary lives in sanitize_shell, which `_restore_into` calls. It is
	# asserted on the function rather than through a pane because a pane given
	# a 1024-character program name tries to spawn it, and that is an engine
	# error the test would then have to expect.
	var fallback := SettingsManager.cfg_shell_command
	assert_eq(PaneTypes.sanitize_shell("x".repeat(1024), fallback), "x".repeat(1024),
		"1024 characters is still allowed")
	assert_eq(PaneTypes.sanitize_shell("x".repeat(1025), fallback), fallback,
		"one more is refused")

func test_command_with_fffd_falls_back_to_shell_default():
	# U+FFFD (Godot's decoded-NUL replacement) must be rejected.
	var bodies = await _restore(_one_tile(
		{"type": "terminal", "command": "evil\uFFFDcmd"}))
	assert_eq(bodies[0].shell_command, SettingsManager.cfg_shell_command,
		"a command containing U+FFFD must not reach the spawned pane")

## The shipped defaults, read directly: the mock store answers for
## `res://profiles.default.json`, so a test that wants the file the app ships
## with has to open it.
func _default_profiles() -> Array:
	var f := FileAccess.open("res://profiles.default.json", FileAccess.READ)
	assert_not_null(f, "res://profiles.default.json must be present")
	if f == null:
		return []
	var j := JSON.new()
	assert_eq(j.parse(f.get_as_text()), OK, "profiles.default.json must be valid JSON")
	var data = j.get_data()
	assert_true(data is Dictionary)
	return data.get("profiles", [])

func test_each_preset_tile_passes_sanitize_tile():
	# Every shipped preset tile must survive PaneTypes.sanitize_tile so the
	# restore path can process it — including the pane type and the companion
	# link the tile carries. The five tool profiles moved to plugin repos,
	# whose own CI sanitizes their tiles; the two shipped profiles are the
	# Agent Workspace and the bundled Knowledge Base.
	var raw := _default_profiles()
	assert_gt(raw.size(), 0, "profiles.default.json must ship at least one profile")
	for profile in raw:
		var profile_name: String = profile.get("name", "")
		var tiles: Array = profile.get("tiles", [])
		assert_gt(tiles.size(), 0, "\"%s\" must carry tiles" % profile_name)
		for td in tiles:
			var st = PaneTypes.sanitize_tile(td, 12)
			assert_false(st.is_empty(), "%s tile must pass sanitize_tile" % profile_name)
			assert_eq(st["type_name"], td["settings"].get("type"),
				"the %s tile must keep its pane type" % profile_name)
			assert_eq(st["settings"].get("attachment_id"),
				td["settings"].get("attachment_id"),
				"the %s tile's companion link must survive sanitize_tile" % profile_name)

## A wiki tile is a path carrier: the vault path must survive sanitize_tile
## (untrusted file input) and the real restore path must rebuild a pane that
## lists the vault — not merely accept the type.
func test_a_wiki_tile_restores_its_vault():
	var vault := TestPaths.user_path("wiki_restore_vault")
	DirAccess.make_dir_recursive_absolute(vault)
	var note := FileAccess.open(vault.path_join("note.md"), FileAccess.WRITE)
	note.store_string("# Heading")
	note.close()

	var body = _tm.spawn_pane("wiki", {"vault_path": vault})
	assert_not_null(body, "a wiki pane must spawn")
	var saved = _gather_tiles()
	assert_eq(saved.size(), 1)
	_save_tiles(saved)

	var restored = await _restore(_load_tiles())
	assert_eq(restored.size(), 1)
	assert_eq(restored[0]._pane_type(), "wiki")
	assert_eq(restored[0].vault_path, vault, "the vault path survives the restore")
	assert_eq(restored[0]._list.get_item_text(0), "note.md",
		"the restored pane must list the vault's notes")

	DirAccess.remove_absolute(vault.path_join("note.md"))
	DirAccess.remove_absolute(vault)

## A media tile is the same kind of path carrier as a wiki tile: the absolute
## file path must survive sanitize_tile and the real restore path must rebuild
## a pane that actually opens (and plays) it, not merely accept the type.
func test_a_media_tile_restores_its_file():
	var path := TestPaths.user_path("media_restore_tone.wav")
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_8_BITS
	stream.mix_rate = 8000
	stream.stereo = false
	var data := PackedByteArray()
	data.resize(8000)
	data.fill(128)
	stream.data = data
	assert_eq(stream.save_to_wav(path), OK)

	var restored = await _restore(_one_tile({"type": "media", "file_path": path}))
	assert_eq(restored.size(), 1)
	assert_true(restored[0] is MediaPane, "a media tile comes back as a media pane")
	assert_eq(restored[0].file_path, path, "the file path survives the restore")
	# Decoding starts on the backend's thread and the generator starts on the
	# first PCM chunk; a restore must not have to finish that synchronously.
	var playing := false
	for _i in 300:
		if restored[0]._audio.playing:
			playing = true
			break
		await get_tree().process_frame
	assert_true(playing, "the restored pane starts its stream")

	DirAccess.remove_absolute(path)

## The shipped profile's token is only useful if a real pane resolves it: this
## is the whole release path (token → seed → index → list) without the GUI.
func test_a_wiki_pane_opens_the_bundled_vault_from_its_token():
	var restored = await _restore(_one_tile({"type": "wiki", "vault_path": "@knowledge"}))
	assert_eq(restored.size(), 1, "the bundled wiki tile must restore")
	assert_not_null(restored[0]._list, "the wiki body must be ready")
	assert_gt(restored[0]._list.item_count, 40,
		"the wiki pane must resolve @knowledge to the seeded vault")

func test_the_shipped_builtins_are_program_free():
	# The five tool-specific built-ins (OMP, Herdr, Lazygit, Neovim, Claude)
	# now come from one plugin repo per tool. Both shipped profiles are
	# program-free: Agent Workspace names no command, and Knowledge Base is a
	# wiki tile whose only setting is the bundled-vault token.
	var names: Array = []
	var knowledge_tile: Dictionary = {}
	for p in _default_profiles():
		if p is Dictionary:
			names.append(p.get("name", ""))
			if p.get("name", "") == "Knowledge Base":
				for tile in p.get("tiles", []):
					if tile is Dictionary:
						var settings: Dictionary = tile.get("settings", {})
						if settings.get("type", "") == "wiki":
							knowledge_tile = tile
	assert_eq(names, ["Agent Workspace", "Knowledge Base"],
		"profiles.default.json must ship the agent workspace and the bundled wiki")
	for moved in ["OMP", "Herdr", "Lazygit", "Neovim", "Claude"]:
		assert_false(moved in names, "\"%s\" must come from its plugin now" % moved)
	assert_false(knowledge_tile.is_empty(), "Knowledge Base must carry a wiki tile")
	var knowledge_settings: Dictionary = knowledge_tile.get("settings", {})
	assert_eq(knowledge_settings.get("vault_path"), "@knowledge",
		"the knowledge base tile must name the shipped bundle, not a machine path")
	assert_eq(knowledge_settings.get("open_note"), "index.md",
		"the bundled profile must open Start Here for a first-time reader")
	# "Program-free" is the whole point of the shipped set: no built-in may
	# turn first-run onboarding into a trust dialog.
	for profile in _default_profiles():
		if not (profile is Dictionary):
			continue
		for tile in profile.get("tiles", []):
			if not (tile is Dictionary):
				continue
			var settings: Dictionary = tile.get("settings", {})
			for key in ["command", "shell", "shell_args"]:
				assert_false(settings.has(key),
					"\"%s\" must not carry a spawn plan (%s)" % [profile.get("name", ""), key])
