extends GutTest
# Integration tests: workspace-level settings consistency.
# Defends the fix for pane titlebars and terminal settings being
# dropped on profile activation and post-startup spawns.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_show_titlebar = false
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80
	SettingsManager.cfg_font_size = 17
	SettingsManager.cfg_cursor_shape = 1

func after_each():
	# The palette is process-global: leave the suite on the dark set, whatever a
	# switch test did.
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_DARK
	SettingsManager.apply_appearance()
	# Free synchronously while mocks are still active: _exit_tree() → _save()
	# would otherwise write the real layout/settings after teardown restores
	# the real persistence scripts.
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()

func test_a_spawned_terminal_gets_global_settings():
	# A fresh launch has no workspace; seed one empty workspace so the spawn has
	# a target, then prove the user-initiated spawn gets the global settings.
	MockAutoloads.set_store(WorkspaceStore.FILE, {
		"active": 0,
		"workspaces": [{"name": "W", "layout": []}],
	})
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame

	var body = ws._spawn_pane("terminal")
	assert_not_null(body, "the workspace can spawn a terminal")
	assert_eq(body.font_size, 17, "spawned terminal should get cfg font size")
	assert_eq(body.cursor_shape, 1, "spawned terminal should get cfg cursor shape")
	var tb = ws._tm.tiles[-1].wrapper.get_node_or_null("BodyVBox/TitleBar")
	assert_false(tb.visible, "spawned titlebar should be hidden when cfg_show_titlebar is false")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_a_workspace_the_store_kept_empty_stays_empty():
	# `WorkspaceStore` writes `layout: []` for a workspace whose panes the user
	# closed. That is a saved state, so the restore keeps it empty and shows the
	# guide; a missing store is a first run with no workspace, pinned by
	# `test_a_first_run_has_no_workspace_and_no_pane`.
	MockAutoloads.set_store(WorkspaceStore.FILE, {
		"active": 0,
		"workspaces": [{"name": "Emptied", "layout": []}],
	})
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(ws._workspaces.size(), 1, "the stored workspace is rebuilt")
	assert_eq(ws._tm.tiles.size(), 0, "a saved empty layout restores no panes")
	ws._apply_layout()
	assert_true(ws._empty_state.visible, "the empty-state guide takes the grid")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_a_settings_save_reaches_a_hidden_workspace():
	# A workspace switch no longer re-applies settings to the incoming panes, so
	# the broadcast itself must reach a workspace that is not visible: a hidden
	# pane has to be current before the user can switch to it, or every switch
	# would show the settings from whenever that workspace was last active.
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame

	ws._add_workspace()
	assert_eq(ws._active, 1, "precondition: the new workspace is active")
	var hidden = ws._spawn_pane("terminal")
	assert_not_null(hidden, "the second workspace holds a terminal")
	ws._switch_workspace(0)
	assert_eq(ws._active, 0, "precondition: the second workspace is hidden")

	SettingsManager.cfg_font_size = 21
	SettingsManager.cfg_show_titlebar = true
	SettingsManager.save_settings()
	await get_tree().process_frame

	assert_eq(hidden.font_size, 21, "the hidden terminal took the font size")
	var tb = ws._workspaces[1].tm.tiles[0].wrapper.get_node_or_null("BodyVBox/TitleBar")
	assert_not_null(tb, "the hidden pane keeps its title bar node")
	assert_true(tb.visible, "the hidden pane's title bar took the setting too")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_profile_activation_respects_show_titlebar():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame

	ws._do_activate({"name": "P", "tiles": [{
		"col": 0, "row": 0, "cspan": 12, "rspan": 12,
		"settings": {"type": "terminal", "shell": SettingsManager.default_shell_command(), "rows": 24, "cols": 80},
	}]}, false)
	await get_tree().process_frame

	var tm: TerminalManager = ws._tm
	assert_eq(tm.tiles.size(), 1, "profile activation should replace the layout")
	var tb = tm.tiles[0].wrapper.get_node_or_null("BodyVBox/TitleBar")
	assert_not_null(tb, "titlebar node should exist")
	assert_false(tb.visible, "profile-activated titlebar should be hidden when cfg_show_titlebar is false")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_click_activates_non_terminal_pane():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	ws._do_activate({"name": "P", "tiles": [
		{"col": 0, "row": 0, "cspan": 6, "rspan": 12,
			"settings": {"type": "code_viewer", "pane_name": "C1"}},
		{"col": 6, "row": 0, "cspan": 6, "rspan": 12,
			"settings": {"type": "terminal", "shell": SettingsManager.default_shell_command(), "rows": 24, "cols": 80}},
	]}, false)
	await get_tree().process_frame
	await get_tree().process_frame

	var tm: TerminalManager = ws._tm
	var terminal_body = null
	var viewer_body = null
	for t in tm.tiles:
		var b = tm._find_body(t.wrapper)
		if b is TerminalPane:
			terminal_body = b
		else:
			viewer_body = b
	assert_not_null(terminal_body)
	assert_not_null(viewer_body)

	# A click inside the code viewer's wrapper must make it the active pane.
	var w0: Control = tm.tiles[0].wrapper
	var ev = InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = w0.get_global_rect().get_center()
	ws._input(ev)

	assert_eq(tm.last_body, viewer_body,
		"clicking a non-terminal pane must make it the active pane")

	# A click on the terminal must make it active again.
	var w1: Control = tm.tiles[1].wrapper
	ev.position = w1.get_global_rect().get_center()
	ws._input(ev)
	assert_eq(tm.last_body, terminal_body,
		"clicking the terminal must make it the active pane")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

## The view refresh runs on every workspace switch and profile activation,
## and the active pane may be a read-only one. It used to call
## `last_body.grab_focus()`, which is an engine error on a pane that cannot
## take focus (GUT fails this test for it) — the one focus rule lives in
## `activate_pane`.
func test_applying_the_active_workspace_view_keeps_a_read_only_pane_active():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame

	ws._execute_command("new code viewer")
	var body = ws._tm.last_body
	assert_not_null(body, "the palette command must leave an active pane")
	assert_eq(body._pane_type(), "code_viewer", "it must be the pane that was spawned")

	ws._apply_active_workspace_view()
	assert_eq(ws._tm.last_body, body,
		"refreshing the view must not drop the active read-only pane")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_add_workspace_starts_blank():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	ws._add_workspace()
	assert_eq(ws._workspaces.size(), 2, "add_workspace must create a second workspace")
	var new_ws: Dictionary = ws._workspaces[1]
	assert_eq((new_ws.tm as TerminalManager).tiles.size(), 0,
		"a new workspace must be a blank slate — no auto-spawned terminal")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_profile_accent_follows_the_active_workspace():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	# W1 activates P1.
	ws._do_activate({"name": "P1", "tiles": []}, false)
	await get_tree().process_frame
	assert_eq(ws._active_profile, "P1")
	assert_eq(ws._workspaces[0].get("profile"), "P1")

	# A new workspace starts blank: no profile accent leaks in from W1.
	ws._add_workspace()
	await get_tree().process_frame
	assert_eq(ws._workspaces.size(), 2)
	assert_eq(ws._active_profile, "", "a new workspace must not inherit W1's profile accent")
	assert_eq(ws._workspaces[1].get("profile"), "")

	# Each workspace remembers its own profile across switches.
	ws._do_activate({"name": "P2", "tiles": []}, false)
	await get_tree().process_frame
	assert_eq(ws._active_profile, "P2")
	ws._switch_workspace(0)
	assert_eq(ws._active_profile, "P1", "W1 must remember P1")
	ws._switch_workspace(1)
	assert_eq(ws._active_profile, "P2", "W2 must remember P2")

	# Reset drops the accent for its own workspace only.
	ws._do_reset_now()
	assert_eq(ws._active_profile, "")
	assert_eq(ws._workspaces[1].get("profile"), "")
	ws._switch_workspace(0)
	assert_eq(ws._active_profile, "P1", "W1's accent survives W2's reset")

	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

## The sidebar's arrow opens a profile in its own workspace. Nothing in the
## active workspace may move: its tiles, its directory and its own profile
## association all stay, and the new tab carries the profile's tiles and name.
func test_profile_opened_in_a_new_workspace_leaves_the_current_one_alone():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	var first: Dictionary = ws._workspaces[0]
	var tiles_before: int = (first.tm as TerminalManager).tiles.size()
	assert_gt(tiles_before, 0, "the first workspace starts with a terminal")
	assert_eq(str(first.get("profile", "")), "")

	var profile := {"name": "Fresh", "tiles": [{
		"col": 0, "row": 0, "cspan": 12, "rspan": 12,
		"settings": {"type": "terminal", "shell": SettingsManager.default_shell_command(),
			"rows": 24, "cols": 80},
	}]}
	ws._do_activate(profile, false, true)
	await get_tree().process_frame

	assert_eq(ws._workspaces.size(), 2, "a profile opened in a new workspace adds a tab")
	assert_eq(ws._active, 1, "the new workspace becomes the active one")
	assert_eq(str(ws._workspaces[1].name), "Fresh", "the tab is named after the profile")
	assert_eq((ws._workspaces[1].tm as TerminalManager).tiles.size(), 1,
		"the profile's tiles land in the new workspace")
	assert_eq((first.tm as TerminalManager).tiles.size(), tiles_before,
		"the current workspace's layout is untouched")
	assert_eq(str(first.get("profile", "")), "",
		"the current workspace keeps its own profile association")
	assert_eq(ws._active_profile, "Fresh", "the new workspace carries the profile accent")
	assert_false((first.grid as Control).visible)
	assert_true((ws._workspaces[1].grid as Control).visible)

	# A second workspace from the same profile gets a distinct name, so the
	# two tabs never read the same in the sidebar.
	ws._do_activate(profile, false, true)
	await get_tree().process_frame
	assert_eq(str(ws._workspaces[2].name), "Fresh 2")

	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

## At the cap the action is refused before anything is created or replaced: a
## ninth tab cannot exist, and the profile's tiles must not fall through into
## the active workspace as a consolation layout.
func test_profile_opened_at_the_workspace_cap_is_refused():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	while ws._workspaces.size() < WorkspaceScript.MAX_WORKSPACES:
		ws._add_workspace()
	await get_tree().process_frame
	var cap: int = WorkspaceScript.MAX_WORKSPACES
	assert_eq(ws._workspaces.size(), cap)
	assert_eq(ws._active, cap - 1)

	var tiles: Array[Dictionary] = [{
		"col": 0, "row": 0, "cspan": 12, "rspan": 12,
		"settings": {"type": "terminal", "shell": SettingsManager.default_shell_command(),
			"rows": 24, "cols": 80},
	}]
	ProfileManager.add_profile("CapTest", tiles)
	ws._open_profile_in_new_workspace("CapTest")
	await get_tree().process_frame

	assert_eq(ws._workspaces.size(), cap, "a ninth workspace must not be created")
	assert_eq((ws._tm.tiles as Array).size(), 0,
		"the refused profile must not be applied to the active workspace")
	assert_eq(ws._active, cap - 1, "the active workspace must not change")

	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_pane_run_executes_through_configured_shell():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	var result = WorkspaceIpcHandlers.handle(ws, "paneRun", {"command": "echo hi && exit 7"})
	assert_true(result is Dictionary and result.has("pane_id"), "paneRun must return a pane id")

	var tm: TerminalManager = ws._tm
	var body = null
	for t in tm.tiles:
		var b = tm._find_body(t.wrapper)
		if b is TerminalPane and b.attachment_id == str(result.get("pane_id", "")):
			body = b
			break
	assert_not_null(body, "paneRun must spawn a terminal pane")
	assert_eq(body.shell_command, SettingsManager.cfg_shell_command,
		"paneRun must use the configured shell as the program")
	assert_eq(body.shell_args, PaneTypes.shell_run_args(SettingsManager.cfg_shell_command, "echo hi && exit 7"),
		"the command must run as shell arguments, not the program")

	var err = WorkspaceIpcHandlers.handle(ws, "paneRun", {"command": "   "})
	assert_true(err is Dictionary and err.has("error"), "empty command must error")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_ui_colors_apply_live_to_existing_wrappers():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	var tm: TerminalManager = ws._tm
	var wrapper: PanelContainer = tm.tiles[0].wrapper
	var sb = wrapper.get_theme_stylebox("panel") as StyleBoxFlat
	assert_not_null(sb, "wrapper must carry a panel stylebox")
	assert_eq(sb.bg_color, SettingsManager.cfg_wrapper_bg,
		"startup must apply the configured wrapper bg")

	# save_settings() emits settings_changed → workspace must re-apply the
	# chrome colors to existing panes (no app restart required).
	SettingsManager.cfg_wrapper_bg = Color(0.9, 0.1, 0.1)
	SettingsManager.cfg_title_bar_bg = Color(0.1, 0.9, 0.1)
	SettingsManager.cfg_sidebar_bg = Color(0.1, 0.1, 0.9)
	SettingsManager.save_settings()

	assert_eq(sb.bg_color, Color(0.9, 0.1, 0.1),
		"wrapper bg must update live on existing panes")
	var tb = wrapper.get_node_or_null("BodyVBox/TitleBar")
	var tbg = tb.get_node_or_null("TitleBarBg")
	assert_not_null(tbg, "pane titlebar must carry a named bg rect")
	assert_eq(tbg.color, Color(0.1, 0.9, 0.1),
		"pane titlebar bg must update live on existing panes")
	assert_eq(ws._sidebar_bg.color, Color(0.1, 0.1, 0.9),
		"sidebar bg must update live")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_pane_status_includes_agent_state():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	var run = WorkspaceIpcHandlers.handle(ws, "paneRun", {"command": "echo hi"})
	assert_true(run is Dictionary and run.has("pane_id"), "paneRun must return a pane id")
	var st = WorkspaceIpcHandlers.handle(ws, "paneStatus", {"pane_id": str(run.get("pane_id"))})
	assert_true(st is Dictionary and not st.has("error"), "paneStatus must succeed")
	assert_true(st.has("agent_state"), "paneStatus must expose agent_state")
	assert_eq(str(st.get("agent_state", "")), "idle",
		"a fresh terminal must report idle agent state")
	assert_true(st.has("agent_state_tier"), "paneStatus must expose the detection tier")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_pane_settings_open_above_second_workspace_grid():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	ws._add_workspace()
	assert_eq(ws._workspaces.size(), 2, "add_workspace must create a second workspace")
	var body = ws._spawn_pane("terminal")
	assert_not_null(body, "spawning into the second workspace must work")

	ws._tm._open_pane_settings(body)
	var panel = ws._tm._pane_settings_panel
	assert_true(panel.visible, "pane settings popup must open on a non-first workspace")
	assert_gt(panel.z_index, ws._grid.z_index,
		"overlay panels must render above later-added workspace grids")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_search_button_opens_active_terminal_search():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	ws._open_active_search()
	var tm: TerminalManager = ws._tm
	var body = tm._find_body(tm.tiles[0].wrapper)
	assert_true(body is TerminalPane, "startup must spawn a terminal")
	assert_true(body._search_visible, "search button must open the terminal search UI")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

func test_search_bar_is_a_compact_strip_at_the_pane_top():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	var tm: TerminalManager = ws._tm
	var body = tm._find_body(tm.tiles[0].wrapper)
	assert_true(body is TerminalPane, "startup must spawn a terminal")
	body._toggle_search()
	await get_tree().process_frame

	# The strip used to sit on the bottom edge and cover the prompt and the
	# last two output rows. It is anchored to the top now.
	var body_rect: Rect2 = body.get_global_rect()
	var strip_rect: Rect2 = body._search_strip.get_global_rect()
	assert_lt(strip_rect.position.y - body_rect.position.y, 10.0,
		"the strip sits on the pane's top edge, not over the prompt")
	assert_gt(strip_rect.size.y, 20.0, "the strip has real height")
	assert_lt(strip_rect.size.y, 50.0, "the strip is a compact row, not a full-pane overlay")
	assert_gt(body._search_bar.size.x, 400.0, "the field spans most of the pane width")
	assert_lt(strip_rect.end.y - body_rect.position.y, body_rect.size.y * 0.25,
		"the strip never reaches the prompt at the bottom")
	assert_gte(body._history_panel.position.y, strip_rect.size.y + 6.0,
		"the results panel hangs below the strip")
	assert_lt(body._history_panel.size.y, 250.0, "the results panel is bounded")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout

## `n/m` on the strip, both step directions, and the engine's refusal shown as
## words instead of an invisible `_search_error`.
func test_search_shows_the_match_count_and_steps_both_ways():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	var body = ws._tm._find_body(ws._tm.tiles[0].wrapper)
	assert_true(body is TerminalPane, "startup must spawn a terminal")
	body._terminal.send_line("printf 'alpha one\\nalpha two\\nbeta three\\nalpha four\\n'")
	# The count is read from the grid, so the child's output has to land first.
	# The shell echoes the typed command, so the expected count is not 3: read
	# it from the results and build every string from it.
	for _i in 300:
		if "alpha four" in str(body._terminal.get_plain_text(200)):
			break
		await get_tree().process_frame
	body._toggle_search()
	await get_tree().process_frame
	body._do_search("alpha")
	var count := int(body._search_results.get("count", 0))
	assert_gte(count, 3, "the three printed alpha lines are matches")
	assert_eq(body._search_count.text, "0/%d" % count,
		"no match is highlighted before the first jump")
	body._jump_to_match(1)
	assert_eq(body._search_count.text, "1/%d" % count)
	var ev := InputEventKey.new()
	ev.keycode = KEY_ENTER
	ev.pressed = true
	ev.shift_pressed = true
	body._on_search_bar_input(ev)
	assert_eq(body._search_count.text, "%d/%d" % [count, count],
		"Shift+Enter wraps back to the last match")
	body._do_search("[")
	assert_ne(body._search_error, "", "precondition: the engine refused the expression")
	assert_eq(body._search_count.text, "Invalid pattern")
	assert_eq(body._search_count.theme_type_variation, UiTheme.DANGER_LABEL)
	body._on_scope_toggled()
	assert_false(body._search_count.visible,
		"the history scope's own panel carries its answer")
	await get_tree().create_timer(2.1).timeout

## A spawn, a swap and a close are visible in the grid; a toast that repeats
## them is noise. The refusal below is the positive control: same recorder,
## and it must catch something.
func test_spawn_swap_and_close_do_not_toast():
	var seen: Array[String] = []
	var recorder := func(d: Dictionary): seen.append(str(d.get("text", "")))
	ToastManager.toast_requested.connect(recorder)
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(seen.size(), 0, "the startup spawn is visible in the tiles; got %s" % [seen])
	var second = ws._spawn_pane("terminal")
	assert_not_null(second)
	await get_tree().process_frame
	assert_eq(seen.size(), 0, "a spawn is visible in the tiles; got %s" % [seen])
	ws._swap_pane_now(second, "code_viewer")
	await get_tree().process_frame
	assert_eq(seen.size(), 0, "a swapped type is visible in the pane; got %s" % [seen])
	ws._kill_now(ws._tm._find_body(ws._tm.tiles[-1].wrapper))
	await get_tree().process_frame
	assert_eq(seen.size(), 0, "a close is visible in the tiles; got %s" % [seen])
	# The positive control: a refusal the user must see still reaches the toast
	# queue. Then the last workspace closes without one.
	ws._set_workspace_cwd(0, "relative/path")
	assert_has(seen, "That working directory is not a usable absolute path",
		"the recorder is wired: a refusal the user must see is caught")
	seen.clear()
	ws._close_workspace_now(0)
	ToastManager.toast_requested.disconnect(recorder)
	assert_true(ws._workspaces.is_empty(), "the last workspace is discardable")
	assert_eq(seen.size(), 0,
		"closing the last workspace is visible in the sidebar, not a toast")
	await get_tree().create_timer(2.1).timeout

func test_a_first_run_has_no_workspace_and_no_pane():
	MockAutoloads.remove_store(WorkspaceStore.FILE)
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(ws._workspaces.size(), 0, "a first run has no workspace")
	assert_eq(ws._tm.tiles.size(), 0, "and no pane")
	assert_eq(ws._active, -1, "there is no active workspace")
	assert_true(ws._empty_state.visible, "the guide owns the screen")
	assert_eq(ws._sidebar._workspace_list.get_child_count(), 0, "no workspace rows")
	assert_false(ws._sidebar._workspaces_close_all_btn.visible,
		"no workspace, no close-all")
	assert_true(ws._sidebar._workspaces_add_btn.visible, "the add button remains")
	assert_false(ws._sidebar._pane_heading.visible, "no panes, no heading")
	await get_tree().create_timer(2.1).timeout

func test_an_empty_saved_store_does_not_reimport_the_legacy_layout():
	# Close-all persists `workspaces: []`, and the pre-workspaces `layout.json`
	# beside it is a one-shot migration source. Treating the saved empty set as
	# a first run re-imported those old panes on the next launch (and asked
	# about their different shell) instead of showing the empty state.
	MockAutoloads.set_store(WorkspaceStore.FILE, {"active": 0, "workspaces": []})
	MockAutoloads.set_store(WorkspaceStore.LEGACY_FILE, {"tiles": [{
		"col": 0, "row": 0, "cspan": PaneTypes.GRID, "rspan": PaneTypes.GRID,
		"settings": {"type": "terminal"},
	}]})
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(ws._workspaces.size(), 0, "the saved empty set is not a first run")
	assert_eq(ws._tm.tiles.size(), 0, "the legacy layout's panes are not spawned")
	assert_true(ws._empty_state.visible, "the empty-state guide takes the grid")
	await get_tree().create_timer(2.1).timeout

func test_a_missing_store_still_imports_the_legacy_layout():
	# The migration is still a first-run path: no store file at all means the
	# old layout is the only saved state there is.
	MockAutoloads.remove_store(WorkspaceStore.FILE)
	MockAutoloads.set_store(WorkspaceStore.LEGACY_FILE, {"tiles": [{
		"col": 0, "row": 0, "cspan": PaneTypes.GRID, "rspan": PaneTypes.GRID,
		"settings": {"type": "terminal"},
	}]})
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(ws._workspaces.size(), 1, "the legacy layout becomes Workspace 1")
	assert_eq(str(ws._workspaces[0].name), "Workspace 1")
	assert_eq(ws._tm.tiles.size(), 1, "its pane is restored")
	await get_tree().create_timer(2.1).timeout

func test_the_first_pane_creates_the_default_workspace():
	MockAutoloads.set_store(WorkspaceStore.FILE, {"active": 0, "workspaces": []})
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	var body = ws._spawn_pane("terminal")
	assert_not_null(body, "a pane can be created with no workspace")
	assert_eq(ws._workspaces.size(), 1, "the pane creates its workspace")
	assert_eq(str(ws._workspaces[0].name), "Default")
	assert_eq(ws._tm.tiles.size(), 1)
	assert_false(ws._empty_state.visible, "the guide leaves")
	await get_tree().create_timer(2.1).timeout

func test_the_add_button_creates_default_from_zero():
	MockAutoloads.set_store(WorkspaceStore.FILE, {"active": 0, "workspaces": []})
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	ws._add_workspace()
	assert_eq(ws._workspaces.size(), 1)
	assert_eq(str(ws._workspaces[0].name), "Default")
	assert_eq(ws._tm.tiles.size(), 0, "the add button creates a blank workspace")
	assert_true(ws._empty_state.visible, "the guide stays until a pane exists")
	await get_tree().create_timer(2.1).timeout

func test_closing_the_last_workspace_enters_the_empty_state():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(ws._workspaces.size(), 1, "the fixture starts with one workspace")
	ws._close_workspace_now(0)
	assert_true(ws._workspaces.is_empty(), "the last workspace is discardable")
	assert_eq(ws._tm.tiles.size(), 0)
	assert_true(ws._empty_state.visible, "the guide takes the screen")
	await get_tree().process_frame
	assert_eq(ws._sidebar._workspace_list.get_child_count(), 0, "no rows remain")
	assert_false(ws._sidebar._workspaces_close_all_btn.visible,
		"the close-all trash disappears with the last workspace")
	await get_tree().create_timer(2.1).timeout

func test_the_panes_title_row_closes_all_panes():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	var close_all := ws._sidebar.find_child("PanesCloseAllBtn", true, false) as Button
	assert_not_null(close_all, "the panes title row carries the close-all")
	close_all.pressed.emit()
	var ok := ws._sidebar.find_child("PanesCloseAllConfirmOk", true, false) as Button
	assert_not_null(ok, "the trash opened the inline check")
	ok.pressed.emit()
	# An idle shell may or may not report foreground work on this platform; a
	# running command would raise the modal (pinned in `test_pane_close_guard`).
	var dialog := ws.find_child("RunningWorkConfirm", false, false) as ConfirmationDialog
	if dialog != null:
		dialog.get_ok_button().pressed.emit()
		await get_tree().process_frame
	assert_eq(ws._tm.tiles.size(), 0, "every pane is gone")
	assert_true(ws._empty_state.visible)
	assert_false(ws._sidebar._pane_heading.visible, "the empty section has no heading")
	await get_tree().create_timer(2.1).timeout

func test_the_workspaces_title_row_closes_all_workspaces():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	ws._add_workspace()
	await get_tree().process_frame
	var close_all := ws._sidebar.find_child("WorkspacesCloseAllBtn", true, false) as Button
	assert_not_null(close_all, "the workspaces title row carries the close-all")
	close_all.pressed.emit()
	var ok := ws._sidebar.find_child("WorkspacesCloseAllConfirmOk", true, false) as Button
	assert_not_null(ok, "the trash opened the inline check")
	ok.pressed.emit()
	var dialog := ws.find_child("RunningWorkConfirm", false, false) as ConfirmationDialog
	if dialog != null:
		dialog.get_ok_button().pressed.emit()
		await get_tree().process_frame
	assert_true(ws._workspaces.is_empty(), "every workspace is gone")
	assert_eq(ws._tm.tiles.size(), 0)
	assert_true(ws._empty_state.visible)
	assert_false(ws._sidebar._workspaces_close_all_btn.visible)
	await get_tree().create_timer(2.1).timeout

func test_the_workspace_menu_lists_directory_and_clear():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	var source := Button.new()
	add_child_autofree(source)
	ws._on_workspace_menu(0, source)
	var menu := ws.find_child("WorkspaceActionsMenu", true, false) as PopupMenu
	assert_not_null(menu, "the More button opens the workspace menu")
	assert_eq(menu.item_count, 2)
	assert_eq(menu.get_item_text(0), "Set Directory")
	assert_string_contains(menu.get_item_tooltip(0), "Working directory:",
		"the directory item carries the current path")
	assert_not_null(menu.get_item_icon(0), "the folder glyph is a menu icon")
	# A texture that is null is not the only failure: an opaque or blank atlas
	# region would draw a square or nothing. The glyph's alpha must cover some
	# pixels and not all of them.
	var icon_image := (menu.get_item_icon(0) as ImageTexture).get_image()
	var covered := 0
	for y in icon_image.get_height():
		for x in icon_image.get_width():
			if icon_image.get_pixel(x, y).a > 0.0:
				covered += 1
	assert_gt(covered, 0, "the folder icon has glyph pixels")
	assert_lt(covered, icon_image.get_width() * icon_image.get_height(),
		"and is not a filled square")
	assert_eq(menu.get_item_text(1), "Clear Workspace")
	assert_string_contains(menu.get_item_tooltip(1), "Close every pane")
	assert_not_null(menu.get_item_icon(1), "the trash glyph is a menu icon")
	menu.queue_free()
	await get_tree().create_timer(2.1).timeout

func test_clearing_a_hidden_workspace_does_not_switch():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	ws._add_workspace()
	await get_tree().process_frame
	var first: Dictionary = ws._workspaces[0]
	first["profile"] = "P"
	var active_before: int = ws._active
	ws._clear_workspace(0)
	var dialog := ws.find_child("RunningWorkConfirm", false, false) as ConfirmationDialog
	if dialog != null:
		dialog.get_ok_button().pressed.emit()
		await get_tree().process_frame
	assert_eq(first.tm.tiles.size(), 0, "the hidden workspace is cleared")
	assert_eq(ws._workspaces.size(), 2, "and not removed")
	assert_eq(ws._active, active_before, "the active workspace never switched")
	assert_eq(str(first.get("profile", "")), "", "a cleared workspace loses its profile")
	await get_tree().create_timer(2.1).timeout

func test_profile_activation_refreshes_layout_and_pane_list():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)  # give layout math a real viewport
	await get_tree().process_frame
	await get_tree().process_frame

	ws._do_activate({"name": "P", "tiles": [
		{"col": 0, "row": 0, "cspan": 6, "rspan": 12,
			"settings": {"type": "code_viewer", "pane_name": "C1"}},
		{"col": 6, "row": 0, "cspan": 6, "rspan": 12,
			"settings": {"type": "terminal", "shell": SettingsManager.default_shell_command(), "rows": 24, "cols": 80}},
	]}, false)
	await get_tree().process_frame
	await get_tree().process_frame

	var tm: TerminalManager = ws._tm
	assert_eq(tm.tiles.size(), 2, "activation should restore two panes")
	# Regression: the pane list must populate immediately — no workspace
	# switch-and-back required.
	assert_eq(ws._sidebar._pane_list.get_child_count(), 2,
		"pane list must reflect the activated profile immediately")
	# Regression: wrappers must be laid out (not squished at the origin).
	var w0: Control = tm.tiles[0].wrapper
	assert_gt(w0.offset_right - w0.offset_left, 100.0,
		"activated wrapper must be laid out with real width")
	# Wait out the deferred concept push timer so it doesn't resume after free.
	await get_tree().create_timer(2.1).timeout


func test_killing_the_focused_pane_hands_focus_to_the_last_survivor():
	# Closing the active pane used to leave keyboard focus unowned: the freed
	# node released it, last_body went null, and typing reached nothing until
	# the user clicked a pane. It then handed focus to the *first* terminal,
	# although the tiling logic grows the last tile into the freed space:
	# T1,T2,T3 minus T3 must leave T2 active, not T1.
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame

	var first = ws._tm._find_body(ws._tm.tiles[0].wrapper)
	assert_not_null(first, "precondition: the startup terminal")
	var middle = ws._spawn_pane("terminal")
	assert_not_null(middle, "the second terminal must spawn")
	var victim = ws._spawn_pane("terminal")
	assert_not_null(victim, "the third terminal must spawn")
	assert_eq(ws._tm.tiles.size(), 3, "precondition: three panes")
	assert_eq(ws._tm._find_body(ws._tm.tiles[-1].wrapper), victim,
		"precondition: the newest pane is the last tile")
	assert_eq(ws._tm.last_body, victim, "a spawned pane is the active pane")
	assert_true(victim.has_focus(), "precondition: the pane to close holds focus")

	ws._kill_now(victim)
	await get_tree().process_frame
	await get_tree().process_frame

	var survivor = ws._tm.last_body
	assert_not_null(survivor, "some pane must hold focus after the active one is closed")
	assert_true(is_instance_valid(survivor))
	assert_ne(survivor, victim, "focus must not stay on the closed pane")
	assert_eq(survivor, middle, "the last surviving tile becomes the active pane")
	assert_ne(survivor, first, "not the first pane in the list")
	assert_true(survivor.has_focus(), "the surviving terminal must hold keyboard focus")

	await get_tree().create_timer(2.1).timeout

func test_closing_the_active_pane_records_a_read_only_last_pane():
	# A read-only survivor cannot take the keyboard, but it is still the active
	# pane - the sidebar accent, the status bar and "close active" all name it -
	# and the keys go back to the window rather than staying on the freed pane.
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame

	var terminal = ws._tm._find_body(ws._tm.tiles[0].wrapper)
	assert_not_null(terminal, "precondition: the startup terminal")
	var viewer = ws._spawn_pane("code_viewer", {})
	assert_not_null(viewer, "the read-only pane must spawn")
	ws.activate_pane(terminal)
	assert_eq(ws.get_viewport().gui_get_focus_owner(), terminal,
		"precondition: the terminal holds the keyboard")

	ws._kill_now(terminal)
	await get_tree().process_frame
	await get_tree().process_frame

	assert_eq(ws._tm.last_body, viewer,
		"the last surviving pane becomes the active one, read-only or not")
	assert_null(ws.get_viewport().gui_get_focus_owner(),
		"and it releases the keyboard instead of grabbing it")

	await get_tree().create_timer(2.1).timeout


func test_restore_renames_duplicate_attachment_ids():
	# Every pane is addressed over IPC by attachment_id and resolution returns
	# the first match, so a saved layout naming one id twice would make inject,
	# read, status, wait, kill and focus all silently act on the same pane.
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame

	ws._build_workspaces([
		{"name": "W1", "layout": [
			{"col": 0, "row": 0, "cspan": 6, "rspan": 12,
			 "settings": {"type": "terminal", "attachment_id": "shared-id"}},
			{"col": 6, "row": 0, "cspan": 6, "rspan": 12,
			 "settings": {"type": "terminal", "attachment_id": "shared-id"}},
		]},
	], 0)

	var ids: Array = []
	for t in ws._tm.tiles:
		var body = ws._tm._find_body(t.wrapper)
		if body:
			ids.append(body.attachment_id)
	assert_eq(ids.size(), 2, "both saved tiles must restore")
	assert_ne(ids[0], ids[1], "duplicate attachment_ids must be made unique")
	assert_eq(ids[0], "shared-id", "the first pane keeps the saved id")
	assert_ne(ids[1], "", "the renamed pane must still have an id")

	await get_tree().create_timer(2.1).timeout

## A restored layout must end up the same *size on screen* as it was saved.
##
## The grid unit is a single constant (PaneTypes.GRID) read by the drag math,
## the sanitizer, and `_apply_layout`; when a second copy of it drifted, the
## sanitizer clamped a half-width tile to a single cell and the layout divided
## by the wrong unit, so the restored panes were sized several times the grid
## and drew outside the visible area. Asserting spans alone misses that: the
## wrappers' rects are what the user sees.
func test_restored_layout_keeps_its_share_of_the_screen():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	# A legacy (12-unit) two-pane profile: the migration must scale it.
	ws._do_activate({"name": "P", "tiles": [
		{"col": 0, "row": 0, "cspan": 6, "rspan": 12,
			"settings": {"type": "code_viewer", "pane_name": "C1"}},
		{"col": 6, "row": 0, "cspan": 6, "rspan": 12,
			"settings": {"type": "terminal", "shell": SettingsManager.default_shell_command(), "rows": 24, "cols": 80}},
	]}, false)
	await get_tree().process_frame
	await get_tree().process_frame

	var tm: TerminalManager = ws._tm
	assert_eq(tm.tiles.size(), 2, "the profile must restore both panes")
	var grid: Control = ws._grid
	var left: Rect2 = (tm.tiles[0].wrapper as Control).get_global_rect()
	var right: Rect2 = (tm.tiles[1].wrapper as Control).get_global_rect()
	assert_almost_eq(left.size.x, grid.size.x * 0.5, grid.size.x * 0.02,
		"a half-width pane must be half the grid wide, not a multiple of it")
	assert_almost_eq(left.size.x + right.size.x, grid.size.x, grid.size.x * 0.02,
		"the two panes must fill the grid between them")
	assert_almost_eq(right.position.x, left.position.x + left.size.x, 1.0,
		"the second pane must start where the first ends")

func test_an_emptied_workspace_shows_the_guide():
	var ws = WorkspaceScript.new()
	_ws = ws
	ws.size = Vector2(1200, 800)
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame

	var empty := ws.get_node_or_null("EmptyState") as Control
	assert_not_null(empty, "the workspace builds the empty state")
	assert_false(empty.visible, "a spawned pane replaces the guide")

	ws._reset_now()
	await get_tree().process_frame
	await get_tree().process_frame

	assert_true(empty.visible, "closing the last pane brings the guide back")
	var guide: ShortcutGuide = ws._shortcut_guide
	assert_not_null(guide, "the empty state builds the shortcut guide")
	assert_eq(guide.rows(),
		ShortcutCatalog.rows(func(action: String): return ShortcutManager.chord(action)),
		"every registered binding is listed")
	assert_eq((guide.find_child("Title", true, false) as Label).text, "Getting Started")
	assert_null(guide.find_child("Subtitle", true, false), "the guide has no subtitle")
	assert_null(guide.find_child("PrimaryAction", true, false),
		"the hero keycap is the only action")
	var hero := guide.find_child("HeroKeycap", true, false) as Button
	assert_not_null(hero, "the animated keycap is clickable")
	assert_eq(hero.tooltip_text, "New Terminal (Ctrl+Shift+N)")
	assert_almost_eq(guide.get_global_rect().get_center().y,
		empty.get_global_rect().get_center().y, 2.0,
		"the guide is centred when it fits")

	guide.pin_animation()
	hero.pressed.emit()
	await get_tree().process_frame
	assert_eq(ws._tm.tiles.size(), 1, "the keycap spawns the pane it shows")
	assert_false(empty.visible, "spawning hides the guide again")

	# The second step is the code viewer: clicking then must start that pane,
	# not a terminal. The clock is pinned so the step under test is exact.
	ws._reset_now()
	await get_tree().process_frame
	assert_true(empty.visible, "closing the pane brings the guide back")
	guide.pin_animation()
	guide._process(ShortcutGuide.HERO_CYCLE + 0.01)
	assert_eq(hero.tooltip_text, "New Code Viewer (Ctrl+Shift+D)")
	hero.pressed.emit()
	await get_tree().process_frame
	assert_eq(ws._tm.tiles.size(), 1)
	var body = ws._tm._find_body(ws._tm.tiles[0].wrapper)
	assert_true(body is CodeViewerPane, "the code-viewer step starts a code viewer")

	# Wait out the deferred concept push so it cannot resume after the free.
	await get_tree().create_timer(2.1).timeout

func test_the_empty_guide_scrolls_at_the_layout_floor():
	var ws = WorkspaceScript.new()
	_ws = ws
	ws.size = Vector2(540, 560)  # UiTokens.MIN_LAYOUT
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	ws._reset_now()
	await get_tree().process_frame
	await get_tree().process_frame

	var empty: ScrollContainer = ws._empty_state
	assert_not_null(empty)
	assert_true(empty.visible, "the guide owns an empty workspace")
	var guide: ShortcutGuide = ws._shortcut_guide
	assert_not_null(guide)
	assert_true(guide.size.x <= empty.size.x, "the guide fits the grid width")
	assert_true(empty.get_v_scroll_bar().max_value > empty.size.y,
		"the atlas scrolls instead of clipping at the layout floor")

	await get_tree().create_timer(2.1).timeout

## The row's end-to-end proof: a mode change through the settings save re-themes
## the live window - the one Theme, the clear colour, the user-coloured chrome
## and the token-only status bar - and switching back restores it.
func test_the_chrome_follows_the_appearance_mode_live():
	var ws = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame

	var wrapper: PanelContainer = ws._tm.tiles[0].wrapper
	var sb = wrapper.get_theme_stylebox("panel") as StyleBoxFlat
	assert_not_null(sb, "wrapper must carry a panel stylebox")

	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_LIGHT
	SettingsManager.save_settings()

	var panel := ws.theme.get_stylebox("panel", "Panel") as StyleBoxFlat
	assert_eq(panel.bg_color, UiPalette.light().SURFACE,
		"the panel is the light surface")
	assert_eq(ws.theme.get_color("font_color", "Label"), UiPalette.light().TEXT,
		"the chrome's ink inverted")
	assert_eq(RenderingServer.get_default_clear_color(), UiPalette.light().BG,
		"the content area's clear colour followed")
	assert_eq(sb.bg_color, UiPalette.light().BG,
		"the existing wrapper followed without a respawn")
	assert_eq(ws._sidebar_bg.color, UiPalette.light().SIDEBAR,
		"the sidebar followed")
	assert_not_null(ws._status_bar, "the status bar exists")
	assert_eq(ws._status_bar._bg.color, UiPalette.light().SURFACE_RAISED,
		"the status bar's own surface followed")

	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_DARK
	SettingsManager.save_settings()
	panel = ws.theme.get_stylebox("panel", "Panel") as StyleBoxFlat
	assert_eq(panel.bg_color, UiPalette.dark().SURFACE, "and back again")
	assert_eq(sb.bg_color, UiPalette.dark().BG)

	# Wait out the deferred concept push so it cannot resume after the free.
	await get_tree().create_timer(2.1).timeout

# ── Same-name profile replacement ─────────────────────────────────────

func _find_dialog(ws: Control, needle: String) -> ConfirmationDialog:
	for child in ws.get_children():
		if child is ConfirmationDialog:
			if needle in AppDialog.body_of(child):
				return child
	return null

func _open_workspace_for_profiles() -> Control:
	MockAutoloads.set_store(WorkspaceStore.FILE, {
		"active": 0, "workspaces": [{"name": "W", "layout": [{
			"col": 0, "row": 0, "cspan": 60, "rspan": 60,
			"settings": {"type": "code_viewer"},
		}]}],
	})
	var ws: Control = WorkspaceScript.new()
	_ws = ws
	ws.size = Vector2(1200, 800)
	add_child(ws)
	await get_tree().process_frame
	await get_tree().process_frame
	return ws

func test_renaming_to_an_existing_user_profile_asks_to_replace():
	var ws := await _open_workspace_for_profiles()
	ProfileManager.add_profile("Target", [])
	ProfileManager.add_profile("Source", [])

	ws._rename_profile(1, "Target")
	var dialog := _find_dialog(ws, "already exists")
	assert_not_null(dialog, "a same-name rename must ask first")
	assert_string_contains(AppDialog.body_of(dialog), "Target")
	dialog.confirmed.emit()

	assert_eq(ProfileManager.profiles.size(), 1,
		"confirming replaces the target, it does not keep both")
	assert_eq(ProfileManager.profiles[0].get("name"), "Target")
	await get_tree().create_timer(2.1).timeout

func test_cancelling_a_replace_rename_keeps_both_profiles():
	var ws := await _open_workspace_for_profiles()
	ProfileManager.add_profile("Target", [])
	ProfileManager.add_profile("Source", [])

	ws._rename_profile(1, "Target")
	var dialog := _find_dialog(ws, "already exists")
	assert_not_null(dialog)
	dialog.canceled.emit()

	assert_eq(ProfileManager.profiles.size(), 2, "cancel keeps both profiles")
	assert_eq(ProfileManager.profiles[0].get("name"), "Target")
	assert_eq(ProfileManager.profiles[1].get("name"), "Source")
	await get_tree().create_timer(2.1).timeout

func test_saving_over_an_existing_profile_asks_before_replacing_tiles():
	var ws := await _open_workspace_for_profiles()
	ProfileManager.add_profile("Target", [])
	var before := (ProfileManager.profiles[0].get("tiles") as Array).size()

	ws._save_current_as_profile()
	var save_dialog: ConfirmationDialog = null
	for child in ws.get_children():
		if child is ConfirmationDialog and AppDialog.body_of(child) == "":
			save_dialog = child
			break
	assert_not_null(save_dialog, "the Save Profile dialog must open")
	var name_input: LineEdit = null
	for node in save_dialog.find_children("*", "LineEdit", true, false):
		name_input = node as LineEdit
		if name_input != null and name_input.placeholder_text == "My Profile":
			break
	assert_not_null(name_input, "the save dialog has a name field")
	name_input.text = "Target"
	save_dialog.confirmed.emit()

	var replace_dialog := _find_dialog(ws, "already exists")
	assert_not_null(replace_dialog, "a same-name save must ask before replacing")
	assert_eq((ProfileManager.profiles[0].get("tiles") as Array).size(), before,
		"the old tiles stay until the replacement is confirmed")
	replace_dialog.confirmed.emit()

	assert_eq(ProfileManager.profiles.size(), 1, "the save replaces, not duplicates")
	assert_gt((ProfileManager.profiles[0].get("tiles") as Array).size(), before,
		"confirming writes the current workspace's tiles")
	await get_tree().create_timer(2.1).timeout
