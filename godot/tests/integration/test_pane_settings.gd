extends GutTest
# Integration tests: settings application to pane bodies.
# Verifies that apply_settings propagates correctly.

var _scene: Control
var _tm: TerminalManager

## The pane settings panel is a real Control; a fixture provides only the two
## fields `_build_pane_settings_ui` writes and reads.
class FakePanePanel extends Control:
	var _debounce_timer: Timer
	var _gather_func: Callable

	func _init():
		_debounce_timer = Timer.new()
		# A real panel's timer is a child; the builder connects every field to
		# `start()`, so a tree-less Timer would log an error on the first edit.
		add_child(_debounce_timer)


func _option_with_item(root: Node, text: String) -> OptionButton:
	for node in root.find_children("*", "OptionButton", true, false):
		var opt := node as OptionButton
		for i in opt.item_count:
			if opt.get_item_text(i) == text:
				return opt
	return null

func _line_edit_named(root: Node, node_name: String) -> LineEdit:
	for node in root.find_children(node_name, "LineEdit", true, false):
		return node as LineEdit
	return null

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_default_rows = 24
	SettingsManager.cfg_default_cols = 80
	SettingsManager.cfg_font_size = 14
	_scene = TestScene.create()
	add_child(_scene)
	_tm = TerminalManager.new()

func after_each():
	_tm.reset()
	MockAutoloads.teardown()
	if _scene:
		_scene.queue_free()

# ── Settings application ───────────────────────────────────────────────

## Each of these checks the *effect* of the setting on the live pane, not that
## a property reads back what was assigned — a setter that stored the value
## and applied it nowhere would have passed the read-back.

func test_apply_settings_font_size():
	var body = _tm.create_body("terminal")
	_scene.add_child(body)
	assert_not_null(body)
	var cell_w: float = body._cell_w
	var cell_h: float = body._cell_h
	assert_gt(cell_w, 0.0, "the pane must have measured its glyphs before the change")

	body.apply_settings({"font_size": 28})

	assert_eq(body.font_size, 28)
	assert_gt(body._cell_w, cell_w, "a larger font must widen the cell")
	assert_gt(body._cell_h, cell_h, "a larger font must heighten the cell")
	assert_eq(body._font.fixed_size, 28, "the font itself is resized, not just the property")

## The v0.8.6 row **A pane's font-size setting does not reach text already on
## screen**: an Inspector with an answer on screen must follow a Pane Settings
## edit, height included.
func test_a_font_size_change_reaches_an_inspector_answer():
	var body = _tm.create_body("inspector")
	_scene.add_child(body)
	body.size = Vector2(420, 320)
	await get_tree().process_frame
	await get_tree().process_frame
	body._display.render_now("word ".repeat(200))
	await get_tree().create_timer(0.15).timeout
	var tall: float = body._display.get_content_height()
	assert_gt(tall, 0.0, "the answer must have a measured height first")

	body.apply_settings({"font_size": 24})
	await get_tree().create_timer(0.15).timeout

	assert_eq(body._display.get_theme_font_size("normal_font_size"), 24)
	assert_eq(body._thinking_display.get_theme_font_size("normal_font_size"), 24)
	assert_gt(body._display.get_content_height(), tall,
		"the larger font must be re-measured, not just re-assigned")

func test_a_font_size_change_reaches_a_rendered_file():
	var body = _tm.create_body("code_viewer")
	body.language = "md"
	_scene.add_child(body)
	body.size = Vector2(420, 320)
	await get_tree().process_frame
	await get_tree().process_frame
	body.receive_content("word ".repeat(200))
	await get_tree().create_timer(0.15).timeout
	var tall: float = body._markdown.get_content_height()
	assert_gt(tall, 0.0)

	body.apply_settings({"font_size": 24})
	await get_tree().create_timer(0.15).timeout

	assert_eq(body._editor.get_theme_font_size("font_size"), 24)
	assert_eq(body._markdown.get_theme_font_size("normal_font_size"), 24)
	assert_gt(body._markdown.get_content_height(), tall)
	assert_eq(body._empty_title.get_theme_font_size("font_size"), 26,
		"the empty-state title follows the body text, one step above it")
	assert_eq(body._empty_hint.get_theme_font_size("font_size"), 24)

func test_a_font_size_change_reaches_streamed_output():
	var body = _tm.create_body("cli_view")
	_scene.add_child(body)
	body._editor.text = "prior output"
	body.apply_settings({"font_size": 22})
	assert_eq(body._editor.get_theme_font_size("font_size"), 22,
		"the output view is where a read continues")

func test_a_font_size_change_reaches_the_file_tree():
	var body = _tm.create_body("file_tree")
	_scene.add_child(body)
	body.apply_settings({"font_size": 24})
	assert_eq(body._tree.get_theme_font_size("font_size"), 24,
		"the tree is this pane's only text surface")
	assert_eq(body._empty_hint.get_theme_font_size("font_size"), 24)

func test_a_font_size_change_reaches_the_media_placeholder():
	var body = _tm.create_body("media")
	_scene.add_child(body)
	body.apply_settings({"font_size": 24})
	assert_eq(body._status.get_theme_font_size("font_size"), 22,
		"the status line keeps its caption-relative offset to the body size")
	assert_eq(body._placeholder_title.get_theme_font_size("font_size"), 26)
	assert_eq(body._placeholder_hint.get_theme_font_size("font_size"), 24)

func test_a_font_size_change_reaches_an_open_note():
	var body = _tm.create_body("wiki")
	_scene.add_child(body)
	body.apply_settings({"font_size": 24})
	assert_eq(body._editor.get_theme_font_size("font_size"), 24)
	assert_eq(body._reader.get_theme_font_size("normal_font_size"), 24)

## The setter now runs for every pane type, so it can fire before `_ready`
## loads the terminal's faces: that call must not touch them, and the size must
## land once `_ready` has them.
func test_a_font_size_applied_before_the_terminal_is_ready_lands_with_its_font():
	var body = _tm.create_body("terminal")
	body.apply_settings({"font_size": 22})
	assert_null(body._font, "no face exists before the pane enters the tree")
	_scene.add_child(body)
	assert_eq(body._font.fixed_size, 22)
	assert_eq(body._cell_h, body._font.get_height(22),
		"the grid must be measured at the size the pane holds")

## A stored `rows`/`cols` no longer resizes a live grid: the pixel fit owns the
## size, because a grid larger than the tile draws cells the tile cannot show
## (the cursor lands off-screen behind `clip_contents`) and the next resize
## would revert it anyway. The fields remain the pre-layout fallback.
func test_apply_settings_rows_cols_never_resizes_a_live_grid():
	var body = _tm.create_body("terminal")
	_scene.add_child(body)
	assert_not_null(body._terminal, "the pane must own a grid for this test")
	body.size = Vector2(900, 600)
	var fitted_rows := int((body.size.y - TerminalPane.PADDING) / body._cell_h)
	assert_eq(body._terminal.get_rows(), fitted_rows,
		"the pane started its child at the size it is drawn at")

	body.apply_settings({"rows": 30, "cols": 100})

	assert_eq([body.rows, body.cols], [30, 100], "the fallback the settings name is kept")
	assert_eq(body._terminal.get_rows(), fitted_rows,
		"a stored size must never resize the live grid")

func test_apply_settings_pane_name():
	var body = _tm.create_body("code_viewer")
	_scene.add_child(body)
	watch_signals(body)
	body.apply_settings({"pane_name": "CustomName"})
	assert_eq(body.pane_name, "CustomName")
	assert_signal_emitted_with_parameters(body, "title_changed", ["CustomName"])
	assert_eq(body._get_layout_state()["pane_name"], "CustomName",
		"the name is what gets saved")

func test_apply_to_terminal_from_settings():
	var body = _tm.create_body("terminal")
	_scene.add_child(body)
	SettingsManager.cfg_font_size = 18
	SettingsManager.cfg_cursor_shape = 1  # block
	SettingsManager.apply_to_terminal(body)
	assert_eq(body.font_size, 18)
	assert_eq(body.get("cursor_shape"), 1)

func test_apply_pane_settings_delegates():
	var body = _tm.create_body("code_viewer")
	_scene.add_child(body)
	watch_signals(body)
	SettingsManager.apply_pane_settings(body, {"font_size": 22, "pane_name": "Delegated"})
	assert_eq(body.font_size, 22)
	# `title_changed` only comes out of the body's own `apply_settings`, so this
	# fails if the call stops going through it (a bare property write would
	# still have set font_size).
	assert_signal_emitted_with_parameters(body, "title_changed", ["Delegated"])

# ── Layout state ───────────────────────────────────────────────────────

func test_terminal_get_layout_state_carries_what_the_pane_holds():
	var body = _tm.create_body("terminal")
	_scene.add_child(body)
	body.shell_command = "/opt/custom-shell"
	body.shell_args = ["--login"]
	body.rows = 33
	body.cols = 91
	var state = body._get_layout_state()
	assert_eq(state.get("type"), "terminal")
	assert_eq(state.get("shell"), "/opt/custom-shell")
	assert_eq(state.get("shell_args"), ["--login"])
	assert_eq([state.get("rows"), state.get("cols")], [33, 91])
	assert_false(state.has("shell_env"), "a saved file must never carry the pane's env")

func test_code_viewer_get_layout_state_round_trips_through_apply_settings():
	var body = _tm.create_body("code_viewer")
	_scene.add_child(body)
	body.apply_settings({"pane_name": "Viewer", "font_size": 19})
	var state = body._get_layout_state()
	assert_eq(state.get("type"), "code_viewer")
	var twin = _tm.create_body("code_viewer")
	_scene.add_child(twin)
	twin.apply_settings(state)
	assert_eq(twin._get_layout_state(), state, "state -> apply -> state is stable")

## The panel re-applies its whole gathered dictionary on every debounced edit,
## so a rename arrives with the same `file_path`. The viewer must not reload
## then: the re-read resets the read-only editor's caret and scroll, losing the
## reader's place for an unrelated edit.
func test_a_name_edit_keeps_the_viewers_scroll():
	var first := TestPaths.user_path("code_viewer_scroll_a.txt")
	var second := TestPaths.user_path("code_viewer_scroll_b.txt")
	var lines := PackedStringArray()
	for i in 200:
		lines.append("line %d of the probe" % i)
	_write_probe(first, "\n".join(lines))
	_write_probe(second, "a different document\n")

	var body = _tm.create_body("code_viewer")
	_scene.add_child(body)
	body.size = Vector2(800, 600)
	body.load_file(first)
	await get_tree().process_frame
	body._editor.scroll_vertical = 10
	assert_gt(body._editor.scroll_vertical, 0,
		"the probe needs a scrollable document to prove anything")
	var scrolled: int = body._editor.scroll_vertical

	body.apply_settings({"pane_name": "Renamed", "file_path": first})
	await get_tree().process_frame
	assert_eq(body._editor.scroll_vertical, scrolled,
		"an unrelated edit must not reset the reader's place")
	assert_string_contains(body._editor.text, "line 0 of the probe",
		"the document is still the one it held")

	# A path that really moved still reloads: the guard is not "never reload".
	body.apply_settings({"file_path": second})
	await get_tree().process_frame
	assert_eq(body._editor.text, "a different document\n",
		"a moved path must load the new file")

	DirAccess.remove_absolute(first)
	DirAccess.remove_absolute(second)

func _write_probe(path: String, text: String):
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()

## `open_in` is a closed vocabulary and travels the same path as every other
## pane setting: the settings UI gathers it, `apply_settings` accepts it, and
## the tile state carries it back.
func test_file_tree_open_in_round_trips_through_the_pane_settings_ui():
	var body = _tm.create_body("file_tree")
	_scene.add_child(body)
	var panel := FakePanePanel.new()
	_scene.add_child(panel)
	var ui: Control = body._build_pane_settings_ui(panel)
	_scene.add_child(ui)

	var opt := _option_with_item(ui, "System application")
	assert_not_null(opt, "the pane settings must offer the system route")
	opt.select(1)

	var gathered: Dictionary = panel._gather_func.call()
	assert_eq(gathered.get("open_in"), "system")
	body.apply_settings(gathered)

	var state = body._get_layout_state()
	assert_eq(state.get("open_in"), "system", "the choice is part of the tile state")
	var twin = _tm.create_body("file_tree")
	_scene.add_child(twin)
	twin.apply_settings(state)
	assert_eq(twin.open_in, "system", "state -> apply restores the choice")
	assert_eq(twin._get_layout_state(), state, "state -> apply -> state is stable")

	# A saved file is untrusted input: the table refuses an unknown member, so
	# the pane keeps the route it had instead of silently falling back to one
	# the user did not pick.
	twin.open_in = "system"
	twin.apply_settings({"open_in": "something-else"})
	assert_eq(twin.open_in, "system", "a refused member changes nothing")

## The row's motivating case: the table used to accept a value the pane then
## dropped, so `paneSet` answered success with `changed: []`. The refusal now
## happens in the table, before the property is touched.
func test_a_closed_set_member_never_reaches_the_pane():
	var wiki = _tm.create_body("wiki")
	_scene.add_child(wiki)
	wiki.view_mode = "preview"
	wiki.apply_settings({"view_mode": "bogus"})
	assert_eq(wiki.view_mode, "preview", "a refused note view changes nothing")

	var viewer = _tm.create_body("code_viewer")
	_scene.add_child(viewer)
	viewer.view_mode = "rendered"
	viewer.language = "md"
	viewer.apply_settings({"view_mode": "bogus", "language": "klingon"})
	assert_eq(viewer.view_mode, "rendered", "a refused view mode changes nothing")
	assert_eq(viewer.language, "md", "a refused language changes nothing")

	var tree = _tm.create_body("file_tree")
	_scene.add_child(tree)
	tree.open_in = "system"
	tree.apply_settings({"open_in": "bogus"})
	assert_eq(tree.open_in, "system", "a refused route changes nothing")

## The closed table is the only rule owner: a value a rule refuses leaves the
## property alone, and a pane's own `apply_settings` never re-applies the rule.
## The duplicate that used to live in each override could silently diverge
## from the table (it cleared a `shell_args` the table had dropped, re-clamped
## a non-finite volume to the top of the range, and assigned a `model` past
## its length cap), so each pane is held to the table's decision here.
func test_a_refused_setting_value_leaves_each_panes_property_alone():
	var scripts := TerminalManager._PaneScripts

	var term: Control = scripts["terminal"].new()
	term.shell_args = ["-lc", "true"]
	term.apply_settings({"shell_args": "not-an-array"})
	assert_eq(term.shell_args, ["-lc", "true"], "a refused argv changes nothing")
	term.free()

	var cli: Control = scripts["cli_view"].new()
	cli.command = "/bin/echo"
	cli.shell_args = ["-n"]
	cli.apply_settings({"command": "x".repeat(2048), "shell_args": "not-an-array"})
	assert_eq(cli.command, "/bin/echo", "an oversized program changes nothing")
	assert_eq(cli.shell_args, ["-n"], "a refused argv changes nothing")
	cli.free()

	var insp: Control = scripts["inspector"].new()
	insp.model = "current"
	insp.auto_run = false
	insp.command = ["-x"]
	insp.apply_settings({"model": "m".repeat(200), "auto_run": "yes", "command": "not-an-array"})
	assert_eq(insp.model, "current", "an oversized model changes nothing")
	assert_false(insp.auto_run, "a non-boolean switch changes nothing")
	assert_eq(insp.command, ["-x"], "a refused argv changes nothing")
	insp.free()

	# Added to the tree: `apply_settings` returns early until `_ready` built
	# `_video_surface`, and only the audio lane is under test here.
	var media: Control = MediaPane.new()
	_scene.add_child(media)
	await get_tree().process_frame
	media.volume_db = -6.0
	media.apply_settings({"volume_db": INF})
	assert_eq(media.volume_db, -6.0, "a non-finite volume changes nothing")

	var reason: Control = scripts["reasoning"].new()
	reason.source_attachment_id = "agent-terminal"
	reason.apply_settings({"source_attachment_id": "OMP"})
	assert_eq(reason.source_attachment_id, "agent-terminal", "a malformed id changes nothing")
	reason.free()

## A terminal's launch line is the spawn plan a user can name: the panel
## gathers it, `apply_settings` accepts it through the closed table, and the
## saved tile carries the line instead of a program and argv.
func test_launch_command_round_trips_through_the_pane_settings_ui():
	var body = _tm.create_body("terminal")
	_scene.add_child(body)
	var panel := FakePanePanel.new()
	_scene.add_child(panel)
	var ui: Control = body._build_pane_settings_ui(panel)
	_scene.add_child(ui)

	var field := _line_edit_named(ui, "LaunchCommand")
	assert_not_null(field, "Pane Settings must offer a launch command")
	assert_eq(field.text, "", "a fresh pane inherits its program")
	assert_eq(field.placeholder_text, "Your shell (%s)" % SettingsManager.cfg_shell_command,
		"an empty field names what it inherits")

	field.text = "omp update && exec omp"
	var gathered: Dictionary = panel._gather_func.call()
	assert_eq(gathered.get("launch"), "omp update && exec omp",
		"the field is what the panel hands the pane")
	body.apply_settings(gathered)

	assert_eq(body.launch, "omp update && exec omp")
	var state: Dictionary = body._get_layout_state()
	assert_eq(state.get("launch"), "omp update && exec omp")
	assert_false(state.has("shell"), "a launch line is the whole plan, not a program")
	assert_false(state.has("shell_args"), "the argv is derived from the line at spawn")
	var tile := PaneTypes.sanitize_tile({
		"settings": state, "col": 0, "row": 0,
		"cspan": PaneTypes.GRID, "rspan": PaneTypes.GRID,
	})
	assert_eq(tile.get("dropped", PackedStringArray()).size(), 0,
		"a saved launch tile must pass the file table")

func test_clearing_the_launch_command_goes_back_to_the_pane_program():
	var body = _tm.create_body("terminal")
	_scene.add_child(body)
	body.shell_command = "/bin/zsh"
	body.launch = "omp update && exec omp"
	var panel := FakePanePanel.new()
	_scene.add_child(panel)
	var ui: Control = body._build_pane_settings_ui(panel)
	_scene.add_child(ui)
	var field := _line_edit_named(ui, "LaunchCommand")
	assert_eq(field.text, "omp update && exec omp", "the field reads the current line")

	field.text = ""
	body.apply_settings(panel._gather_func.call())
	assert_eq(body.launch, "")
	var state: Dictionary = body._get_layout_state()
	assert_false(state.has("launch"))
	assert_eq(state.get("shell"), "/bin/zsh", "an empty field inherits the pane's program")
	assert_eq(state.get("shell_args"), [])

# ── spawn_pane applies global settings ─────────────────────────────────

func test_spawn_pane_applies_global_settings():
	SettingsManager.cfg_font_size = 18
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	var body = _tm.spawn_pane("terminal", {})
	assert_not_null(body)
	assert_eq(body.font_size, 18, "spawn_pane must apply global font size")
	assert_eq(body.shell_command, SettingsManager.default_shell_command(), "spawn_pane must apply global shell")
	for t in _tm.tiles:
		t.wrapper.free()
	_tm.tiles.clear()

func test_spawn_pane_opts_override_globals():
	SettingsManager.cfg_font_size = 18
	var body = _tm.spawn_pane("terminal", {"font_size": 22, "shell_command": "/bin/zsh"})
	assert_not_null(body)
	assert_eq(body.font_size, 22, "per-pane font_size must override global")
	assert_eq(body.shell_command, "/bin/zsh", "per-pane shell must override global")
	for t in _tm.tiles:
		t.wrapper.free()
	_tm.tiles.clear()

# ── Settings allowlist ─────────────────────────────────────────────────

func test_apply_settings_refuses_an_unlisted_property():
	# The hole this closes: `_set_typed` assigned any exported String/int/
	# float/bool property, so a layout could pick the next font to load().
	var body = _tm.create_body("terminal")
	_scene.add_child(body)
	body.apply_settings({
		"font_bold_path": "/tmp/evil.tres",
		"font_italic_path": "/tmp/evil.tres",
		"workspace_cwd": "/tmp",
	})
	assert_eq(body.font_bold_path, "res://fonts/DejaVuSansMono-Bold.ttf",
		"an unlisted property must never be assigned from settings")
	assert_eq(body.font_italic_path, "res://fonts/DejaVuSansMono-Oblique.ttf")
	assert_eq(body.workspace_cwd, "", "the manager owns the working directory")

func test_every_pane_type_accepts_the_settings_it_saves():
	# Drift guard for the closed table: a key added to `_get_layout_state`
	# without a rule would silently stop surviving a save/restore cycle.
	var applied_by_the_pane := ["graph", "open_note", "loop", "graph_positions"]
	for type_name in PaneTypes.ALL:
		var script = TerminalManager._PaneScripts.get(type_name)
		assert_not_null(script, "%s must have a pane script" % type_name)
		var body: Control = script.new()
		var saved: Dictionary = body._get_layout_state()
		var tile := PaneTypes.sanitize_tile({
			"settings": saved, "col": 0, "row": 0,
			"cspan": PaneTypes.GRID, "rspan": PaneTypes.GRID,
		})
		assert_eq(tile.get("dropped", PackedStringArray()).size(), 0,
			"%s must accept every key it saves (dropped %s)"
			% [type_name, str(tile.get("dropped", []))])
		assert_eq(tile.get("type_name"), type_name, "a saved tile keeps its type")
		for key in PaneTypes.settings_schema(type_name):
			if key == "type":
				continue
			assert_true(key in body or applied_by_the_pane.has(key),
				"%s: allowlisted key '%s' addresses no property" % [type_name, key])
		body.free()
