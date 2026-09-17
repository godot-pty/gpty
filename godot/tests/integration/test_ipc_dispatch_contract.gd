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

# ── Consent memory ────────────────────────────────────────────────────

func test_consented_content_skips_the_trust_gates():
	var version: String = GptyTerminal.get_app_version()
	# A builtin is covered once approved at this app version — never before,
	# and never from another version's approval.
	var builtin := {"name": "contract-builtin", "builtin": true, "tiles": [
		{"settings": {"type": "terminal", "command": "contract-tool"}},
	]}
	assert_false(_ws._profile_consented(builtin), "an unapproved builtin is not consented")
	TrustedStore.approve_builtin("contract-builtin", version, ["contract-tool"])
	assert_true(_ws._profile_consented(builtin), "an approved builtin at this version is consented")
	TrustedStore.approve_builtin("contract-stale", "0.0.0", ["contract-tool"])
	var stale := {"name": "contract-stale", "builtin": true, "tiles": [
		{"settings": {"type": "terminal", "command": "contract-tool"}},
	]}
	assert_false(_ws._profile_consented(stale), "an approval from another app version is stale")

	# A user profile is covered when every untrusted tile's exact plan was
	# approved; any uncovered plan keeps the gate.
	var covered := {"name": "contract-covered", "tiles": [
		{"settings": {"type": "terminal", "command": "contract-tool"}},
	]}
	assert_true(_ws._profile_consented(covered), "an approved plan covers a user profile")
	var uncovered := {"name": "contract-uncovered", "tiles": [
		{"settings": {"type": "terminal", "command": "contract-other"}},
	]}
	assert_false(_ws._profile_consented(uncovered), "an unapproved plan still asks")

	# The restore gate: covered plans stop counting, anything else does not,
	# and a trusted tile never counts with or without a record.
	var tiles_covered: Array[Dictionary] = [
		{"settings": {"type": "terminal", "command": "contract-tool"}},
	]
	assert_false(_ws._tiles_untrusted_without_consent(tiles_covered))
	var tiles_uncovered: Array[Dictionary] = [
		{"settings": {"type": "terminal", "command": "contract-other"}},
	]
	assert_true(_ws._tiles_untrusted_without_consent(tiles_uncovered))
	var tiles_trusted: Array[Dictionary] = [{"settings": {"type": "terminal"}}]
	assert_false(_ws._tiles_untrusted_without_consent(tiles_trusted))

func test_plugin_profiles_are_consented_by_their_installed_revision():
	var version: String = GptyTerminal.get_app_version()
	var plugin_tiles: Array[Dictionary] = [
		{"settings": {"type": "terminal", "command": "contract-tool"}},
	]
	var plugin_profile := {
		"name": "contract-plugin", "plugin": true,
		"plugin_id": "godot-pty/gpty-omp", "revision": "a1b2c3d4e5f6",
		"tiles": plugin_tiles,
	}
	assert_true(_ws._tiles_untrusted(plugin_tiles),
		"the plugin's tiles name a program, so the gate applies")

	# A plan-key approval covers a user profile but not a plugin profile: the
	# plugin branch decides first, and the install review's record is the
	# answer the user actually gave.
	TrustedStore.approve_builtin("contract-plan", version, ["contract-tool"])
	assert_false(_ws._profile_consented(plugin_profile),
		"a plan approval is not the plugin's install record")

	TrustedStore.approve_plugin("godot-pty/gpty-omp", "a1b2c3d4e5f6")
	assert_true(_ws._profile_consented(plugin_profile),
		"the approved revision activates without the trust dialog")

	# The record keys on the pin, so a newer revision re-prompts.
	var newer := plugin_profile.duplicate(true)
	newer["revision"] = "f6e5d4c3b2a1"
	assert_false(_ws._profile_consented(newer), "another revision re-prompts")

func test_layout_load_sees_installed_plugin_profiles():
	# The merge this item adds is what makes a plugin profile reachable by
	# name over IPC — layoutList offers it and layoutLoad gates on the
	# plugin's record. A plugin id of its own, so no other case in this
	# script's shared consent store can stand in for the answer.
	ProfileManager.plugin_profiles_source = func(): return JSON.stringify([{
		"plugin_id": "godot-pty/gpty-herdr", "revision": "c0ffee123456",
		"name": "contract-plugin-load",
		"tiles": [{"col": 0, "row": 0, "cspan": 60, "rspan": 60,
			"settings": {"type": "terminal", "shell_args": ["-i"]}}],
	}])
	ProfileManager.refresh_plugin_profiles()

	var listed = WorkspaceIpcHandlers.handle(_ws, "layoutList", {})
	assert_true(listed is Dictionary and listed.has("layouts"), "layoutList must answer layouts")
	assert_true((listed["layouts"] as Array).has("contract-plugin-load"),
		"an installed plugin profile must be listed")

	var refused = WorkspaceIpcHandlers.handle(_ws, "layoutLoad", {"name": "contract-plugin-load"})
	assert_true(refused.has("error"), "an unapproved plugin profile must be refused over IPC")
	assert_string_contains(str(refused["error"]["message"]), "GUI",
		"the refusal must point at the GUI")

	TrustedStore.approve_plugin("godot-pty/gpty-herdr", "c0ffee123456")
	var loaded = WorkspaceIpcHandlers.handle(_ws, "layoutLoad", {"name": "contract-plugin-load"})
	assert_true(loaded.get("success", false),
		"an approved plugin profile must load over IPC")
	assert_eq(_ws._tm.tiles.size(), 1, "the plugin profile replaces the layout")

	# Leave the merged set empty again — the mocked autoload outlives this
	# test for the whole script — without asking the real store.
	ProfileManager.plugin_profiles_source = func(): return "[]"
	ProfileManager.refresh_plugin_profiles()

func test_an_admin_notification_refreshes_the_profile_list():
	# The install review refreshes on a timer because the CLI moves the clone
	# into place only after it reads the answer. An admin action is the
	# opposite: the store is already written when the notification arrives, so
	# the refresh is synchronous and `refreshed: true` means the GUI has
	# caught up. Without it, `gpty plugin uninstall` left the row in a running
	# GUI (and kept activating it from memory) until the next restart.
	ProfileManager.plugin_profiles_source = func(): return JSON.stringify([{
		"plugin_id": "godot-pty/gpty-omp", "revision": "a1b2c3d4e5f6",
		"name": "contract-admin-refresh",
		"tiles": [{"col": 0, "row": 0, "cspan": 60, "rspan": 60,
			"settings": {"type": "terminal"}}],
	}])
	ProfileManager.refresh_plugin_profiles()
	assert_false(ProfileManager.find_profile("contract-admin-refresh").is_empty(),
		"precondition: the installed plugin's profile is listed")

	# What the store answers once `gpty plugin uninstall` has removed it.
	ProfileManager.plugin_profiles_source = func(): return "[]"
	var answer = WorkspaceIpcHandlers.handle(
		_ws, "pluginsChanged", {"action": "uninstall", "id": "godot-pty/gpty-omp"})
	assert_eq(answer.get("refreshed"), true, "the notification must re-read the store")
	assert_true(ProfileManager.find_profile("contract-admin-refresh").is_empty(),
		"an uninstalled plugin's profile must leave the list without a restart")

	var refused = WorkspaceIpcHandlers.handle(_ws, "pluginsChanged", {"action": "rm -rf /"})
	assert_true(refused.has("error"),
		"an action outside the vocabulary must be refused, not ignored")

	# The id is inert today but validated anyway (boundary property, not a
	# consumer's concern) — and a refusal must precede the refresh, so a
	# malformed notice cannot move the profile list as a side effect. The
	# source below would add a row if the handler got as far as refreshing.
	ProfileManager.plugin_profiles_source = func(): return JSON.stringify([{
		"plugin_id": "godot-pty/gpty-nvim", "revision": "deadbeef1234",
		"name": "contract-refused-notice",
		"tiles": [{"col": 0, "row": 0, "cspan": 60, "rspan": 60,
			"settings": {"type": "terminal"}}],
	}])
	var bad_id = WorkspaceIpcHandlers.handle(
		_ws, "pluginsChanged", {"action": "disable", "id": "Not An Id"})
	assert_true(bad_id.has("error"), "a malformed plugin id must be refused")
	assert_string_contains(str(bad_id["error"]["message"]), "plugin id",
		"the refusal must name the field it refused")
	assert_true(ProfileManager.find_profile("contract-refused-notice").is_empty(),
		"a refused notice must not refresh the store")

	ProfileManager.plugin_profiles_source = func(): return "[]"
	ProfileManager.refresh_plugin_profiles()

func test_accepted_plugin_profiles_are_read_after_the_clone_lands():
	# The install review's accept path refreshes on a timer: the CLI only
	# moves the accepted clone into place after it reads the answer, so an
	# immediate re-read would miss the profiles it wrote.
	ProfileManager.plugin_profiles_source = func(): return "[]"
	ProfileManager.refresh_plugin_profiles()

	# What the store answers once the install has landed.
	ProfileManager.plugin_profiles_source = func(): return JSON.stringify([{
		"plugin_id": "godot-pty/gpty-nvim", "revision": "deadbeef1234",
		"name": "contract-installed",
		"tiles": [{"col": 0, "row": 0, "cspan": 60, "rspan": 60,
			"settings": {"type": "code_viewer"}}],
	}])
	_ws._refresh_plugin_profiles_deferred()
	assert_true(ProfileManager.find_profile("contract-installed").is_empty(),
		"the refresh must wait for the install to land, not read immediately")

	await get_tree().create_timer(2.1).timeout
	var found := ProfileManager.find_profile("contract-installed")
	assert_false(found.is_empty(),
		"the deferred refresh must pick up the installed plugin's profiles")
	assert_true(found.get("plugin", false), "it must arrive as a plugin profile")
	assert_eq(found.get("plugin_id"), "godot-pty/gpty-nvim")

	ProfileManager.plugin_profiles_source = func(): return "[]"
	ProfileManager.refresh_plugin_profiles()
