extends Control
class_name WorkspaceTabs
# Workspace tab strip — switch/add/close/rename workspace tabs.
# Double-click a tab to rename inline; "×" closes; "+" adds.

const HEIGHT = 28.0

signal switch_requested(idx: int)
signal add_requested
signal close_requested(idx: int)
signal rename_requested(idx: int, name: String)

var _tabs: Array[String] = []
var _active: int = 0
var _box: HBoxContainer


func _ready():
	_box = HBoxContainer.new()
	_box.name = "Tabs"
	_box.add_theme_constant_override("separation", 4)
	_box.anchor_left = 0.0
	_box.anchor_right = 1.0
	_box.anchor_top = 0.0
	_box.anchor_bottom = 1.0
	_box.offset_left = 6
	_box.offset_right = -6
	_box.offset_top = 3
	_box.offset_bottom = -3
	add_child(_box)


func update(tabs: Array[String], active: int):
	_tabs = tabs
	_active = clampi(active, 0, _tabs.size() - 1) if _tabs.size() > 0 else 0
	for c in _box.get_children():
		c.queue_free()
	for i in _tabs.size():
		_box.add_child(_make_tab(i, _tabs[i]))
	var plus = Button.new()
	plus.text = "+"
	plus.tooltip_text = "New workspace (max 8)"
	plus.flat = true
	plus.focus_mode = Control.FOCUS_NONE
	plus.custom_minimum_size = Vector2(30, HEIGHT - 6)
	plus.pressed.connect(func(): add_requested.emit())
	_box.add_child(plus)


func _make_tab(idx: int, tab_name: String) -> PanelContainer:
	var panel = PanelContainer.new()
	panel.name = "Tab%d" % idx
	panel.custom_minimum_size = Vector2(0, HEIGHT - 6)

	var h = HBoxContainer.new()
	h.add_theme_constant_override("separation", 2)
	panel.add_child(h)

	var btn = Button.new()
	btn.text = tab_name
	btn.flat = true
	btn.button_pressed = idx == _active
	btn.focus_mode = Control.FOCUS_NONE
	btn.tooltip_text = "Switch workspace (double-click to rename)"
	btn.pressed.connect(func(): switch_requested.emit(idx))
	btn.gui_input.connect(func(ev: InputEvent): _on_tab_input(idx, btn, ev))
	h.add_child(btn)

	if _tabs.size() > 1:
		var close = Button.new()
		close.flat = true
		close.focus_mode = Control.FOCUS_NONE
		close.tooltip_text = "Close workspace"
		close.custom_minimum_size = Vector2(22, HEIGHT - 10)
		var lbl = Label.new()
		lbl.text = Icons.CLOSE
		lbl.add_theme_font_override("font", Icons.font_resource)
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		close.add_child(lbl)
		close.pressed.connect(func(): close_requested.emit(idx))
		h.add_child(close)
	return panel


func _on_tab_input(idx: int, btn: Button, ev: InputEvent):
	if not (ev is InputEventMouseButton):
		return
	if not ev.double_click or ev.button_index != MOUSE_BUTTON_LEFT:
		return
	# Inline rename: swap the label button for a LineEdit; the caller's
	# rename handler refreshes the strip and discards this edit control.
	var le = LineEdit.new()
	le.text = _tabs[idx]
	le.custom_minimum_size = btn.size
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.get_parent().add_child(le)
	btn.visible = false
	le.grab_focus()
	le.select_all()
	le.text_submitted.connect(func(t: String): rename_requested.emit(idx, t))
	le.focus_exited.connect(func(): rename_requested.emit(idx, le.text))
	le.gui_input.connect(func(e2: InputEvent):
		if e2 is InputEventKey and e2.pressed and e2.keycode == KEY_ESCAPE:
			rename_requested.emit(idx, _tabs[idx])
	)
