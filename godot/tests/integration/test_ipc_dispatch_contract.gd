extends GutTest
# Contract tests across the IPC seam: `WorkspaceIpcHandlers.handle` against the
# workspace it drives — the real dispatch table, the real id/label resolution,
# the real panes.
#
# The coverage this replaces reimplemented `_find_pane_by_label`, the listPanes
# response and the error envelope inside the test file and asserted on those
# copies (its own header said so), so a change to the shipped handlers — the id
# and label resolution IPC targeting rests on, above all — could not fail it.
#
# One workspace for the whole script: every instance schedules a deferred
# concept push 2 s after `_ready`, and freeing it before that timer fires
# leaves the callback on a freed object, so an instance per test would cost
# ~2 s of waiting each.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

func before_all():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80
	_ws = WorkspaceScript.new()
	add_child(_ws)
	_ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

func after_all():
	# Let the workspace's deferred concept push land while it is still alive.
	await get_tree().create_timer(2.1).timeout
	remove_child(_ws)
	_ws.free()
	_ws = null
	MockAutoloads.teardown()

func _spawn(type_name: String) -> Control:
	var body = _ws._spawn_pane(type_name, {})
	assert_not_null(body, "spawning a %s pane must work" % type_name)
	return body

# ── listPanes ↔ pane targeting ─────────────────────────────────────────

func test_every_listed_id_addresses_the_pane_it_names():
	var extra = _spawn("code_viewer")
	var result = WorkspaceIpcHandlers.handle(_ws, "listPanes", {})
	assert_true(result is Dictionary and result.has("panes"), "listPanes must answer a panes array")
	assert_eq(int(result["count"]), _ws._tm.tiles.size(), "count must match the live tile list")
	assert_eq((result["panes"] as Array).size(), _ws._tm.tiles.size())

	for entry in result["panes"]:
		var pane_id := str(entry["id"])
		var focus = WorkspaceIpcHandlers.handle(_ws, "focusPane", {"pane_id": pane_id})
		assert_true(
			focus is Dictionary and focus.get("success", false),
			"the id listPanes reports (%s) must address the pane IPC targeting resolves" % pane_id
		)
		assert_eq(
			_ws._tm.last_body, _ws._find_pane_by_label(pane_id),
			"focusPane must make the pane it resolved the active one"
		)

	# The label is the legacy spelling of the same target, and it must resolve
	# to the pane carrying it rather than to whichever pane comes first.
	var by_label = WorkspaceIpcHandlers.handle(_ws, "focusPane", {"pane_id": str(extra.pane_label)})
	assert_true(by_label.get("success", false), "the pane label must still address its pane")
	assert_eq(_ws._tm.last_body, extra, "label targeting must activate the labelled pane")

	# A pane that cannot take keyboard focus must not be handed the keys: the
	# activation above must leave the keyboard owner released.
	assert_null(
		_ws.get_viewport().gui_get_focus_owner() as TerminalPane,
		"activating a read-only pane must not leave a terminal holding keyboard focus"
	)

	_ws._kill(extra)

func test_pane_targeting_accepts_an_id_and_a_legacy_label():
	var by_id = _spawn("code_viewer")
	var by_label = _spawn("code_viewer")
	var by_id_key := str(by_id.attachment_id)
	var by_label_key := str(by_label.pane_label)

	var killed = WorkspaceIpcHandlers.handle(_ws, "killPane", {"pane_id": by_id_key})
	assert_true(killed.get("success", false), "killPane must accept an attachment id")
	assert_null(_ws._find_pane_by_label(by_id_key), "the pane addressed by id must be gone")
	assert_eq(_ws._find_pane_by_label(by_label_key), by_label, "the other pane must survive")

	killed = WorkspaceIpcHandlers.handle(_ws, "killPane", {"pane_id": by_label_key})
	assert_true(killed.get("success", false), "killPane must still accept a label")
	assert_null(_ws._find_pane_by_label(by_label_key), "the pane addressed by label must be gone")

	var missing = WorkspaceIpcHandlers.handle(_ws, "killPane", {"pane_id": "no-such-pane"})
	assert_true(missing.has("error"), "killing an unknown pane must be an error, not a success")

# ── Method contracts ───────────────────────────────────────────────────

func test_terminal_only_methods_refuse_other_panes():
	var viewer = _spawn("code_viewer")
	var viewer_id := str(viewer.attachment_id)

	var read = WorkspaceIpcHandlers.handle(_ws, "paneRead", {"pane_id": viewer_id})
	assert_true(read.has("error"), "paneRead must refuse a pane that has no terminal")

	var injected = WorkspaceIpcHandlers.handle(_ws, "inject", {"pane_id": viewer_id, "text": "x"})
	assert_true(injected.has("error"), "inject must refuse a pane that has no terminal")

	var absent = WorkspaceIpcHandlers.handle(_ws, "paneRead", {"pane_id": "no-such-pane"})
	assert_true(absent.has("error"), "paneRead must refuse an unknown pane")

	_ws._kill(viewer)

func test_unknown_method_answers_method_not_found():
	var result = WorkspaceIpcHandlers.handle(_ws, "notAMethod", {})
	assert_true(result.has("error"), "an unknown method must answer an error")
	assert_eq(int(result["error"]["code"]), -32601, "unknown methods answer JSON-RPC -32601")

# ── layoutList / layoutLoad ────────────────────────────────────────────

func test_layout_list_reports_the_profiles_the_store_holds():
	ProfileManager.add_profile("contract-listed", [])
	var result = WorkspaceIpcHandlers.handle(_ws, "layoutList", {})
	assert_true(result is Dictionary and result.has("layouts"), "layoutList must answer layouts")
	assert_true(
		(result["layouts"] as Array).has("contract-listed"),
		"a saved profile must appear in layoutList"
	)

func test_layout_load_refuses_an_untrusted_profile():
	ProfileManager.add_profile("contract-untrusted", [
		{
			"col": 0, "row": 0, "cspan": 60, "rspan": 60,
			"settings": {"type": "terminal", "shell": SettingsManager.default_shell_command(), "shell_args": ["-c", "echo pwned"]},
		},
	])
	var tiles_before: int = _ws._tm.tiles.size()

	var refused = WorkspaceIpcHandlers.handle(_ws, "layoutLoad", {"name": "contract-untrusted"})
	assert_true(refused.has("error"), "an untrusted profile must be refused over IPC")
	assert_string_contains(str(refused["error"]["message"]), "GUI", "the refusal must point at the GUI")
	assert_eq(_ws._tm.tiles.size(), tiles_before, "a refused load must not touch the workspace")

	ProfileManager.add_profile("contract-trusted", [
		{"col": 0, "row": 0, "cspan": 60, "rspan": 60, "settings": {"type": "code_viewer"}},
	])
	var loaded = WorkspaceIpcHandlers.handle(_ws, "layoutLoad", {"name": "contract-trusted"})
	assert_true(loaded.get("success", false), "a trusted profile must still load over IPC")
	assert_eq(_ws._tm.tiles.size(), 1, "the trusted profile replaces the layout")
