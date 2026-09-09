extends Control
class_name PaneSettingsPanel
# Type-aware pane settings overlay. Builds a shared shell (header, close, ESC)
# and delegates content to the target pane's _build_pane_settings_ui().

var _target: Control
var _debounce_timer: Timer
var _gather_func: Callable

func _ready():
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false

func _process(_delta: float):
	# The popup is a shared workspace-level overlay: its target pane can be
	# torn down through kill, type swap, reset, workspace close, or layout
	# restore without the popup being told. A freed target makes every
	# interaction a script error (dead popup). Auto-close as soon as the
	# target dies — covers every pane type and teardown path.
	if visible and (_target == null or not is_instance_valid(_target)):
		close()

func _unhandled_input(event):
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()

func open_for(body: Control):
	_target = body
	if _target == null or not is_instance_valid(_target):
		close()
		return
	_build_ui()
	# Godot 4 GUI input picking ignores z_index: among siblings, the LAST
	# child in tree order receives clicks first (reverse tree order).
	# Rendering DOES honor z_index, which is why the popup drew on top
	# while later-added workspace grids/sidebar/status bar ate its input.
	# Move to the end of the workspace's children so it is topmost for
	# both picking and rendering while open.
	if get_parent():
		get_parent().move_child(self, -1)
	visible = true

func close():
	visible = false
	_target = null
	_gather_func = Callable()

func _build_ui():
	# Free immediately: queue_free would leave the previous build's subtree
	# (with its stale target wiring) alive and interactive for a frame when
	# reopening for another pane.
	for c in get_children():
		c.free()

	var cc = CenterContainer.new()
	add_child(cc)
	cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var bg = Panel.new()
	bg.custom_minimum_size = Vector2(380, 420)
	cc.add_child(bg)

	var mc = MarginContainer.new()
	mc.add_theme_constant_override("margin_left", 16)
	mc.add_theme_constant_override("margin_right", 16)
	mc.add_theme_constant_override("margin_top", 16)
	mc.add_theme_constant_override("margin_bottom", 16)
	bg.add_child(mc)
	mc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var v = VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	mc.add_child(v)

	# Header with close button
	var h = HBoxContainer.new()
	var t = Label.new(); t.text = "Pane Settings"
	t.add_theme_font_size_override("font_size", 18)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL; h.add_child(t)
	var x = Button.new(); x.text = Icons.CLOSE; x.flat = true
	Icons.style_button(x)
	x.pressed.connect(close); h.add_child(x)
	v.add_child(h)
	v.add_child(HSeparator.new())

	# Scrollable content area — filled by the pane type
	var sc = ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(sc)

	var content = _target._build_pane_settings_ui(self)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(content)

	# Debounce timer — fires _apply_to_target after user stops typing
	_debounce_timer = Timer.new()
	_debounce_timer.one_shot = true; _debounce_timer.wait_time = 0.15
	_debounce_timer.timeout.connect(_apply_to_target)
	bg.add_child(_debounce_timer)

func _apply_to_target():
	if _target == null or not is_instance_valid(_target): return
	if not _gather_func.is_valid(): return
	_target.apply_settings(_gather_func.call())
