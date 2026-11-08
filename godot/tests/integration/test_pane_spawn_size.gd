extends GutTest
# A fresh pane's child is born at the size the pane is drawn at.
#
# The pane used to spawn its PTY in `_ready`, before any container had sized it,
# so the child started at the configured 24x80 and only learned the real size
# from the resize debounce 50 ms later. A TUI that snapshots its size at startup
# (OMP) kept the 80x24 layout until something resized the pane. The obligation is
# now: the first size the child can read is the settled size, and a pane the grid
# has never positioned has no child at all.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

## The child's own report, through a real PTY: `stty size` is the only source
## that proves the *PTY* holds the size, not just the pane's fields.
const CHILD_REPORT_MS := 30000

var _scene: Control
var _tm: TerminalManager
var _ws: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	# Deliberately not 24x80: the pre-fix pane spawned at the configured grid,
	# so a fitted size can never pass by coinciding with the default.
	SettingsManager.cfg_default_rows = 10
	SettingsManager.cfg_default_cols = 40
	SettingsManager.cfg_font_size = 14
	_scene = TestScene.create()
	add_child(_scene)
	_tm = TerminalManager.new()

func after_each():
	if _ws:
		if _ws.get_parent():
			remove_child(_ws)
		_ws.free()
		_ws = null
	_tm.reset()
	_tm = null
	MockAutoloads.teardown()
	if _scene:
		remove_child(_scene)
		_scene.free()
		_scene = null

## A real workspace with a real size, so `_apply_layout` positions its tiles
## (`test_bracketed_paste.gd` and `test_ipc_dispatch_contract.gd` use the same
## fixture): the birth size is a layout fact, so the layout has to be real.
func _workspace() -> Control:
	_ws = WorkspaceScript.new()
	add_child(_ws)
	_ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	return _ws

## The grid the pane's own pixels can show, by the same formula the pane uses
## (`TerminalPane._grid_for_size`). Never a literal: the cell size depends on
## the font this machine has.
func _fitted_grid(body: Control) -> Vector2i:
	var cols := int((body.size.x - TerminalPane.PADDING) / body._cell_w)
	var rows := int((body.size.y - TerminalPane.PADDING) / body._cell_h)
	return Vector2i(cols, rows)

## The first screen line matching `pattern`, or "" at the deadline. Polls the
## pane's drained grid (the child writes through the PTY thread, so the text
## arrives on a later frame than the spawn).
func _wait_for_line(body: Control, pattern: String, timeout_ms: int) -> String:
	var re := RegEx.new()
	re.compile(pattern)
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		for line in str(body._terminal.get_plain_text(4000)).split("\n"):
			if re.search(line) != null:
				return line
		await get_tree().create_timer(0.05).timeout
	return ""

# ── The contract ───────────────────────────────────────────────────────

func test_a_fresh_pane_births_its_child_at_the_fitted_size():
	if ShellFixtures.is_windows():
		pending("`stty` has no Windows equivalent; the spawn path is shared")
		return
	var ws := await _workspace()
	var body: Control = ws._spawn_pane("terminal", {"shell_args": ["-c", "stty size"]})
	assert_not_null(body, "the pane must spawn")
	await get_tree().process_frame

	var fitted := _fitted_grid(body)
	assert_eq([body.rows, body.cols], [fitted.y, fitted.x],
		"the pane must start at the size it is drawn at, not the configured grid")
	var line := await _wait_for_line(body, "^\\d+ \\d+$", CHILD_REPORT_MS)
	assert_eq(line, "%d %d" % [fitted.y, fitted.x],
		"the child's own first `stty size` must be the settled grid (got '%s')" % line)

func test_input_before_the_first_layout_is_not_lost():
	var ws := await _workspace()
	var body: Control = ws._spawn_pane("terminal", {})
	assert_not_null(body, "the pane must spawn")
	# The same frame the pane was created: the child does not exist yet, so this
	# has to be held, not written into a terminal with no session.
	var reply = WorkspaceIpcHandlers.handle(ws, "inject",
		{"pane_id": body.attachment_id, "text": "echo PENDING_INPUT_MARKER"})
	assert_true(reply is Dictionary, "inject must answer")
	assert_false(reply.has("error"),
		"injecting before the child exists must be accepted: %s" % str(reply))
	var line := await _wait_for_line(body, "PENDING_INPUT_MARKER", CHILD_REPORT_MS)
	assert_ne(line, "", "the line buffered before the spawn must reach the child")

func test_a_pane_that_was_never_laid_out_has_no_child():
	var body: Control = _tm.create_body("terminal")
	_scene.add_child(body)
	await get_tree().process_frame
	assert_false(body._started,
		"a pane the grid has never positioned must not spawn a child")
	assert_eq(body._terminal.get_rows(), 0,
		"a terminal with no session has no grid size")

func test_a_sized_pane_starts_at_its_own_size():
	var body: Control = _tm.create_body("terminal")
	_scene.add_child(body)
	body.size = Vector2(900, 600)
	var fitted := _fitted_grid(body)
	assert_true(body._started,
		"a pane that is given a size starts without waiting for the grid")
	assert_eq([body.rows, body.cols], [fitted.y, fitted.x],
		"the child must start at the size the pane was given")
