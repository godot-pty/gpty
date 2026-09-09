extends Control
class_name SettingsPanel

var _debounce_timer: Timer = null
var _workspace: Control
var _menu_width: float = 540.0  # settings panel width — dialogs size relative to it

func _init(workspace: Control):
	_workspace = workspace

func _ready():
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()

func _unhandled_input(event):
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		visible = false
		get_viewport().set_input_as_handled()

func _build_ui():
	var cc = CenterContainer.new()
	add_child(cc)
	cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var bg = Panel.new()
	# Wide enough that all six tabs fit the TabContainer without clipping.
	# When tabs overflow, Godot hides trailing tabs behind a dropdown; a
	# clipped tab only becomes visible in the bar after being clicked,
	# stretching the tab bar while the panel keeps its old width (mangled
	# layout). Keep every tab visible from the start.
	bg.custom_minimum_size = Vector2(540, 560)
	_menu_width = bg.custom_minimum_size.x
	cc.add_child(bg)

	var mc = MarginContainer.new()
	mc.add_theme_constant_override("margin_left", 16)
	mc.add_theme_constant_override("margin_right", 16)
	mc.add_theme_constant_override("margin_top", 16)
	mc.add_theme_constant_override("margin_bottom", 16)
	bg.add_child(mc)
	mc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var v = VBoxContainer.new(); v.name = "VBox"
	v.add_theme_constant_override("separation", 6)
	mc.add_child(v)

	_add_settings_header(v)
	v.add_child(HSeparator.new())

	var tabs = TabContainer.new()
	tabs.add_theme_font_size_override("font_size", 13)
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(tabs)

	# Tab 1: System
	var t_sys = _create_tab(tabs, "System")
	var fps_opt = _add_fps_control(t_sys)
	var show_tb_cb = _add_show_titlebar_control(t_sys)
	var win_mode_opt = _add_window_mode_control(t_sys)
	var check_updates_cb = _add_check_updates_control(t_sys)
	_add_tab_reset(t_sys, func():
		SettingsManager.cfg_max_fps = 0
		SettingsManager.cfg_show_titlebar = true
		SettingsManager.cfg_window_mode = 0
		SettingsManager.cfg_check_updates = true
		fps_opt.selected = 6  # "Unlimited" (0)
		show_tb_cb.button_pressed = true
		win_mode_opt.selected = 0
		check_updates_cb.button_pressed = true
		SettingsManager.save_settings()
	)

	# Tab 2: Terminal
	var t_term = _create_tab(tabs, "Terminal")
	var shape_opt = _add_cursor_control(t_term)
	var blink_cb = _add_blink_control(t_term)
	var blink_spin = _add_blink_speed_control(t_term)
	var cursor_px = _add_cursor_thickness_control(t_term)
	t_term.add_child(HSeparator.new())
	var dims = _add_dims_control(t_term)
	var scroll_spin = _add_scroll_control(t_term)
	var history_spin = _add_history_control(t_term)
	t_term.add_child(HSeparator.new())
	var shell_le = _add_shell_control(t_term)
	var env_te = _add_env_control(t_term)
	_add_tab_reset(t_term, func():
		SettingsManager.cfg_cursor_shape = 0
		SettingsManager.cfg_cursor_blink = true
		SettingsManager.cfg_cursor_blink_speed = 0.5
		SettingsManager.cfg_beam_width = 2
		SettingsManager.cfg_underline_height = 3
		SettingsManager.cfg_scroll_lines = 3
		SettingsManager.cfg_history_lines = 10000
		SettingsManager.cfg_default_rows = 24
		SettingsManager.cfg_default_cols = 80
		SettingsManager.cfg_shell_command = "/bin/bash"
		SettingsManager.cfg_shell_env = ""
		shape_opt.selected = 0
		blink_cb.button_pressed = true
		blink_spin.value = 0.5
		cursor_px[0].value = 2
		cursor_px[1].value = 3
		scroll_spin.value = 3
		history_spin.value = 10000
		dims[0].value = 24
		dims[1].value = 80
		shell_le.text = "/bin/bash"
		env_te.text = ""
		SettingsManager.save_settings()
	)

	# Tab 3: Appearance
	var t_app = _create_tab(tabs, "Appearance")
	var font_btn = _add_font_picker(t_app)
	var fs_spin = _add_font_control(t_app)
	t_app.add_child(HSeparator.new())
	var scheme_btn = _add_scheme_picker(t_app)
	t_app.add_child(HSeparator.new())
	var color_btns = _add_color_section(t_app)
	_add_tab_reset(t_app, func():
		SettingsManager.cfg_font_path = "res://fonts/DejaVuSansMono.ttf"
		SettingsManager.cfg_font_size = 14
		SettingsManager.cfg_color_scheme_path = ""
		SettingsManager.cfg_wrapper_bg = SettingsManager.WRAPPER_BG_COLOR
		SettingsManager.cfg_title_bar_bg = SettingsManager.TITLE_BAR_BG_COLOR
		SettingsManager.cfg_wrapper_border = SettingsManager.WRAPPER_BORDER_COLOR
		SettingsManager.cfg_sidebar_bg = SettingsManager.SIDEBAR_BG_COLOR
		SettingsManager.cfg_focus_border = SettingsManager.FOCUS_BORDER_COLOR
		SettingsManager.cfg_selection = SettingsManager.SELECTION_COLOR
		SettingsManager.cfg_scrollback_indicator = SettingsManager.SCROLLBACK_INDICATOR_COLOR
		font_btn.text = "DejaVuSansMono.ttf"
		scheme_btn.text = "(none)"
		fs_spin.value = 14
		_reset_colors(color_btns)
		SettingsManager.save_settings()
	)

	# Tab 4: Reasoning
	var t_reas = _create_tab(tabs, "Reasoning")
	var reason_spins = _add_reasoning_control(t_reas)
	_add_tab_reset(t_reas, func():
		SettingsManager.cfg_reasoning_max_turns = 16
		SettingsManager.cfg_reasoning_max_turn_bytes = 65536
		reason_spins[0].value = 16
		reason_spins[1].value = 65536
		SettingsManager.save_settings()
	)

	# Tab 5: Concepts
	var t_con = _create_tab(tabs, "Concepts")
	_add_concept_section(t_con)

	# Tab 6: About
	var t_about = _create_tab(tabs, "About")
	_add_about_section(t_about)

	v.add_child(HSeparator.new())

	_debounce_timer = Timer.new()
	_debounce_timer.name = "DebounceTimer"
	_debounce_timer.one_shot = true
	_debounce_timer.wait_time = 0.15
	_debounce_timer.timeout.connect(func():
		SettingsManager.cfg_cursor_shape = shape_opt.selected
		SettingsManager.cfg_cursor_blink = blink_cb.button_pressed
		SettingsManager.cfg_font_size = int(fs_spin.value)
		SettingsManager.cfg_cursor_blink_speed = blink_spin.value
		SettingsManager.cfg_scroll_lines = int(scroll_spin.value)
		SettingsManager.cfg_history_lines = int(history_spin.value)
		SettingsManager.cfg_default_rows = int(dims[0].value)
		SettingsManager.cfg_default_cols = int(dims[1].value)
		SettingsManager.cfg_beam_width = int(cursor_px[0].value)
		SettingsManager.cfg_underline_height = int(cursor_px[1].value)
		SettingsManager.cfg_show_titlebar = show_tb_cb.button_pressed
		SettingsManager.cfg_window_mode = win_mode_opt.selected
		SettingsManager.cfg_reasoning_max_turns = int(reason_spins[0].value)
		SettingsManager.cfg_reasoning_max_turn_bytes = int(reason_spins[1].value)
		SettingsManager.cfg_check_updates = check_updates_cb.button_pressed
		SettingsManager.save_settings()
	)
	bg.add_child(_debounce_timer)

	shape_opt.item_selected.connect(func(_idx): _debounce_timer.start())
	blink_cb.toggled.connect(func(_pressed): _debounce_timer.start())
	blink_spin.value_changed.connect(func(_v): _debounce_timer.start())
	fs_spin.value_changed.connect(func(_v): _debounce_timer.start())
	scroll_spin.value_changed.connect(func(_v): _debounce_timer.start())
	history_spin.value_changed.connect(func(_v): _debounce_timer.start())
	reason_spins[0].value_changed.connect(func(_v): _debounce_timer.start())
	reason_spins[1].value_changed.connect(func(_v): _debounce_timer.start())
	show_tb_cb.toggled.connect(func(_pressed): _debounce_timer.start())
	check_updates_cb.toggled.connect(func(_pressed): _debounce_timer.start())

func _create_tab(tabs: TabContainer, title: String) -> VBoxContainer:
	var sc = ScrollContainer.new()
	sc.name = title
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(sc)

	var mc = MarginContainer.new()
	mc.add_theme_constant_override("margin_left", 8)
	mc.add_theme_constant_override("margin_right", 8)
	mc.add_theme_constant_override("margin_top", 8)
	mc.add_theme_constant_override("margin_bottom", 8)
	mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.add_child(mc)

	var v = VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mc.add_child(v)
	return v

func _add_settings_header(v: VBoxContainer):
	var h = HBoxContainer.new()
	var t = Label.new(); t.text = "Settings"; t.add_theme_font_size_override("font_size", 18)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL; h.add_child(t)
	var x = Button.new(); x.text = Icons.CLOSE; x.flat = true
	Icons.style_button(x)
	x.pressed.connect(func(): visible = false); h.add_child(x)
	v.add_child(h)

func _lbl(t: String) -> Label:
	var l = Label.new(); l.text = t; l.add_theme_font_size_override("font_size", 12); return l

func _add_cursor_control(v: VBoxContainer) -> OptionButton:
	var hs = HBoxContainer.new()
	hs.add_child(_lbl("Cursor:"))
	var opt = OptionButton.new(); opt.name = "ShapeOpt"
	opt.add_item("Block (█)"); opt.add_item("Underline (_)"); opt.add_item("Beam (|)")
	opt.selected = SettingsManager.cfg_cursor_shape
	hs.add_child(opt)
	v.add_child(hs)
	return opt

func _add_blink_control(v: VBoxContainer) -> CheckBox:
	var cb = CheckBox.new(); cb.name = "BlinkCb"; cb.text = "Cursor blink"
	cb.add_theme_font_size_override("font_size", 12)
	cb.button_pressed = SettingsManager.cfg_cursor_blink
	v.add_child(cb)
	return cb

func _add_blink_speed_control(v: VBoxContainer) -> SpinBox:
	var hb = HBoxContainer.new()
	hb.add_child(_lbl("Blink speed:"))
	var spin = SpinBox.new(); spin.name = "BlinkSpeedSpin"
	spin.get_line_edit().add_theme_font_size_override("font_size", 12)
	spin.min_value = 0.1; spin.max_value = 2.0; spin.step = 0.1
	spin.value = SettingsManager.cfg_cursor_blink_speed
	hb.add_child(spin)
	v.add_child(hb)
	return spin

func _add_font_control(v: VBoxContainer) -> SpinBox:
	var hf = HBoxContainer.new()
	hf.add_child(_lbl("Font size:"))
	var spin = SpinBox.new(); spin.name = "FontSpin"
	spin.get_line_edit().add_theme_font_size_override("font_size", 12)
	spin.min_value = 8; spin.max_value = 32
	spin.value = SettingsManager.cfg_font_size
	hf.add_child(spin)
	v.add_child(hf)
	return spin

func _add_reasoning_control(v: VBoxContainer) -> Array:
	var h1 = HBoxContainer.new()
	h1.add_child(_lbl("Max turns:"))
	var turns = SpinBox.new()
	turns.name = "ReasonTurnsSpin"
	turns.min_value = 1
	turns.max_value = 64
	turns.step = 1
	turns.value = SettingsManager.cfg_reasoning_max_turns
	h1.add_child(turns)
	v.add_child(h1)

	var h2 = HBoxContainer.new()
	h2.add_child(_lbl("Max turn bytes:"))
	var bytes = SpinBox.new()
	bytes.name = "ReasonBytesSpin"
	bytes.min_value = 4096
	bytes.max_value = 1048576
	bytes.step = 4096
	bytes.value = SettingsManager.cfg_reasoning_max_turn_bytes
	h2.add_child(bytes)
	v.add_child(h2)
	return [turns, bytes]

func _add_scroll_control(v: VBoxContainer) -> SpinBox:
	var hs = HBoxContainer.new()
	hs.add_child(_lbl("Scroll lines:"))
	var spin = SpinBox.new(); spin.name = "ScrollSpin"
	spin.get_line_edit().add_theme_font_size_override("font_size", 12)
	spin.min_value = 1; spin.max_value = 10; spin.step = 1
	spin.value = SettingsManager.cfg_scroll_lines
	hs.add_child(spin)
	v.add_child(hs)
	return spin

func _add_history_control(v: VBoxContainer) -> SpinBox:
	var hs = HBoxContainer.new()
	hs.add_child(_lbl("History lines:"))
	var spin = SpinBox.new(); spin.name = "HistorySpin"
	spin.get_line_edit().add_theme_font_size_override("font_size", 12)
	spin.min_value = 100; spin.max_value = 100000; spin.step = 100
	spin.value = SettingsManager.cfg_history_lines
	hs.add_child(spin)
	v.add_child(hs)
	return spin

func _add_dims_control(v: VBoxContainer) -> Array:
	var hr = HBoxContainer.new()
	hr.add_child(_lbl("Default size:"))
	var rspin = SpinBox.new()
	rspin.get_line_edit().add_theme_font_size_override("font_size", 12)
	rspin.min_value = 10; rspin.max_value = 100
	rspin.value = SettingsManager.cfg_default_rows
	hr.add_child(rspin)
	hr.add_child(_lbl("×"))
	var cspin = SpinBox.new()
	cspin.get_line_edit().add_theme_font_size_override("font_size", 12)
	cspin.min_value = 40; cspin.max_value = 200
	cspin.value = SettingsManager.cfg_default_cols
	hr.add_child(cspin)
	v.add_child(hr)
	return [rspin, cspin]

func _add_color_control(v: VBoxContainer, label: String, value: Color, setter: Callable, default_color: Color) -> ColorPickerButton:
	var h = HBoxContainer.new()
	var lbl = _lbl(label)
	# Uniform label column: without a fixed width the expand-fill picker
	# stretches differently per row (long labels → short pickers).
	lbl.custom_minimum_size = Vector2(96, 0)
	h.add_child(lbl)
	var btn = ColorPickerButton.new()
	btn.color = value
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.color_changed.connect(setter)
	btn.picker_created.connect(_attach_color_picker_buttons.bind(btn))
	h.add_child(btn)
	var reset = Button.new()
	reset.text = Icons.RESET
	reset.flat = true
	reset.tooltip_text = "Reset to default"
	Icons.style_button(reset)
	# ColorPickerButton.color assignment does not emit color_changed when set
	# programmatically — call the setter explicitly so cfg + debounced save run.
	reset.pressed.connect(func():
		btn.color = default_color
		setter.call(default_color)
	)
	h.add_child(reset)
	v.add_child(h)
	return btn

## Add explicit OK/Cancel buttons to a ColorPickerButton's popup pane.
## Colors apply live while picking; Cancel restores the pre-open color so
## dismissing by clicking elsewhere is never the only way out.
func _attach_color_picker_buttons(btn: ColorPickerButton):
	var picker := btn.get_picker()
	if picker == null:
		return
	var popup := btn.get_popup()
	popup.about_to_popup.connect(func():
		btn.set_meta("_pre_open_color", btn.color)
	)
	var hb = HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_END
	var cancel = Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(func():
		btn.color = btn.get_meta("_pre_open_color", btn.color)
		popup.hide()
	)
	var ok = Button.new()
	ok.text = "OK"
	ok.pressed.connect(func(): popup.hide())
	hb.add_child(cancel)
	hb.add_child(ok)
	picker.add_child(hb)

func _add_color_section(v: VBoxContainer) -> Array:
	v.add_child(_lbl("UI Colors:"))
	var btns = []
	for item in [
		["Wrapper bg", SettingsManager.cfg_wrapper_bg, SettingsManager.WRAPPER_BG_COLOR, func(c: Color): SettingsManager.cfg_wrapper_bg = c; _debounce_timer.start()],
		["Title bar", SettingsManager.cfg_title_bar_bg, SettingsManager.TITLE_BAR_BG_COLOR, func(c: Color): SettingsManager.cfg_title_bar_bg = c; _debounce_timer.start()],
		["Border", SettingsManager.cfg_wrapper_border, SettingsManager.WRAPPER_BORDER_COLOR, func(c: Color): SettingsManager.cfg_wrapper_border = c; _debounce_timer.start()],
		["Sidebar", SettingsManager.cfg_sidebar_bg, SettingsManager.SIDEBAR_BG_COLOR, func(c: Color): SettingsManager.cfg_sidebar_bg = c; _debounce_timer.start()],
		["Focus", SettingsManager.cfg_focus_border, SettingsManager.FOCUS_BORDER_COLOR, func(c: Color): SettingsManager.cfg_focus_border = c; _debounce_timer.start()],
		["Selection", SettingsManager.cfg_selection, SettingsManager.SELECTION_COLOR, func(c: Color): SettingsManager.cfg_selection = c; _debounce_timer.start()],
		["Scroll", SettingsManager.cfg_scrollback_indicator, SettingsManager.SCROLLBACK_INDICATOR_COLOR, func(c: Color): SettingsManager.cfg_scrollback_indicator = c; _debounce_timer.start()],
	]:
		var b = _add_color_control(v, item[0], item[1], item[3], item[2])
		btns.append([item[0], b, item[2]])
	return btns

func _add_file_picker(v: VBoxContainer, label: String, current_path: String, filters: Array, on_selected: Callable, reset_to_default: Callable = Callable()) -> Button:
	var h = HBoxContainer.new()
	h.add_child(_lbl(label))
	var btn = Button.new()
	btn.text = current_path.get_file() if current_path != "" else "(none)"
	btn.add_theme_font_size_override("font_size", 12)
	btn.clip_text = true
	btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(func():
		var dlg = FileDialog.new()
		dlg.access = FileDialog.ACCESS_FILESYSTEM
		dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		dlg.current_path = current_path
		for f in filters: dlg.add_filter(f[0], f[1])
		dlg.file_selected.connect(func(path: String):
			btn.text = path.get_file()
			on_selected.call(path)
			dlg.queue_free())
		dlg.canceled.connect(dlg.queue_free)
		add_child(dlg)
		dlg.popup_centered())
	h.add_child(btn)
	if reset_to_default.is_valid():
		var reset = Button.new()
		reset.text = Icons.RESET
		reset.flat = true
		reset.tooltip_text = "Reset to default"
		Icons.style_button(reset)
		reset.pressed.connect(func():
			btn.text = "(none)"
			reset_to_default.call()
		)
		h.add_child(reset)
	v.add_child(h)
	return btn

func _add_fps_control(v: VBoxContainer) -> OptionButton:
	var hf = HBoxContainer.new()
	hf.add_child(_lbl("Max FPS:"))
	
	var fps_opt = OptionButton.new(); fps_opt.name = "FpsOpt"
	fps_opt.add_theme_font_size_override("font_size", 12)
	fps_opt.add_item("60");
	fps_opt.add_item("120");
	fps_opt.add_item("144")
	fps_opt.add_item("165");
	fps_opt.add_item("240");
	fps_opt.add_item("Native");
	fps_opt.add_item("Unlimited");
	
	var presets = [60, 120, 144, 165, 240, -1, 0]
	fps_opt.selected = presets.find(SettingsManager.cfg_max_fps)
	fps_opt.item_selected.connect(func(idx: int):
		SettingsManager.cfg_max_fps = presets[idx]
		SettingsManager.save_settings()
	)
	hf.add_child(fps_opt)
	v.add_child(hf)
	return fps_opt

func _add_show_titlebar_control(v: VBoxContainer) -> CheckBox:
	var cb = CheckBox.new(); cb.name = "ShowTitlebarCb"; cb.text = "Show titlebar"
	cb.add_theme_font_size_override("font_size", 12)
	cb.button_pressed = SettingsManager.cfg_show_titlebar
	v.add_child(cb)
	return cb

func _add_window_mode_control(v: VBoxContainer) -> OptionButton:
	var hb = HBoxContainer.new()
	hb.add_child(_lbl("Window Mode:"))
	var opt = OptionButton.new()
	for label in SettingsManager.WINDOW_MODE_LABELS:
		opt.add_item(label)
	opt.selected = SettingsManager.cfg_window_mode
	opt.item_selected.connect(func(_idx): _debounce_timer.start())
	hb.add_child(opt)
	v.add_child(hb)
	return opt

func _add_check_updates_control(v: VBoxContainer) -> CheckBox:
	var cb = CheckBox.new(); cb.name = "CheckUpdatesCb"; cb.text = "Check for updates on startup"
	cb.add_theme_font_size_override("font_size", 12)
	cb.button_pressed = SettingsManager.cfg_check_updates
	v.add_child(cb)
	return cb

func _add_scheme_picker(v: VBoxContainer) -> Button:
	return _add_file_picker(v, "Color scheme:", SettingsManager.cfg_color_scheme_path, [["*.txt; *.json; *.csv", "Scheme files"]], func(path: String):
		SettingsManager.cfg_color_scheme_path = path
		SettingsManager.save_settings()
	, func():
		# Empty path = the built-in default palette (terminals revert live).
		SettingsManager.cfg_color_scheme_path = ""
		SettingsManager.save_settings()
	)

func _add_font_picker(v: VBoxContainer) -> Button:
	return _add_file_picker(v, "Font:", SettingsManager.cfg_font_path, [["*.ttf", "TrueType Fonts"]], func(path: String):
		SettingsManager.cfg_font_path = path
		SettingsManager.save_settings()
	)

func _add_cursor_thickness_control(v: VBoxContainer) -> Array:
	var h1 = HBoxContainer.new()
	h1.add_child(_lbl("Beam width (|):"))
	var bspin = SpinBox.new()
	bspin.get_line_edit().add_theme_font_size_override("font_size", 12)
	bspin.min_value = 1; bspin.max_value = 8
	bspin.value = SettingsManager.cfg_beam_width
	h1.add_child(bspin)
	h1.add_child(_lbl("px"))
	v.add_child(h1)

	var h2 = HBoxContainer.new()
	h2.add_child(_lbl("Underline height (_):"))
	var uspin = SpinBox.new()
	uspin.get_line_edit().add_theme_font_size_override("font_size", 12)
	uspin.min_value = 1; uspin.max_value = 8
	uspin.value = SettingsManager.cfg_underline_height
	h2.add_child(uspin)
	h2.add_child(_lbl("px"))
	v.add_child(h2)

	return [bspin, uspin]

func _reset_colors(btns: Array):
	# Entries are [label, ColorPickerButton, default_color]; assigning
	# btn.color fires color_changed → setter → cfg + debounced save.
	for entry in btns:
		if entry is Array and entry.size() >= 3:
			(entry[1] as ColorPickerButton).color = entry[2]

## Per-tab reset: each tab's button restores ONLY that tab's settings.
## The button spans the tab's full width with centered text.
func _add_tab_reset(v: VBoxContainer, reset_func: Callable):
	v.add_child(HSeparator.new())
	var btn = Button.new(); btn.text = "Reset tab to defaults"
	btn.add_theme_font_size_override("font_size", 12)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
	btn.pressed.connect(reset_func)
	v.add_child(btn)

func _add_shell_control(v: VBoxContainer) -> LineEdit:
	var h = HBoxContainer.new()
	h.add_child(_lbl("Shell:"))
	var le = LineEdit.new()
	le.text = SettingsManager.cfg_shell_command
	le.placeholder_text = "/bin/bash"
	le.add_theme_font_size_override("font_size", 12)
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.text_changed.connect(func(t: String):
		SettingsManager.cfg_shell_command = t
		_debounce_timer.start()
	)
	h.add_child(le)
	v.add_child(h)
	return le

func _add_env_control(v: VBoxContainer) -> TextEdit:
	v.add_child(_lbl("Environment:"))
	var te = TextEdit.new()
	te.text = SettingsManager.cfg_shell_env
	te.placeholder_text = "KEY=value (one per line)"
	te.custom_minimum_size = Vector2(0, 60)
	te.add_theme_font_size_override("font_size", 11)
	te.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	te.text_changed.connect(func():
		SettingsManager.cfg_shell_env = te.text
		_debounce_timer.start()
	)
	v.add_child(te)
	return te

var _version_label: Label
var _concept_list: VBoxContainer
var _concept_terminal: GptyTerminal  # any terminal for global concept FFI

func _add_about_section(v: VBoxContainer):
	_version_label = Label.new()
	_version_label.name = "VersionLabel"
	_version_label.text = "gpty v" + GptyTerminal.get_app_version()
	_version_label.add_theme_font_size_override("font_size", 14)
	v.add_child(_version_label)

	v.add_child(HSeparator.new())

	var ipc_row = HBoxContainer.new()
	ipc_row.add_child(_lbl("IPC protocol:"))
	var ipc_val = Label.new()
	ipc_val.text = "2.0"
	ipc_val.add_theme_font_size_override("font_size", 12)
	ipc_row.add_child(ipc_val)
	v.add_child(ipc_row)

	var url_lbl = Label.new()
	url_lbl.name = "RepoUrl"
	url_lbl.text = "github.com/godot-pty/gpty"
	url_lbl.add_theme_font_size_override("font_size", 12)
	v.add_child(url_lbl)

func _add_concept_section(v: VBoxContainer):
	_concept_terminal = _workspace.get_terminal_for_ffi()

	var add_btn = Button.new()
	add_btn.text = "Add Concept"
	# No terminal → no FFI vehicle for concepts; adding would silently
	# no-op on save, so disable the button instead.
	add_btn.disabled = _concept_terminal == null
	add_btn.pressed.connect(_show_concept_dialog.bind(-1))
	v.add_child(add_btn)

	_concept_list = VBoxContainer.new()
	_concept_list.name = "ConceptList"
	v.add_child(_concept_list)
	_refresh_concept_list()

func _refresh_concept_list():
	if _concept_list == null:
		return
	for c in _concept_list.get_children():
		c.queue_free()
	var concepts = ConceptManager.get_concepts() if _concept_terminal else []
	for i in concepts.size():
		var c = concepts[i]
		var enabled: bool = c.get("enabled", true)
		var h = HBoxContainer.new()
		# Enabled toggle
		var toggle = CheckButton.new()
		toggle.button_pressed = enabled
		toggle.toggled.connect(func(_on: bool):
			if _concept_terminal == null:
				return
			ConceptManager.toggle_concept(str(c.get("name", "")))
			_refresh_concept_list()
		)
		h.add_child(toggle)
		var lbl = Label.new()
		lbl.text = "%s  →  %s" % [c.get("name", "?"), c.get("trigger", "?")]
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if not enabled:
			lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		h.add_child(lbl)
		var edit_btn = Button.new(); edit_btn.text = "Edit"
		edit_btn.pressed.connect(_show_concept_dialog.bind(i))
		h.add_child(edit_btn)
		var del_btn = Button.new(); del_btn.text = Icons.DELETE
		Icons.style_button(del_btn)
		del_btn.pressed.connect(func(): _delete_concept(i))
		h.add_child(del_btn)
		_concept_list.add_child(h)

func _show_concept_dialog(idx: int):
	var dlg = AcceptDialog.new()
	dlg.title = "Edit Concept" if idx >= 0 else "Add Concept"
	# 90% of the settings menu width — the default dialog is cramped for
	# regex triggers and commands.
	dlg.min_size = Vector2i(int(_menu_width * 0.9), 0)
	var v = VBoxContainer.new()
	dlg.add_child(v)
	var name_le = LineEdit.new(); name_le.placeholder_text = "Concept name"
	var regex_le = LineEdit.new(); regex_le.placeholder_text = "Regex trigger"
	var cmd_le = LineEdit.new(); cmd_le.placeholder_text = "Action command"
	var target_le = LineEdit.new(); target_le.placeholder_text = "Target label"
	var enabled_cb = CheckButton.new(); enabled_cb.text = "Enabled"
	enabled_cb.button_pressed = true
	# Capture mode selector
	var mode_opt = OptionButton.new()
	mode_opt.add_item("Single line")
	mode_opt.add_item("Capture until stop")
	var timeout_spin = SpinBox.new()
	timeout_spin.min_value = 50; timeout_spin.max_value = 5000
	timeout_spin.step = 50; timeout_spin.value = 300
	var stop_on_input_cb = CheckButton.new(); stop_on_input_cb.text = "Stop on input"
	stop_on_input_cb.button_pressed = true
	timeout_spin.visible = false; stop_on_input_cb.visible = false
	mode_opt.item_selected.connect(func(sel: int):
		timeout_spin.visible = (sel == 1)
		stop_on_input_cb.visible = (sel == 1)
	)
	if idx >= 0:
		var concepts = ConceptManager.get_concepts()
		if idx < concepts.size():
			var c = concepts[idx]
			name_le.text = c.get("name", "")
			regex_le.text = c.get("trigger", "")
			enabled_cb.button_pressed = c.get("enabled", true)
			var acts = c.get("actions", [])
			if acts.size() > 0:
				cmd_le.text = acts[0].get("cmd", "")
				target_le.text = acts[0].get("target", "")
			var cap_mode = c.get("capture_mode", "single_line")
			if cap_mode == "until_stop":
				mode_opt.selected = 1
				timeout_spin.visible = true
				stop_on_input_cb.visible = true
				timeout_spin.value = c.get("stop_timeout_ms", 300)
				stop_on_input_cb.button_pressed = c.get("stop_on_input", true)
			else:
				mode_opt.selected = 0
	v.add_child(_lbl("Name:")); v.add_child(name_le)
	v.add_child(_lbl("Regex:")); v.add_child(regex_le)
	v.add_child(_lbl("Command:")); v.add_child(cmd_le)
	v.add_child(_lbl("Target:")); v.add_child(target_le)
	v.add_child(enabled_cb)
	v.add_child(_lbl("Capture mode:")); v.add_child(mode_opt)
	v.add_child(timeout_spin)
	v.add_child(stop_on_input_cb)
	dlg.confirmed.connect(func():
		var capture_mode = "until_stop" if mode_opt.selected == 1 else "single_line"
		_save_concept(idx, name_le.text, regex_le.text, cmd_le.text, target_le.text,
			enabled_cb.button_pressed, capture_mode, int(timeout_spin.value), stop_on_input_cb.button_pressed)
		dlg.queue_free()
	)
	add_child(dlg)
	dlg.popup_centered()
func _save_concept(idx: int, p_name: String, regex_pat: String, cmd: String, target: String,
	p_enabled: bool = true, p_capture_mode: String = "single_line",
	stop_ms: int = 300, stop_input: bool = true):
	if p_name.strip_edges() == "":
		return
	var entry: Dictionary = {
		"name": p_name.strip_edges(),
		"trigger": regex_pat,
		"enabled": p_enabled,
		"capture_mode": p_capture_mode,
		"actions": [{"cmd": cmd, "target": target.strip_edges()}],
	}
	if p_capture_mode == "until_stop":
		entry["stop_timeout_ms"] = stop_ms
		entry["stop_on_input"] = stop_input
	ConceptManager._migrate_actions_target(entry)
	var user = ConceptManager._load_from_file()
	var replaced := false
	for i in user.size():
		if user[i] is Dictionary and user[i].get("name", "") == entry["name"]:
			user[i] = entry
			replaced = true
			break
	if not replaced:
		user.append(entry)
	ConceptManager.save_concepts(user)
	_refresh_concept_list()

func _delete_concept(idx: int):
	var concepts = ConceptManager.get_concepts()
	if idx < 0 or idx >= concepts.size():
		return
	var concept_name: String = str(concepts[idx].get("name", ""))
	if concept_name == "":
		return
	var user = ConceptManager._load_from_file()
	var kept: Array = []
	for c in user:
		if c is Dictionary and c.get("name", "") == concept_name:
			continue
		kept.append(c)
	if ConceptManager._default_names(ConceptManager._load_defaults()).has(concept_name):
		kept.append({"name": concept_name, "enabled": false})
	ConceptManager.save_concepts(kept)
	_refresh_concept_list()
