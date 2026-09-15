extends PaneBody
class_name CliViewPane
## Runs a configured command and streams its stdout+stderr into a read-only
## text view — "plugin UI v1": a third-party CLI gets a pane without being
## handed any Godot SDK surface.
##
## The pane runs argv, never a shell: `command` is the program and
## `shell_args` is its argument vector — the same two keys the Workspace
## Trust gate already reads, so a tile that names something to run goes
## through the existing consent path unchanged. The child itself belongs to
## the `GptyCliView` extension class; this script is only the view, and it
## stops the process in `_exit_tree` so closing a pane cannot leave one
## running.

## Program to run. Empty means "not configured": the pane stays idle.
@export var command: String = ""
## Program arguments (argv). Never shell-evaluated.
@export var shell_args: Array = []

## Lines kept in memory and drawn. The Rust side bounds its own queue; this
## bounds what the GUI holds and re-renders.
const MAX_LINES := 4000

var _cli: Node = null
var _status: Label
var _editor: CodeEdit
var _restart_btn: Button
var _stop_btn: Button
## Complete lines, oldest first — the source of truth for `get_text()`.
var _lines := PackedStringArray()
var _running := false

func _ready():
	super._ready()
	_build_ui()

	_cli = ClassDB.instantiate("GptyCliView")
	if _cli == null:
		_status.text = "GptyCliView unavailable (rebuild gdext)"
		push_error("GptyCliView is not registered; rebuild gpty-gdext and restart Godot")
	else:
		_cli.name = "GptyCliView"
		add_child(_cli)

	if command != "":
		_start()
	elif _cli != null:
		_status.text = "No command configured — set Program in pane settings, then Restart"
	_sync_buttons()

func _exit_tree():
	# Closing the pane is the only thing that kills the child: the contract
	# says the process dies with the pane, so it is stopped here rather than
	# left for the extension's own Drop, which has no idea the pane is gone.
	if _cli != null:
		_cli.stop()

## Last `max_lines` complete lines, oldest first. This — not the status
## label — is the read API for `paneRead` and for tests: the label is
## UI wording, the ring is the child's output.
func get_text(max_lines := 200) -> String:
	var start := maxi(0, _lines.size() - max_lines)
	return "\n".join(_lines.slice(start))

func is_running() -> bool:
	return _running

func _process(_delta):
	if _cli == null:
		return
	var lines: PackedStringArray = _cli.poll_lines()
	if lines.size() > 0:
		_append_lines(lines)
	var status = JSON.parse_string(str(_cli.status_json()))
	if not (status is Dictionary):
		return
	var running := bool(status.get("running", false))
	# The label is written on transitions only: polling returns the same
	# status every frame while the child lives, and rewriting the label there
	# would also undo a "command changed" notice the settings path just set.
	if running == _running:
		return
	_running = running
	if running:
		_status.text = "Running (pid %s)" % str(status.get("pid", "?"))
	else:
		_report_exit(status)
	_sync_buttons()

func _start():
	if _cli == null or command == "":
		return
	# `start` replaces a live child by itself (the extension stops the old
	# process first), so Restart needs no separate stop. Output is kept: this
	# is a log view, and a restart continues it rather than erasing what the
	# previous run printed.
	var raw := str(_cli.start(JSON.stringify({"command": command, "args": shell_args})))
	var resp = JSON.parse_string(raw)
	if resp is Dictionary and bool(resp.get("ok", false)):
		_running = true
		_status.text = "Running (pid %s)" % str(resp.get("pid", "?"))
	else:
		_running = false
		var err := "failed to start"
		if resp is Dictionary:
			err = str(resp.get("error", err))
		_status.text = err
	_sync_buttons()

func _report_exit(status: Dictionary):
	if str(status.get("exit_reason", "")) == "killed":
		_status.text = "Stopped"
		return
	var code = status.get("exit_code")
	_status.text = "Exited" if code == null else "Exited (%s)" % str(code)

func _on_restart_pressed():
	_start()

func _on_stop_pressed():
	if _cli == null:
		return
	_cli.stop()
	# Reported here rather than waiting for the poll: the next status can
	# only confirm what the user just asked for, and one frame of "Running"
	# after Stop reads as a failed click.
	_running = false
	_status.text = "Stopped"
	_sync_buttons()

func _sync_buttons():
	var configured := _cli != null and command != ""
	_restart_btn.disabled = not configured
	_stop_btn.disabled = not _running

func _build_ui():
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root)

	var header := HBoxContainer.new()
	header.name = "Header"
	header.add_theme_constant_override("separation", 6)
	root.add_child(header)

	_status = Label.new()
	_status.name = "Status"
	_status.text = "Idle"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.add_theme_font_size_override("font_size", 12)
	header.add_child(_status)

	_restart_btn = Button.new()
	_restart_btn.name = "RestartButton"
	_restart_btn.text = "Restart"
	_restart_btn.focus_mode = Control.FOCUS_NONE
	_restart_btn.pressed.connect(_on_restart_pressed)
	header.add_child(_restart_btn)

	_stop_btn = Button.new()
	_stop_btn.name = "StopButton"
	_stop_btn.text = "Stop"
	_stop_btn.focus_mode = Control.FOCUS_NONE
	_stop_btn.pressed.connect(_on_stop_pressed)
	header.add_child(_stop_btn)

	_editor = CodeEdit.new()
	_editor.name = "CodeEdit"
	_editor.editable = false
	_editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_editor.add_theme_font_size_override("font_size", font_size)
	root.add_child(_editor)

## Append a batch of complete lines to the ring and the view.
##
## The view is appended to, not re-assigned: re-setting `.text` re-parses the
## whole document on every batch, which is the cost this pane exists to avoid
## while a child streams. Only the ring trimming rebuilds it.
func _append_lines(lines: PackedStringArray):
	var at_bottom := _is_scrolled_to_bottom()
	_lines.append_array(lines)
	if _lines.size() > MAX_LINES:
		_lines = _lines.slice(_lines.size() - MAX_LINES)
		_editor.text = "\n".join(_lines) + "\n"
	else:
		var last := _editor.get_line_count() - 1
		_editor.insert_text("\n".join(lines) + "\n", last, _editor.get_line(last).length())
	if at_bottom:
		_scroll_to_end()

## Follow only while already at the bottom: a deliberate scroll-up to read
## earlier output must not be yanked back down by the next line.
func _is_scrolled_to_bottom() -> bool:
	if _editor == null:
		return true
	var bar := _editor.get_v_scroll_bar()
	if bar == null:
		return true
	return bar.value + bar.page >= bar.max_value - 1.0

func _scroll_to_end():
	if _editor == null:
		return
	var bar := _editor.get_v_scroll_bar()
	if bar != null:
		bar.value = bar.max_value

func _recompute_cell_metrics():
	if _editor != null:
		_editor.add_theme_font_size_override("font_size", font_size)

func _pane_type() -> String:
	return "cli_view"

func _default_title() -> String:
	return "CLI View"

func _get_layout_state() -> Dictionary:
	var state := super._get_layout_state()
	state.merge({"command": command, "shell_args": shell_args.duplicate()})
	return state

func apply_settings(settings: Dictionary):
	# The previous plan is captured before `super`, not after: `super` assigns
	# `command` directly whenever the incoming value is a String, and that
	# assignment skips the length and U+FFFD checks — so a sanitiser whose
	# fallback read the *current* value would return the very value it is
	# supposed to reject.
	var prev_command := command
	var prev_args := shell_args.duplicate()
	super.apply_settings(settings)
	if settings.has("command"):
		command = PaneTypes.sanitize_shell(settings.get("command"), prev_command)
	if settings.has("shell_args"):
		# `super` never sets array properties (they have no TYPE_ match in
		# `_set_typed`), so the argv is applied here or nowhere.
		shell_args = PaneTypes.sanitize_shell_args(settings.get("shell_args"))
	if _restart_btn == null:
		return  # not in the tree yet: `_ready` starts with whatever landed here
	_sync_buttons()
	# Never restart on a settings edit: the debounced panel re-applies on
	# every keystroke, and relaunching a third-party CLI per keystroke is not
	# a settings preview. Say what is needed instead.
	if _running and (command != prev_command or shell_args != prev_args):
		_status.text = "Command changed — Restart to apply"

func _build_pane_settings_ui(panel: Control) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)

	var name_le := LineEdit.new()
	name_le.text = pane_name
	name_le.placeholder_text = "CLI View"
	name_le.text_changed.connect(func(_s): panel._debounce_timer.start())
	_add_setting_row(v, "Name:", name_le)

	var font_spin := SpinBox.new()
	font_spin.min_value = 8
	font_spin.max_value = 32
	font_spin.value = font_size
	font_spin.value_changed.connect(func(_v): panel._debounce_timer.start())
	_add_setting_row(v, "Font size:", font_spin)

	v.add_child(HSeparator.new())

	var program_le := LineEdit.new()
	program_le.text = command
	program_le.placeholder_text = "/path/to/tool"
	program_le.text_changed.connect(func(_s): panel._debounce_timer.start())
	_add_setting_row(v, "Program:", program_le)

	var args_le := LineEdit.new()
	args_le.text = " ".join(shell_args)
	args_le.placeholder_text = "--flag value"
	args_le.text_changed.connect(func(_s): panel._debounce_timer.start())
	_add_setting_row(v, "Arguments:", args_le)

	# The field renders argv joined by spaces, which cannot represent an
	# argument that contains a space. Re-splitting on every gather would
	# fragment such an argument whenever any *other* setting was edited; keep
	# the argv and only re-parse a field the user actually changed.
	var shown_args: String = args_le.text
	var shown_argv: Array = shell_args.duplicate()

	var note := Label.new()
	note.text = "Program and argument changes take effect on Restart."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 12)
	v.add_child(note)

	panel._gather_func = func():
		return {
			"pane_name": name_le.text.strip_edges(),
			"font_size": int(font_spin.value),
			"command": program_le.text.strip_edges(),
			"shell_args": _args_from_field(args_le.text, shown_args, shown_argv),
		}

	return v

## Parse the Arguments field back into argv.
##
## While the text is still exactly what was rendered the stored argv is
## authoritative; only an actual edit is parsed, with the documented v1
## limitation of whitespace separation and no quoting.
func _args_from_field(text: String, shown_text: String, shown_argv: Array) -> Array:
	if text.strip_edges() == shown_text:
		return shown_argv.duplicate()
	return text.strip_edges().split(" ", false)

func _add_setting_row(parent: VBoxContainer, label: String, control: Control):
	var hb := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_font_size_override("font_size", 12)
	hb.add_child(lbl)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(control)
	parent.add_child(hb)
