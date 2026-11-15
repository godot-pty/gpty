extends GutTest
# CLI View pane: a real child process whose stdout reaches the pane body,
# plus the settings sanitization the pane owes its inputs.
#
# The child is a real program with real argv — never a shell command line the
# pane might evaluate, because it does not: `ShellFixtures.print_text_argv`
# names the program (the shell running `printf` on POSIX, PowerShell itself on
# Windows) and the pane spawns exactly that.

## A launch plus a poll cycle, sized for a real process rather than a frame
## count. Generous because the child is an interpreter starting cold on a CI
## runner — a cold `powershell.exe` measured past 10 s in this repo already
## (`test_bracketed_paste.gd`) — and because the pane only observes an exit
## after the extension has reaped the child. Waits return as soon as the
## condition holds, so the budget only costs time when something is wrong.
const PROCESS_BUDGET_MS := 20000

var _scene: Control
## Directories a test created for a working-directory assertion.
var _dirs: Array[String] = []

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	_scene = TestScene.create()
	add_child(_scene)

func after_each():
	if _scene:
		remove_child(_scene)
		_scene.free()
	for dir in _dirs:
		DirAccess.remove_absolute(dir)
	_dirs.clear()
	MockAutoloads.teardown()

## The pane is a thin view over the `GptyCliView` extension class. With the
## class missing the pane logs an error and does nothing, so every assertion
## below would be about a pane that never ran. The extension is a build
## requirement — CI builds it on every platform before this suite — so its
## absence is a failure to report, never a skip (the Inspector suite's rule for
## the same situation).
func _ffi_ready() -> bool:
	var present := ClassDB.class_exists("GptyCliView")
	assert_true(present,
		"GptyCliView must be registered: build and install the gpty-gdext extension")
	return present

## A real pane with its spawn plan already set, entering the tree starting it.
func _make_pane(command: String, args: Array) -> CliViewPane:
	var pane := CliViewPane.new()
	pane.command = command
	pane.shell_args = args
	_scene.add_child(pane)
	return pane

## The plan that prints `text` and exits, as the argv the pane spawns.
func _print_plan(text: String, hold_seconds := 0) -> Array:
	return ShellFixtures.print_text_argv(
		SettingsManager.default_shell_command(), text, hold_seconds)

func _wait_until(predicate: Callable, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await get_tree().create_timer(0.05).timeout
	return false

## The child's own state as the extension reports it — not the pane's copy,
## so a "stopped" claim is checked against the process, not the label.
func _ffi_running(pane: CliViewPane) -> bool:
	var status = JSON.parse_string(str(pane._cli.status_json()))
	return status is Dictionary and bool(status.get("running", false))

## A real program that prints its own working directory, as argv.
func _pwd_plan() -> Array:
	if ShellFixtures.is_windows():
		var comspec := OS.get_environment("COMSPEC")
		return [comspec if comspec != "" else "cmd.exe", ["/c", "cd"]]
	return ["/bin/pwd", []]

## An existing absolute directory in the throwaway user-data dir.
func _temp_dir(slug: String) -> String:
	var dir := OS.get_user_data_dir().path_join(
		"gpty-test-cli-cwd-%s-%d" % [slug, Time.get_ticks_usec()])
	DirAccess.make_dir_absolute(dir)
	_dirs.append(dir)
	return dir

## One separator spelling for both sides of a path comparison.
##
## Godot's own paths use `/` even on Windows (`path_join`, `OS.get_user_data_dir`)
## while a child process prints its cwd the way the OS does (`\` from `cmd`), so
## a raw `contains` compares two spellings of the same directory and answers
## false on Windows only. `/` also keeps the assertion text readable.
func _slashed(path: String) -> String:
	return path.replace("\\", "/")

# ── Streaming ──────────────────────────────────────────────────────────

func test_child_stdout_reaches_the_pane_and_the_process_ends():
	if not _ffi_ready():
		return
	var plan := _print_plan("cli_view_marker\n")
	var pane := _make_pane(plan[0], plan[1])
	var ok := await _wait_until(
		func(): return pane.get_text().contains("cli_view_marker") and not pane.is_running(),
		PROCESS_BUDGET_MS)
	assert_true(ok, "the child's output must reach the pane and the process must end: %s"
		% JSON.stringify(pane.get_text()))
	# The ring is what `get_text()`/`pane-read` serve; the CodeEdit is what the
	# user sees. Both must carry the line, or a pane could pass its read API
	# while showing nothing.
	assert_true(
		pane._editor.text.contains("cli_view_marker"),
		"the visible view must show the child's line: %s" % JSON.stringify(pane._editor.text))

## The child starts where its pane resolved: the workspace's directory, then
## the pane's own override on Restart. Before this, a `cli_view` child ran in
## the GUI process's directory and `git status` in a view reported the app's
## own repository.
func test_the_child_starts_in_the_panes_directory():
	if not _ffi_ready():
		return
	var plan := _pwd_plan()
	var pane := _make_pane("", [])
	var workspace := _temp_dir("workspace")
	pane.workspace_cwd = workspace
	pane.command = plan[0]
	pane.shell_args = plan[1]
	pane._start()
	var ok := await _wait_until(
		func(): return _slashed(pane.get_text()).contains(_slashed(workspace)),
		PROCESS_BUDGET_MS)
	assert_true(ok, "the child must start in its workspace directory %s: %s (%s)"
		% [_slashed(workspace), JSON.stringify(_slashed(pane.get_text())),
		pane.start_error()])

	# The pane's own directory is the first layer, and Restart re-resolves it.
	var own := _temp_dir("own")
	pane.pane_cwd = own
	pane._start()
	ok = await _wait_until(
		func(): return _slashed(pane.get_text()).contains(_slashed(own)),
		PROCESS_BUDGET_MS)
	assert_true(ok, "the pane's own directory %s must replace the workspace's at Restart: %s (%s)"
		% [_slashed(own), JSON.stringify(_slashed(pane.get_text())),
		pane.start_error()])

func test_stop_kills_a_running_child():
	if not _ffi_ready():
		return
	var plan := _print_plan("held\n", 30)
	var pane := _make_pane(plan[0], plan[1])
	var up := await _wait_until(
		func(): return pane.is_running() and pane.get_text().contains("held"),
		PROCESS_BUDGET_MS)
	assert_true(up, "a holding child must be running and must have printed: %s"
		% JSON.stringify(pane.get_text()))
	pane._on_stop_pressed()
	assert_true(
		await _wait_until(func(): return not _ffi_running(pane), PROCESS_BUDGET_MS),
		"Stop must kill the child process")
	assert_false(pane.is_running(), "a stopped pane is not running")

# ── Configuration ──────────────────────────────────────────────────────

func test_a_pane_with_no_command_stays_idle():
	if not _ffi_ready():
		return
	var pane := _make_pane("", [])
	await get_tree().process_frame
	assert_false(pane.is_running(), "an unconfigured pane must not run anything")
	assert_eq(pane.get_text(), "", "an unconfigured pane has no output")

## The pane is a header row plus a filling view, all stock Godot Containers —
## the class of layout that has silently collapsed before in this repo (a
## textless Button, an overlay with one anchor). A Control with no size lays
## nothing out, so the pane gets an explicit one and the widgets must fill it.
func test_the_view_fills_the_pane():
	if not _ffi_ready():
		return
	var pane := _make_pane("", [])
	pane.size = Vector2(640, 480)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_gt(pane._editor.size.x, 0.0, "the output view must fill the pane's width")
	assert_gt(pane._editor.size.y, 0.0, "the output view must fill the pane's height")
	assert_true(pane._status.visible, "the status row must be visible")
	assert_true(pane._restart_btn.visible, "the Restart button must be visible")
	assert_true(pane._stop_btn.visible, "the Stop button must be visible")

func test_apply_settings_sanitizes_the_spawn_plan():
	if not _ffi_ready():
		return
	var pane := _make_pane("", [])
	# Junk types come from layout/profile JSON; a non-string program must fall
	# back to the previous plan rather than spawning something else.
	pane.apply_settings({"command": 123, "shell_args": ["ok", 5, ""]})
	assert_eq(pane.command, "", "a non-string command must fall back to the previous value")
	assert_eq(pane.shell_args, ["ok"], "junk arguments must be dropped and the rest kept")

	pane.apply_settings({"command": "/bin/echo", "shell_args": ["-n", "hi"]})
	assert_eq(pane.command, "/bin/echo")
	assert_eq(pane.shell_args, ["-n", "hi"])

	# The fallback must be the pre-call value: `super.apply_settings` assigns a
	# String `command` unchecked, so a sanitiser reading the current value
	# would hand back the oversized value it is supposed to reject.
	pane.apply_settings({"command": "x".repeat(2048)})
	assert_eq(pane.command, "/bin/echo", "an oversized command must not persist")

func test_layout_state_persists_the_spawn_plan():
	if not _ffi_ready():
		return
	var pane := _make_pane("", [])
	pane.apply_settings({"command": "/bin/echo", "shell_args": ["-n", "hi"], "pane_name": "Probe"})
	var state = pane._get_layout_state()
	assert_eq(state.get("type"), "cli_view")
	assert_eq(state.get("command"), "/bin/echo")
	assert_eq(state.get("shell_args"), ["-n", "hi"])

# ── Role ───────────────────────────────────────────────────────────────

func test_cli_view_is_a_display_sink_not_a_concept_receiver():
	if not _ffi_ready():
		return
	var pane := _make_pane("", [])
	assert_eq(pane._pane_type(), "cli_view")
	assert_false(pane.can_receive_content(), "CLI View is a display sink, not a receiver")
	assert_false(pane.receive_content("routed capture"), "nothing may be routed into the view")
