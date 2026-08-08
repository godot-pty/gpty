extends PaneBody
class_name ObserverPane
# AI Observer pane — displays concept-triggered responses as formatted text.

@export var label_name := "observer"

var _terminal: GptyTerminal
var _display: RichTextLabel
var _shell_command := "/bin/bash"

func _ready():
	super._ready()
	
	_display = RichTextLabel.new()
	_display.name = "Display"
	_display.bbcode_enabled = true
	_display.fit_content = true
	_display.scroll_following = true
	_display.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_display.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_display)
	_display.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Spawn a shell with the observer label so concept events target it
	_terminal = GptyTerminal.new()
	_terminal.name = "GptyTerminal"
	add_child(_terminal)
	_terminal.start_shell(_shell_command, 24, 80, "")
	
	# Poll for output and append to display
	_fetch_output()

func _fetch_output():
	var last_gen = -1
	while is_inside_tree():
		await get_tree().process_frame
		if not is_inside_tree():
			return
		var new_gen = _terminal.get_grid_generation()
		if new_gen != last_gen:
			last_gen = new_gen
			var updates = _terminal.get_grid_updates_packed(true)
			var chars: Array = updates.get("chars", [])
			for line in chars:
				var text: String = line.strip_edges(false, true)
				if text != "":
					_display.append_text("[color=#0f0]" + text + "[/color]\n")

func _pane_type() -> String:
	return "observer"

func _get_layout_state() -> Dictionary:
	var state = super._get_layout_state()
	state.merge({"shell": _shell_command, "rows": 24, "cols": 80, "label": label_name})
	return state

func apply_settings(settings: Dictionary):
	super.apply_settings(settings)
	if settings.has("shell_command"):
		_shell_command = settings["shell_command"]
	if settings.has("shell"):
		_shell_command = settings["shell"]
	if settings.has("label"):
		label_name = settings["label"]
	if settings.has("label_name"):
		label_name = settings["label_name"]

func _build_pane_settings_ui(panel: Control) -> Control:
	var v = VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	
	# ── Shared pane controls ──
	var name_le = LineEdit.new()
	name_le.text = pane_name
	name_le.placeholder_text = "Observer"
	name_le.text_changed.connect(func(_s): panel._debounce_timer.start())
	_add_setting_row(v, "Name:", name_le)
	
	var font_spin = SpinBox.new()
	font_spin.min_value = 8; font_spin.max_value = 32
	font_spin.value = font_size
	font_spin.value_changed.connect(func(_v): panel._debounce_timer.start())
	_add_setting_row(v, "Font size:", font_spin)
	
	v.add_child(HSeparator.new())
	
	# ── Observer controls ──
	var label_le = LineEdit.new()
	label_le.text = label_name
	label_le.placeholder_text = "observer"
	label_le.text_changed.connect(func(_s): panel._debounce_timer.start())
	_add_setting_row(v, "Label:", label_le)
	
	var shell_te = TextEdit.new()
	shell_te.text = _shell_command
	shell_te.placeholder_text = "/bin/bash"
	shell_te.custom_minimum_size = Vector2(0, 40)
	shell_te.add_theme_font_size_override("font_size", 11)
	shell_te.text_changed.connect(func(): panel._debounce_timer.start())
	var shell_lbl = Label.new()
	shell_lbl.text = "Shell command:"
	shell_lbl.add_theme_font_size_override("font_size", 12)
	v.add_child(shell_lbl)
	v.add_child(shell_te)
	
	panel._gather_func = func():
		return {
			"pane_name": name_le.text.strip_edges(),
			"font_size": int(font_spin.value),
			"label_name": label_le.text.strip_edges(),
			"shell_command": shell_te.text.strip_edges(),
		}
	
	return v

func _add_setting_row(parent: VBoxContainer, label: String, control: Control):
	var hb = HBoxContainer.new()
	var lbl = Label.new(); lbl.text = label
	lbl.add_theme_font_size_override("font_size", 12)
	hb.add_child(lbl)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(control)
	parent.add_child(hb)
