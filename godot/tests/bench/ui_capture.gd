extends SceneTree
## Deterministic UI capture driver for the UI/UX assessment (AGENTS.md).
##
## Stages one named UI state through the real autoloads and the real main
## scene, waits for the pixels to stop changing, and saves the app's own
## rendered viewport as a PNG. This is the committed staging path the audits
## used to rewrite per run: the same state on the same build must come out
## pixel-identical, and `scripts/ui-capture-check` is what proves it.
##
##   scripts/ui-capture <state> <out-dir>          # private sandbox + PNG
##   scripts/ui-capture --list                    # the state names
##   scripts/ui-capture-check                     # determinism + locality test
##
## Raw form (the scripts add the sandbox):
##
##   godot --path godot --disable-vsync -s res://tests/bench/ui_capture.gd -- \
##       --state palette --out /tmp/captures
##
## Flags:
##   --state <name>     the state to stage (required; see STATES)
##   --out <dir>        write <dir>/<state>.png
##   --hold             stage and stay open instead of capturing, so
##                      `scripts/screenshot-gpty --state` can grab the window
##   --ready <path>     write this file once the state is staged and settled
##                      (the desktop grab waits on it; stdout may be buffered)
##   --perturb <name>   shift that one state's topmost overlay (or its first
##                      pane) by 16 px; `scripts/ui-capture-check` uses it to
##                      prove a capture diff is local to one state
##   --list             print the state names, one per line, and exit
##   --compare a b      compare two PNGs pixel for pixel and exit 0/1
##
## A real display driver is required: under `--headless` there is no redraw
## pass, `frame_post_draw` never fires, and a script awaiting it hangs.
## `--disable-vsync` keeps a vsync-locked present from blocking on a window
## the compositor never shows.
##
## Determinism, all of it needed:
##   - `GPTY_TEST_USER_DIR` must name an absolute directory (fresh per run):
##     the driver writes through `WorkspaceStore`, and the app binds its
##     control socket at launch. `scripts/ui-capture` owns the whole sandbox
##     (user dir, XDG dirs, HOME, socket); refuse to run without one rather
##     than seed a developer's real profile.
##   - Cursor blink off, so the caret is not mid-blink.
##   - The status bar's clock and FPS pinned (`StatusBar.freeze_readouts`);
##     they are the only readouts that move while nothing does.
##   - The capture waits for every terminal grid generation, every pane title
##     and the toast queue to stop changing, then parks the pointer so no
##     hover highlight depends on the desktop's mouse position.
##   - Window size comes from the state table, not the WM: the root viewport
##     is resized and the capture is of that render target, so a desktop that
##     clamps windows cannot change the image.

const DEFAULT_SIZE := Vector2i(1920, 1080)
## Pane count before the state's interaction runs. 0 leaves the workspace
## store empty, so the app's own first-launch path creates the first terminal.
const STATES := {
	"first-launch": {"size": DEFAULT_SIZE, "panes": 0},
	"sidebar": {"size": DEFAULT_SIZE, "panes": 4},
	"settings": {"size": DEFAULT_SIZE, "panes": 1, "open": "settings"},
	"pane-settings": {"size": DEFAULT_SIZE, "panes": 1, "open": "pane-settings"},
	"palette": {"size": DEFAULT_SIZE, "panes": 1, "open": "palette"},
	"empty-workspace": {"size": DEFAULT_SIZE, "panes": 1, "close_all": true},
	"workspace-1280x760": {"size": Vector2i(1280, 760), "panes": 4},
	"window-800x500": {"size": Vector2i(800, 500), "panes": 4},
	"window-560x340": {"size": Vector2i(560, 340), "panes": 4},
}
## How long a signature must stay unchanged before the state counts as settled.
const SETTLE_MS := 250
## Upper bound on waiting for a state to settle, so a stuck pane fails the run
## instead of hanging it.
const SETTLE_TIMEOUT_MS := 20000
## Upper bound on draining the toast queue (the longest toast lasts 8 s).
const TOAST_TIMEOUT_MS := 15000

var _workspace: Control = null
## Autoloads are not compile-time identifiers for a `-s` script (measured:
## `Identifier not found: SettingsManager`), so they are resolved as nodes.
var _settings: Node = null
var _store: Node = null


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	if args.has("error"):
		_fail(str(args["error"]))
		return
	if args.get("list", false):
		for state_name in STATES:
			print(state_name)
		quit(0)
		return
	if args.has("compare"):
		var pair: Array = args["compare"]
		quit(_compare(str(pair[0]), str(pair[1])))
		return

	var state_name := str(args.get("state", ""))
	if not STATES.has(state_name):
		_fail("--state %s is not a known state; --list prints them" % state_name)
		return
	var sandbox := OS.get_environment("GPTY_TEST_USER_DIR")
	if not BasePersistenceManager.is_real_absolute_path(sandbox):
		_fail(
			"GPTY_TEST_USER_DIR must name an absolute directory (got %s). "
			% sandbox
			+ "Run scripts/ui-capture, which owns the private sandbox; staging "
			+ "writes through WorkspaceStore and the app binds its control socket.")
		return
	if not args.has("out") and not args.get("hold", false):
		_fail("--out <dir> is required unless --hold is given")
		return

	await _run(state_name, STATES[state_name], args)


func _run(state_name: String, state: Dictionary, args: Dictionary) -> void:
	var size: Vector2i = state["size"]
	# In-memory settings only: the sandbox already keeps the stores private,
	# and a capture may not rewrite the settings file it is capturing.
	_settings = root.get_node("SettingsManager")
	_store = root.get_node("WorkspaceStore")
	_settings.cfg_cursor_blink = false
	_settings.cfg_show_titlebar = true
	_settings.cfg_window_size = size
	_settings.cfg_check_updates = false
	_seed_workspace(int(state.get("panes", 0)))

	_workspace = load("res://scenes/main.tscn").instantiate()
	root.add_child(_workspace)
	await _settle_window(size)
	# A seeded layout restores its panes unfocused; pin the active pane so the
	# status bar and the sidebar accent cannot depend on restore order. The
	# first-launch state keeps the app's own focus — that behaviour is audited.
	if int(state.get("panes", 0)) > 0:
		var bodies: Array = _workspace._pane_bodies(_workspace._active_workspace())
		if not bodies.is_empty():
			_workspace.activate_pane(bodies[0])
	await _settle()
	if not await _apply_state(state_name, state):
		return

	if args.get("perturb", "") == state_name:
		_perturb()

	await _wait_toasts()
	await _settle()
	_workspace._status_bar.freeze_readouts()
	# Freeze last, then settle again: the pinned readout must not be the last
	# thing to change the pixels.
	await _settle()
	_park_pointer()

	if args.get("hold", false):
		_write_ready(str(args.get("ready", "")), state_name, size)
		print("ui_capture: ready state=%s size=%dx%d" % [state_name, size.x, size.y])
		while true:
			await process_frame
		return

	await _capture(state_name, str(args.get("out", "")))
	quit(0)


# ── Seeding ────────────────────────────────────────────────────────────

## Write the state's panes through the real store, exactly as a restore would
## find them. Tile settings go through `PaneTypes.sanitize_tile` at restore,
## so a state definition that drifts from the schema fails visibly instead of
## silently spawning something else.
func _seed_workspace(panes: int) -> void:
	if panes <= 0:
		return
	var grid := PaneTypes.GRID
	var tiles: Array[Dictionary] = []
	if panes == 1:
		tiles.append(_tile(1, 0, 0, grid, grid))
	else:
		var half := grid / 2
		var index := 1
		for row in 2:
			for col in 2:
				tiles.append(_tile(index, col * half, row * half, half, half))
				index += 1
	# A saved layout carries its panes' public ids; naming them here keeps the
	# Pane Settings capture free of a random `pane-…` handle.
	var workspaces: Array[Dictionary] = [
		{"name": "Workspace 1", "cwd": "", "layout": tiles},
	]
	_store.save(0, workspaces)

func _tile(index: int, col: int, row: int, cspan: int, rspan: int) -> Dictionary:
	return {
		"col": col, "row": row, "cspan": cspan, "rspan": rspan,
		"settings": {"type": "terminal", "attachment_id": "capture-%d" % index},
	}

## `_chrome.restore_position()` runs deferred at launch and re-applies the
## saved window size through `DisplayServer`, which does not resize the root
## render target on every display server. The root viewport is the authority:
## set it, then wait until it reads back.
func _settle_window(size: Vector2i) -> void:
	for _i in 120:
		if Vector2i(root.size) == size:
			return
		await process_frame
	root.size = size
	for _i in 120:
		if Vector2i(root.size) == size:
			await process_frame
			return
		await process_frame
	_fail("window did not reach %dx%d (root viewport is %s)" % [size.x, size.y, root.size])


# ── The state's interaction ────────────────────────────────────────────

func _apply_state(state_name: String, state: Dictionary) -> bool:
	match str(state.get("open", "")):
		"settings":
			await _click(_button_with_label(_workspace._sidebar, "Settings"))
			await _wait_frames(3)
			if _workspace._settings_panel == null or not _workspace._settings_panel.visible:
				_fail("clicking Settings did not open the Settings panel")
				return false
		"pane-settings":
			var wrapper: Control = _workspace._tm.tiles[0].wrapper
			var button := _button_with_tooltip(wrapper, "Pane settings")
			if button == null:
				_fail("the first pane has no Pane settings button")
				return false
			await _click(button)
			await _wait_frames(3)
			var panel: Control = _workspace._tm._pane_settings_panel
			if panel == null or not panel.visible:
				_fail("clicking Pane settings did not open the panel")
				return false
		"palette":
			await _press_key(KEY_P, true, true)
			await _wait_frames(3)
			if _workspace._palette == null or not _workspace._palette.visible:
				_fail("Ctrl+Shift+P did not open the command palette")
				return false
	if state.get("close_all", false):
		await _click(_button_with_label(_workspace._sidebar, "Close All"))
		await _wait_frames(2)
		# A live shell counts as running work, so Close All asks first. The
		# modal is its own OS window; press its OK button's signal, which is
		# what a click on it emits.
		var dialog := _workspace.get_node_or_null("RunningWorkConfirm")
		if dialog != null:
			dialog.get_ok_button().pressed.emit()
		await _wait_frames(4)
		if not _workspace._tm.tiles.is_empty():
			_fail("Close All left %d panes" % _workspace._tm.tiles.size())
			return false
	return true

## Shift the one control that only this state shows, so a diff is attributable.
func _perturb() -> void:
	var target: Control = null
	if _workspace._settings_panel != null and _workspace._settings_panel.visible:
		target = _workspace._settings_panel
	elif _workspace._tm._pane_settings_panel != null and _workspace._tm._pane_settings_panel.visible:
		target = _workspace._tm._pane_settings_panel
	elif _workspace._palette != null and _workspace._palette.visible:
		target = _workspace._palette
	elif not _workspace._tm.tiles.is_empty():
		target = _workspace._tm.tiles[0].wrapper
	if target != null:
		target.offset_left += 16.0
		print("ui_capture: perturbed %s by 16 px" % target.name)


# ── Input ──────────────────────────────────────────────────────────────

func _click(control: Control) -> void:
	if control == null or not is_instance_valid(control):
		_fail("cannot click an invalid control")
		return
	var pos := control.get_global_rect().get_center()
	await _send_motion(pos)
	await _send_button(pos, true)
	await process_frame
	await _send_button(pos, false)
	await process_frame

func _send_motion(pos: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	Input.parse_input_event(motion)
	await process_frame

func _send_button(pos: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = pos
	event.global_position = pos
	Input.parse_input_event(event)
	await process_frame

func _press_key(keycode: Key, ctrl := false, shift := false) -> void:
	var down := InputEventKey.new()
	down.keycode = keycode
	down.physical_keycode = keycode
	down.ctrl_pressed = ctrl
	down.shift_pressed = shift
	down.pressed = true
	Input.parse_input_event(down)
	await process_frame
	var up: InputEventKey = down.duplicate()
	up.pressed = false
	Input.parse_input_event(up)
	await process_frame

## Leave the pointer somewhere inert: a hover highlight must not depend on
## where the desktop happened to leave the mouse before the run.
func _park_pointer() -> void:
	await _send_motion(Vector2(root.size) - Vector2(4, 4))
	await _wait_frames(2)

func _button_with_label(node: Node, text: String) -> Button:
	if node is Button and _has_label(node, text):
		return node as Button
	for child in node.get_children():
		var found := _button_with_label(child, text)
		if found != null:
			return found
	return null

func _has_label(node: Node, text: String) -> bool:
	if node is Label and (node as Label).text == text:
		return true
	for child in node.get_children():
		if _has_label(child, text):
			return true
	return false

func _button_with_tooltip(node: Node, tip: String) -> Button:
	if node is Button and (node as Button).tooltip_text == tip:
		return node as Button
	for child in node.get_children():
		var found := _button_with_tooltip(child, tip)
		if found != null:
			return found
	return null

func _wait_frames(count: int) -> void:
	for _i in count:
		await process_frame


# ── Settling ───────────────────────────────────────────────────────────

## Everything that can still change without user input: terminal grid
## generations, pane titles (the shell's OSC title lands after the prompt) and
## the status bar's left label.
func _settle() -> void:
	var last := "?"
	var changed_at := Time.get_ticks_msec()
	var deadline := changed_at + SETTLE_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var signature := _ui_signature()
		if signature != last:
			last = signature
			changed_at = Time.get_ticks_msec()
		elif Time.get_ticks_msec() - changed_at >= SETTLE_MS:
			return
	_fail("the UI did not settle within %d ms (last signature %s)" % [SETTLE_TIMEOUT_MS, last])

func _ui_signature() -> String:
	var parts := PackedStringArray()
	for tile in _workspace._tm.tiles:
		var body = _workspace._tm._find_body(tile.wrapper)
		var generation := -1
		if _is_terminal(body) and body._terminal != null:
			generation = body._terminal.get_grid_generation()
		var title := ""
		var label = tile.wrapper.get_node_or_null("BodyVBox/TitleBar/TitleLabel")
		if label is Label:
			title = (label as Label).text
		parts.append("%d/%s" % [generation, title])
	return "|".join(parts)

## The toast queue drains on its own timers; a spawn or restore notice left
## on screen would otherwise land in whichever capture raced it.
func _wait_toasts() -> void:
	var overlay: Node = _find_script(_workspace, "res://scenes/ui/toast_overlay.gd")
	if overlay == null:
		return
	var deadline := Time.get_ticks_msec() + TOAST_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if overlay.get_child_count() == 0 and not overlay._active:
			await process_frame
			return
	_fail("toasts did not clear within %d ms" % TOAST_TIMEOUT_MS)

## Find a node by its script path. `is <Class>` would compile the script (and
## its autoload identifiers) into this one; see `_is_terminal`.
func _find_script(node: Node, path: String) -> Node:
	var script = node.get_script()
	if script != null and script.resource_path == path:
		return node
	for child in node.get_children():
		var found := _find_script(child, path)
		if found != null:
			return found
	return null

## A terminal body without naming the class: `is TerminalPane` would pull
## `terminal_pane.gd` into this script's compile, and that script reads the
## `PaneEnvStore` autoload by name — which is not an identifier yet when a
## `-s` script is first compiled (measured: `Identifier not found`).
func _is_terminal(body) -> bool:
	return body != null and is_instance_valid(body) and "_terminal" in body


# ── Capture ────────────────────────────────────────────────────────────

func _capture(state_name: String, out_dir: String) -> void:
	var focused: Control = _workspace._tm.last_body
	if _is_terminal(focused):
		focused._cursor_visible = true
		focused.queue_redraw()
	await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = root.get_texture().get_image()
	if image == null:
		_fail("the root viewport produced no image (a display driver is required)")
		return
	if not out_dir.is_absolute_path():
		_fail("--out must be an absolute directory (got %s)" % out_dir)
		return
	var err := DirAccess.make_dir_recursive_absolute(out_dir)
	if err != OK and err != ERR_ALREADY_EXISTS:
		_fail("cannot create %s (error %d)" % [out_dir, err])
		return
	var path := out_dir.path_join("%s.png" % state_name)
	err = image.save_png(path)
	if err != OK:
		_fail("cannot write %s (error %d)" % [path, err])
		return
	print("ui_capture: wrote %s (%dx%d)" % [path, image.get_width(), image.get_height()])

func _write_ready(path: String, state_name: String, size: Vector2i) -> void:
	if path == "":
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("cannot write ready file %s" % path)
		return
	file.store_line("state=%s size=%dx%d" % [state_name, size.x, size.y])
	file.close()


# ── PNG comparison (scripts/ui-capture-check) ──────────────────────────

func _compare(a: String, b: String) -> int:
	var left: Image = Image.load_from_file(a)
	var right: Image = Image.load_from_file(b)
	if left == null or right == null:
		printerr("ui_capture: cannot load %s" % (a if left == null else b))
		return 2
	if left.get_size() != right.get_size():
		print("ui_capture: differ sizes %s=%s %s=%s" % [a, left.get_size(), b, right.get_size()])
		return 1
	var ldata := left.get_data()
	var rdata := right.get_data()
	if ldata == rdata:
		print("ui_capture: identical %s %s" % [a, b])
		return 0
	var width := left.get_width()
	var channels := maxi(ldata.size() / maxi(width * left.get_height(), 1), 1)
	var pixels := 0
	var first := Vector2i(-1, -1)
	var last := Vector2i.ZERO
	for i in ldata.size():
		if ldata[i] == rdata[i]:
			continue
		var pixel := i / channels
		var point := Vector2i(pixel % width, pixel / width)
		if pixels == 0:
			first = point
		last = point
		pixels += 1
	print("ui_capture: differ %s %s pixels=%d first=%s last=%s"
		% [a, b, pixels, first, last])
	return 1


# ── Usage ──────────────────────────────────────────────────────────────

func _parse_args(raw: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < raw.size():
		match raw[i]:
			"--state":
				i += 1
				if i >= raw.size():
					return {"error": "--state needs a value"}
				out["state"] = raw[i]
			"--out":
				i += 1
				if i >= raw.size():
					return {"error": "--out needs a value"}
				out["out"] = raw[i]
			"--ready":
				i += 1
				if i >= raw.size():
					return {"error": "--ready needs a value"}
				out["ready"] = raw[i]
			"--perturb":
				i += 1
				if i >= raw.size():
					return {"error": "--perturb needs a state name"}
				out["perturb"] = raw[i]
			"--hold":
				out["hold"] = true
			"--list":
				out["list"] = true
			"--compare":
				if i + 2 >= raw.size():
					return {"error": "--compare needs two image paths"}
				out["compare"] = [raw[i + 1], raw[i + 2]]
				i += 2
			_:
				return {"error": "unknown argument %s" % raw[i]}
		i += 1
	return out

func _fail(message: String) -> void:
	printerr("ui_capture: " + message)
	quit(2)
