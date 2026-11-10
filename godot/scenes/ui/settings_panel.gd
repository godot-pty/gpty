extends OverlayPanel
class_name SettingsPanel

## Asks the workspace to open the visual concept editor over this panel.
signal request_graph_editor

var _debounce_timer: Timer = null
var _workspace: Control
var _menu_width: float = 540.0  # settings panel width — dialogs size relative to it
## The disk-usage row in the Terminal tab; refreshed whenever the panel opens,
## because the panel outlives a single visit and scrollback keeps growing.
var _history_size_label: Label = null
## The scale row's "shown at N %" hint; see `_refresh_ui_scale_hint`.
var _ui_scale_hint: Label = null
## The seven chrome-colour rows, kept so a palette switch can re-point their
## swatches: an untouched colour moves with the palette, and the picker must
## show the value the setting actually holds.
var _color_rows: Array[Dictionary] = []
## How the row reads the store size. Overridable so a test can pin a number:
## the real store grows while the suite runs (every pane has a writer thread).
var _history_stats_provider := Callable()
## The tab bar and the Commands tab, kept so `open_commands()` can land on the
## right one whatever order the tabs are built in.
var _tabs: TabContainer = null
var _command_tab: VBoxContainer = null
var _command_list: ItemList = null
var _command_empty: Label = null
## The Commands tab's row buttons by role ("add", "edit", "delete", "up",
## "down"), so `_sync_command_buttons` enables them by what the selection is.
var _command_actions := {}

func _init(workspace: Control):
	_workspace = workspace

func _ready():
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()

func _notification(what: int):
	if not visible:
		return
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		_refresh_history_size()
		_refresh_ui_scale_hint()
		# The list outlives a visit: a command saved from the palette while the
		# panel was closed must be there on the next open.
		_refresh_command_list()
		# The About tab's chords are read from the registry, which a workspace
		# fills after this panel may already exist: re-read on every show so the
		# table cannot print a binding from before that happened.
		_refresh_shortcut_list()
	elif what == NOTIFICATION_RESIZED:
		# The window (and with it the layout space) changed, so the scale it can
		# show may have moved while the panel is open.
		_refresh_ui_scale_hint()

func _build_ui():
	var cc = CenterContainer.new()
	add_child(cc)
	cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var bg = Panel.new()
	# Wide enough that all seven tabs fit the TabContainer without clipping.
	# When tabs overflow, Godot hides trailing tabs behind a dropdown; a
	# clipped tab only becomes visible in the bar after being clicked,
	# stretching the tab bar while the panel keeps its old width (mangled
	# layout). Keep every tab visible from the start.
	#
	# This card *is* the layout floor: `UiTokens.MIN_LAYOUT` is the size
	# `SettingsManager` caps the UI scale against, so the two cannot drift.
	bg.custom_minimum_size = UiTokens.MIN_LAYOUT
	_menu_width = bg.custom_minimum_size.x
	cc.add_child(bg)

	var mc = MarginContainer.new()
	UiTheme.margins(mc, UiTokens.SPACE_XXL)
	bg.add_child(mc)
	mc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var v = VBoxContainer.new(); v.name = "VBox"
	v.add_theme_constant_override("separation", UiTokens.SPACE_MD)
	mc.add_child(v)

	_add_settings_header(v)
	v.add_child(HSeparator.new())

	var tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(tabs)
	_tabs = tabs

	# Tab 1: System
	var t_sys = _create_tab(tabs, "System")
	var fps_opt = _add_fps_control(t_sys)
	var win_mode_opt = _add_window_mode_control(t_sys)
	var check_updates_cb = _add_check_updates_control(t_sys)
	_add_tab_reset(t_sys, func():
		SettingsManager.cfg_max_fps = 0
		SettingsManager.cfg_window_mode = 0
		SettingsManager.cfg_check_updates = true
		fps_opt.selected = 6  # "Unlimited" (0)
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
	_add_history_size_row(t_term)
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
		SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
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
		shell_le.text = SettingsManager.default_shell_command()
		env_te.text = ""
		SettingsManager.save_settings()
	)

	# Tab 3: Appearance
	var t_app = _create_tab(tabs, "Appearance")
	var appearance_opt = _add_appearance_control(t_app)
	var font_btn = _add_font_picker(t_app)
	var fs_spin = _add_font_control(t_app)
	var scale_opt = _add_ui_scale_control(t_app)
	t_app.add_child(HSeparator.new())
	var scheme_btn = _add_scheme_picker(t_app)
	t_app.add_child(HSeparator.new())
	# The pane titlebar on/off sits with the chrome it controls — next to the
	# "Title bar" colour and the border — instead of hiding in the System tab,
	# where nobody looking for a titlebar setting would find it. It is a global
	# setting, so it is not in the per-pane settings popup.
	var show_tb_cb = _add_show_titlebar_control(t_app)
	var color_btns = _add_color_section(t_app)
	_add_tab_reset(t_app, func():
		SettingsManager.cfg_font_path = "res://fonts/DejaVuSansMono.ttf"
		SettingsManager.cfg_font_size = 14
		SettingsManager.cfg_ui_scale = 100
		SettingsManager.cfg_color_scheme_path = ""
		SettingsManager.cfg_show_titlebar = true
		SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_DARK
		# Resolve first: the rows below reset to the palette's own values, and
		# the mode just went back to dark.
		SettingsManager.apply_appearance()
		for key in SettingsManager.CHROME_COLOR_TOKENS:
			SettingsManager.set("cfg_" + key,
				UiPalette.active().color(SettingsManager.CHROME_COLOR_TOKENS[key]))
		font_btn.text = "DejaVuSansMono.ttf"
		scheme_btn.text = "(none)"
		fs_spin.value = 14
		scale_opt.selected = 0
		appearance_opt.selected = SettingsManager.APPEARANCE_DARK
		show_tb_cb.button_pressed = true
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

	# Tab 6: Commands — before About, so the shipped tabs keep their positions
	var t_cmd = _create_tab(tabs, "Commands")
	_command_tab = t_cmd
	_add_command_section(t_cmd)

	# Tab 7: About
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
	SettingsManager.appearance_changed.connect(func(_dark: bool): _sync_color_rows())

func _create_tab(tabs: TabContainer, title: String) -> VBoxContainer:
	var sc = ScrollContainer.new()
	sc.name = title
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(sc)

	var mc = MarginContainer.new()
	UiTheme.margins(mc, UiTokens.SPACE_LG)
	mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.add_child(mc)

	var v = VBoxContainer.new()
	v.add_theme_constant_override("separation", UiTokens.SPACE_LG)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mc.add_child(v)
	return v

func _add_settings_header(v: VBoxContainer):
	var h = HBoxContainer.new()
	var t = Label.new(); t.text = "Settings"; t.add_theme_font_size_override("font_size", UiTokens.FS_TITLE)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL; h.add_child(t)
	var x = Button.new()
	Icons.icon_button(x, Icons.CLOSE, "Close settings")
	x.pressed.connect(close); h.add_child(x)
	v.add_child(h)

func _lbl(t: String) -> Label:
	var l = Label.new(); l.text = t; return l

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
	cb.button_pressed = SettingsManager.cfg_cursor_blink
	v.add_child(cb)
	return cb

func _add_blink_speed_control(v: VBoxContainer) -> SpinBox:
	var hb = HBoxContainer.new()
	hb.add_child(_lbl("Blink speed:"))
	var spin = SpinBox.new(); spin.name = "BlinkSpeedSpin"
	spin.min_value = 0.1; spin.max_value = 2.0; spin.step = 0.1
	spin.value = SettingsManager.cfg_cursor_blink_speed
	hb.add_child(spin)
	v.add_child(hb)
	return spin

func _add_font_control(v: VBoxContainer) -> SpinBox:
	var hf = HBoxContainer.new()
	hf.add_child(_lbl("Font size:"))
	var spin = SpinBox.new(); spin.name = "FontSpin"
	spin.min_value = 8; spin.max_value = 32
	spin.value = SettingsManager.cfg_font_size
	hf.add_child(spin)
	v.add_child(hf)
	return spin

## The UI scale, in the percentage steps `UI_SCALE_PRESETS` offers. Written and
## saved on selection rather than through `_debounce_timer`: the point of the
## control is to see the change, and `settings_changed` applies it.
func _add_ui_scale_control(v: VBoxContainer) -> OptionButton:
	var hf = HBoxContainer.new()
	hf.add_child(_lbl("UI scale:"))

	var scale_opt = OptionButton.new(); scale_opt.name = "UiScaleOpt"
	var presets: Array = SettingsManager.UI_SCALE_PRESETS.duplicate()
	for p in presets:
		scale_opt.add_item("%d%%" % p)
	var scale_idx: int = presets.find(SettingsManager.cfg_ui_scale)
	if scale_idx < 0:
		# The same trap the FPS picker documents: `find()` returns -1 for a
		# stored value that is not a step, and `selected = -1` leaves the
		# dropdown blank with no way to see the current value.
		presets.append(SettingsManager.cfg_ui_scale)
		scale_opt.add_item("%d%% (custom)" % SettingsManager.cfg_ui_scale)
		scale_idx = presets.size() - 1
	scale_opt.selected = scale_idx
	scale_opt.item_selected.connect(func(idx: int):
		SettingsManager.cfg_ui_scale = presets[idx]
		SettingsManager.save_settings()
		_refresh_ui_scale_hint()
	)
	hf.add_child(scale_opt)
	# What the window actually shows, in the same row and on one line, so the
	# card's measured 540 x 560 does not move. Empty unless the clamp bites.
	_ui_scale_hint = Label.new()
	_ui_scale_hint.name = "UiScaleHint"
	_ui_scale_hint.theme_type_variation = UiTheme.MUTED_LABEL
	_ui_scale_hint.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_ui_scale_hint.mouse_filter = Control.MOUSE_FILTER_STOP  # a tooltip needs a hover target
	hf.add_child(_ui_scale_hint)
	v.add_child(hf)
	_refresh_ui_scale_hint()
	return scale_opt

## The scale row's second half: the scale the window shows, when the cap in
## `SettingsManager.applied_ui_scale_percent()` is below the picker's value.
func _refresh_ui_scale_hint() -> void:
	if _ui_scale_hint == null:
		return
	var requested := SettingsManager.cfg_ui_scale
	var applied := SettingsManager.applied_ui_scale_percent()
	_ui_scale_hint.text = ui_scale_hint(requested, applied)
	_ui_scale_hint.tooltip_text = ui_scale_hint_tooltip(requested, applied)

## The hint's text, pure so the wording is pinned without a window: empty when
## the window shows the request, otherwise the scale it does show.
static func ui_scale_hint(requested: int, applied: int) -> String:
	if requested == applied:
		return ""
	return "shown at %d %%" % applied

## The hint's tooltip, same shape and the same condition.
static func ui_scale_hint_tooltip(requested: int, applied: int) -> String:
	if requested == applied:
		return ""
	return (
		"This window shows the interface at %d %% instead of %d %%: at the larger "
		+ "scale the layout would be smaller than %d x %d px and the Settings card "
		+ "would not fit. Make the window bigger to use the full scale."
	) % [applied, requested, int(UiTokens.MIN_LAYOUT.x), int(UiTokens.MIN_LAYOUT.y)]

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
	spin.min_value = 1; spin.max_value = 10; spin.step = 1
	spin.value = SettingsManager.cfg_scroll_lines
	hs.add_child(spin)
	v.add_child(hs)
	return spin

func _add_history_control(v: VBoxContainer) -> SpinBox:
	var hs = HBoxContainer.new()
	hs.add_child(_lbl("History lines:"))
	var spin = SpinBox.new(); spin.name = "HistorySpin"
	spin.min_value = 100; spin.max_value = 100000; spin.step = 100
	spin.value = SettingsManager.cfg_history_lines
	hs.add_child(spin)
	v.add_child(hs)
	return spin

## What scrollback costs on disk.
##
## The store is bounded by rows *and* bytes, so the number cannot be derived
## from `History lines` — it depends on how long the lines actually were. Shown
## as a hint (refresh on open), not as a live gauge.
func _add_history_size_row(v: VBoxContainer) -> void:
	var hs = HBoxContainer.new()
	hs.add_child(_lbl("On disk:"))
	var size = Label.new()
	size.name = "HistorySizeLabel"
	hs.add_child(size)
	v.add_child(hs)
	_history_size_label = size
	_refresh_history_size()

func _refresh_history_size() -> void:
	if _history_size_label == null or not is_instance_valid(_history_size_label):
		return
	var raw := (
		str(_history_stats_provider.call())
		if _history_stats_provider.is_valid()
		else str(GptyTerminal.history_store_stats())
	)
	var stats = JSON.parse_string(raw)
	if not (stats is Dictionary):
		_history_size_label.text = "unavailable"
		return
	_history_size_label.text = format_bytes(int(stats.get("bytes", -1)))
	_history_size_label.tooltip_text = str(stats.get("path", ""))


## Human-readable byte count. Static and pure so the formatting is testable
## without a panel or a store.
static func format_bytes(bytes: int) -> String:
	if bytes < 0:
		return "unavailable"
	var units := ["B", "KiB", "MiB", "GiB", "TiB"]
	var value := float(bytes)
	var unit := 0
	while value >= 1024.0 and unit < units.size() - 1:
		value /= 1024.0
		unit += 1
	if unit == 0:
		return "%d B" % bytes
	return "%.1f %s" % [value, units[unit]]

func _add_dims_control(v: VBoxContainer) -> Array:
	var hr = HBoxContainer.new()
	hr.add_child(_lbl("Default size:"))
	var rspin = SpinBox.new()
	rspin.min_value = 10; rspin.max_value = 100
	rspin.value = SettingsManager.cfg_default_rows
	hr.add_child(rspin)
	hr.add_child(_lbl("×"))
	var cspin = SpinBox.new()
	cspin.min_value = 40; cspin.max_value = 200
	cspin.value = SettingsManager.cfg_default_cols
	hr.add_child(cspin)
	v.add_child(hr)
	return [rspin, cspin]

## The chrome's colour mode. Its own row at the top of the tab: it decides the
## palette every other control on this page renders in.
func _add_appearance_control(v: VBoxContainer) -> OptionButton:
	var hb = HBoxContainer.new()
	hb.add_child(_lbl("Appearance:"))
	var opt = OptionButton.new(); opt.name = "AppearanceOpt"
	for label in SettingsManager.APPEARANCE_LABELS:
		opt.add_item(label)
	opt.selected = SettingsManager.cfg_appearance_mode
	opt.tooltip_text = "Dark, light, or whatever the desktop is using"
	# Immediate, not debounced: a mode is one decision, not a slider.
	opt.item_selected.connect(func(idx: int):
		SettingsManager.cfg_appearance_mode = idx
		SettingsManager.save_settings()
	)
	hb.add_child(opt)
	v.add_child(hb)
	return opt

func _add_color_control(v: VBoxContainer, label: String, value: Color, setter: Callable, default_color: Callable) -> Array:
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
	ColorSwatch.attach(lbl, btn)
	h.add_child(btn)
	var reset = Button.new()
	reset.tooltip_text = "Reset to default"
	Icons.icon_button(reset, Icons.RESET, "Reset to default")
	# ColorPickerButton.color assignment does not emit color_changed when set
	# programmatically — call the setter explicitly so cfg + debounced save run.
	# The default is a provider, not a captured colour: it is the active
	# palette's token, which moves when the mode does.
	reset.pressed.connect(func():
		var c: Color = default_color.call()
		btn.color = c
		ColorSwatch.sync(lbl, btn)
		setter.call(c)
	)
	h.add_child(reset)
	v.add_child(h)
	return [btn, lbl]

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

## The seven chrome colours, one row each. A row is driven by its settings key,
## so the default it resets to and the value it shows are both the active
## palette's — never a colour captured when the panel was built.
func _add_color_section(v: VBoxContainer) -> Array:
	v.add_child(_lbl("UI Colors:"))
	_color_rows.clear()
	for item in [
		["Wrapper bg", "wrapper_bg"],
		["Title bar", "title_bar_bg"],
		["Border", "wrapper_border"],
		["Sidebar", "sidebar_bg"],
		["Focus", "focus_border"],
		["Selection", "selection"],
		["Scroll", "scrollback_indicator"],
	]:
		var key: String = item[1]
		var setter := func(c: Color):
			SettingsManager.set("cfg_" + key, c)
			_debounce_timer.start()
		var default_color := func() -> Color:
			return UiPalette.active().color(SettingsManager.CHROME_COLOR_TOKENS[key])
		var row: Array = _add_color_control(v, item[0], SettingsManager.get("cfg_" + key), setter, default_color)
		var btn: ColorPickerButton = row[0]
		_color_rows.append({"label": item[0], "label_node": row[1], "key": key, "button": btn, "set": setter})
	return _color_rows

## Re-point every swatch at the value its setting now holds, after a palette
## switch carried the untouched ones. Assigning `color` emits nothing, so this
## cannot feed back into the debounced save.
func _sync_color_rows() -> void:
	for row in _color_rows:
		var btn := row["button"] as ColorPickerButton
		btn.color = SettingsManager.get("cfg_" + row["key"])
		ColorSwatch.sync(row["label_node"] as Label, btn)

func _add_file_picker(v: VBoxContainer, label: String, current_path: String, filters: Array, on_selected: Callable, reset_to_default: Callable = Callable()) -> Button:
	var h = HBoxContainer.new()
	h.add_child(_lbl(label))
	var btn = Button.new()
	btn.text = current_path.get_file() if current_path != "" else "(none)"
	btn.clip_text = true
	btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(func():
		var dlg := AppDialog.picker(self, label.trim_suffix(":"), FileDialog.FILE_MODE_OPEN_FILE)
		dlg.current_path = current_path
		for f in filters: dlg.add_filter(f[0], f[1])
		dlg.file_selected.connect(func(path: String):
			btn.text = path.get_file()
			on_selected.call(path)
			dlg.queue_free())
		dlg.canceled.connect(dlg.queue_free)
		dlg.popup_centered())
	h.add_child(btn)
	if reset_to_default.is_valid():
		var reset = Button.new()
		reset.tooltip_text = "Reset to default"
		Icons.icon_button(reset, Icons.RESET, "Reset to default")
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
	fps_opt.add_item("60");
	fps_opt.add_item("120");
	fps_opt.add_item("144")
	fps_opt.add_item("165");
	fps_opt.add_item("240");
	fps_opt.add_item("Native");
	fps_opt.add_item("Unlimited");
	
	var presets = [60, 120, 144, 165, 240, -1, 0]
	var fps_idx: int = presets.find(SettingsManager.cfg_max_fps)
	if fps_idx < 0:
		# Hand-edited / unsupported value: find() returns -1, and selected = -1
		# leaves the dropdown blank with no way to see the current value. Show
		# the actual setting as its own trailing entry instead.
		presets.append(SettingsManager.cfg_max_fps)
		fps_opt.add_item(str(SettingsManager.cfg_max_fps) + " (custom)")
		fps_idx = presets.size() - 1
	fps_opt.selected = fps_idx
	fps_opt.item_selected.connect(func(idx: int):
		SettingsManager.cfg_max_fps = presets[idx]
		SettingsManager.save_settings()
	)
	hf.add_child(fps_opt)
	v.add_child(hf)
	return fps_opt

func _add_show_titlebar_control(v: VBoxContainer) -> CheckBox:
	var cb = CheckBox.new(); cb.name = "ShowTitlebarCb"; cb.text = "Show titlebar"
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
	# Same name and explanation as the sidebar's dropdown: the two select the
	# same setting, and three bare words never said what a mode draws.
	opt.accessibility_name = SettingsManager.WINDOW_MODE_TITLE
	opt.tooltip_text = SettingsManager.WINDOW_MODE_HINT
	opt.item_selected.connect(func(_idx): _debounce_timer.start())
	hb.add_child(opt)
	v.add_child(hb)
	return opt

func _add_check_updates_control(v: VBoxContainer) -> CheckBox:
	var cb = CheckBox.new(); cb.name = "CheckUpdatesCb"; cb.text = "Check for updates on startup"
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
	return _add_file_picker(v, "Font:", SettingsManager.cfg_font_path, [[PaneTypes.font_filter(), "Fonts"]], func(path: String):
		SettingsManager.cfg_font_path = path
		SettingsManager.save_settings()
	)

func _add_cursor_thickness_control(v: VBoxContainer) -> Array:
	var h1 = HBoxContainer.new()
	h1.add_child(_lbl("Beam width (|):"))
	var bspin = SpinBox.new()
	bspin.min_value = 1; bspin.max_value = 8
	bspin.value = SettingsManager.cfg_beam_width
	h1.add_child(bspin)
	h1.add_child(_lbl("px"))
	v.add_child(h1)

	var h2 = HBoxContainer.new()
	h2.add_child(_lbl("Underline height (_):"))
	var uspin = SpinBox.new()
	uspin.min_value = 1; uspin.max_value = 8
	uspin.value = SettingsManager.cfg_underline_height
	h2.add_child(uspin)
	h2.add_child(_lbl("px"))
	v.add_child(h2)

	return [bspin, uspin]

func _reset_colors(rows: Array) -> void:
	# Assigning `color` does not emit `color_changed`, so each row's setter runs
	# explicitly — that is what reaches cfg and the debounced save.
	for row in rows:
		var c: Color = UiPalette.active().color(SettingsManager.CHROME_COLOR_TOKENS[row["key"]])
		var btn := row["button"] as ColorPickerButton
		btn.color = c
		ColorSwatch.sync(row["label_node"] as Label, btn)
		(row["set"] as Callable).call(c)

## Per-tab reset: each tab's button restores ONLY that tab's settings.
## The button spans the tab's full width with centered text.
func _add_tab_reset(v: VBoxContainer, reset_func: Callable):
	v.add_child(HSeparator.new())
	var btn = Button.new(); btn.text = "Reset tab to defaults"
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
	btn.pressed.connect(reset_func)
	v.add_child(btn)

func _add_shell_control(v: VBoxContainer) -> LineEdit:
	var h = HBoxContainer.new()
	h.add_child(_lbl("Shell:"))
	var le = LineEdit.new()
	le.text = SettingsManager.cfg_shell_command
	le.placeholder_text = SettingsManager.default_shell_command()
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
	te.add_theme_font_size_override("font_size", UiTokens.FS_CAPTION)
	te.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	te.text_changed.connect(func():
		SettingsManager.cfg_shell_env = te.text
		_debounce_timer.start()
	)
	v.add_child(te)
	return te

var _version_label: Label
var _protocol_label: Label
var _concept_list: VBoxContainer
var _concept_terminal: GptyTerminal  # any terminal for global concept FFI
## The About tab and its shortcut table, kept so `open_about()` can land on the
## right tab and `_refresh_shortcut_list()` can rebuild the table on each open.
var _about_tab: VBoxContainer = null
var _shortcut_list: VBoxContainer = null
## The aligned chord column's floor: the widest chord in the list is
## "Ctrl+PageDown".
const SHORTCUT_CHORD_WIDTH := 108.0
## The About tab's one outbound link.
const REPO_URL := "https://github.com/godot-pty/gpty"

func _add_about_section(v: VBoxContainer):
	_version_label = Label.new()
	_version_label.name = "VersionLabel"
	_version_label.text = "gpty v" + GptyTerminal.get_app_version()
	_version_label.add_theme_font_size_override("font_size", UiTokens.FS_BODY)
	v.add_child(_version_label)

	v.add_child(HSeparator.new())

	var ipc_row = HBoxContainer.new()
	ipc_row.add_child(_lbl("IPC protocol:"))
	# From the one definition (`gpty_ipc::protocol::PROTOCOL_VERSION`), not a
	# literal: the same value the wire carries and the CLI prints.
	_protocol_label = Label.new()
	_protocol_label.name = "ProtocolLabel"
	_protocol_label.text = GptyTerminal.get_ipc_protocol_version()
	ipc_row.add_child(_protocol_label)
	v.add_child(ipc_row)

	var url_btn := Button.new()
	url_btn.name = "RepoUrl"
	url_btn.text = "github.com/godot-pty/gpty"
	url_btn.flat = true
	url_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	url_btn.theme_type_variation = UiTheme.ACCENT_BUTTON
	url_btn.tooltip_text = "Open the gPTY repository in your browser"
	url_btn.pressed.connect(func(): ExternalLink.open(REPO_URL))
	v.add_child(url_btn)

	_about_tab = v
	v.add_child(HSeparator.new())
	var shortcut_heading := Label.new()
	shortcut_heading.name = "ShortcutHeading"
	shortcut_heading.text = "Keyboard Shortcuts"
	shortcut_heading.add_theme_font_size_override("font_size", UiTokens.FS_BODY)
	v.add_child(shortcut_heading)
	_shortcut_list = VBoxContainer.new()
	_shortcut_list.name = "ShortcutList"
	_shortcut_list.add_theme_constant_override("separation", UiTokens.SPACE_SM)
	v.add_child(_shortcut_list)
	_refresh_shortcut_list()

## Rebuild the shortcut table from the registry. Called on construction, on
## `open_about()` and whenever the panel is shown: a chord is only known once
## the workspace has registered it, so the list is re-read rather than
## snapshotted here.
func _refresh_shortcut_list() -> void:
	if _shortcut_list == null:
		return
	# Freed immediately, not queued: this runs on every open, and a queued free
	# would leave the previous table on screen for the first frame.
	for child in _shortcut_list.get_children():
		_shortcut_list.remove_child(child)
		child.free()
	var group := ""
	var grid: GridContainer = null
	for row in ShortcutCatalog.rows(func(action: String): return ShortcutManager.chord(action)):
		if row["group"] != group:
			group = str(row["group"])
			var caption := Label.new()
			caption.text = group
			caption.add_theme_font_size_override("font_size", UiTokens.FS_CAPTION)
			caption.theme_type_variation = UiTheme.MUTED_LABEL
			_shortcut_list.add_child(caption)
			grid = GridContainer.new()
			grid.columns = 2
			grid.add_theme_constant_override("h_separation", UiTokens.SPACE_XL)
			grid.add_theme_constant_override("v_separation", UiTokens.SPACE_XS)
			_shortcut_list.add_child(grid)
		var chord_lbl := Label.new()
		chord_lbl.text = str(row["chord"])
		chord_lbl.custom_minimum_size.x = SHORTCUT_CHORD_WIDTH
		chord_lbl.add_theme_font_size_override("font_size", UiTokens.FS_SMALL)
		grid.add_child(chord_lbl)
		var desc_lbl := Label.new()
		desc_lbl.text = str(row["label"])
		desc_lbl.add_theme_font_size_override("font_size", UiTokens.FS_SMALL)
		desc_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(desc_lbl)

func _add_concept_section(v: VBoxContainer):
	_concept_terminal = _workspace.get_terminal_for_ffi()

	# The visual editor is the primary authoring surface; this list stays the
	# quick index (toggle / delete / manual edit). Re-read on every save so a
	# graph edit is reflected without reopening the panel.
	ConceptManager.concepts_changed.connect(_refresh_concept_list)

	var graph_btn = Button.new()
	graph_btn.text = "Open Visual Editor"
	graph_btn.tooltip_text = "Build rules as a node graph (trigger → conditions → action)"
	graph_btn.pressed.connect(func(): request_graph_editor.emit())
	v.add_child(graph_btn)

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
	# Provenance for the rows a plugin shipped, by the name the merged set
	# carries: a rule the user did not write should say where it came from,
	# and a deduped name like "cat (2)" needs it most.
	var plugin_sources: Dictionary = ConceptManager.plugin_sources() if _concept_terminal else {}
	for i in concepts.size():
		var c = concepts[i]
		var enabled: bool = c.get("enabled", true)
		var h = HBoxContainer.new()
		var source: Dictionary = plugin_sources.get(str(c.get("name", "")), {})
		var provenance := ""
		if not source.is_empty():
			provenance = "From plugin %s (revision %s)" % [
				source.get("plugin_id", "?"), source.get("revision", "?")]
			h.tooltip_text = provenance
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
		lbl.add_theme_font_size_override("font_size", UiTokens.FS_CAPTION)
		if provenance != "":
			lbl.tooltip_text = provenance
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if not enabled:
			lbl.theme_type_variation = UiTheme.MUTED_LABEL
		h.add_child(lbl)
		var edit_btn = Button.new(); edit_btn.text = "Edit"
		edit_btn.pressed.connect(_show_concept_dialog.bind(i))
		h.add_child(edit_btn)
		var del_btn = Button.new()
		Icons.icon_button(del_btn, Icons.DELETE, "Delete concept")
		del_btn.pressed.connect(func(): _delete_concept(i))
		h.add_child(del_btn)
		_concept_list.add_child(h)

func _show_concept_dialog(idx: int):
	var dlg := AppDialog.alert(self, "Edit Concept" if idx >= 0 else "Add Concept")
	# 90% of the settings menu width — the default dialog is cramped for
	# regex triggers and target labels.
	dlg.min_size = Vector2i(int(_menu_width * 0.9), 0)
	var v = VBoxContainer.new()
	AppDialog.content(dlg).add_child(v)
	var name_le = LineEdit.new(); name_le.placeholder_text = "Concept name"
	var regex_le = LineEdit.new(); regex_le.placeholder_text = "Regex trigger"
	var target_row := _lbl("Target:"); var target_le = LineEdit.new()
	target_le.placeholder_text = "Target pane type (e.g. code_viewer)"
	var enabled_cb = CheckButton.new(); enabled_cb.text = "Enabled"
	enabled_cb.button_pressed = true
	# Mode: capture-and-route, or notify-only (publish the match, keep output).
	var mode_opt = OptionButton.new()
	mode_opt.add_item("Capture output (route to a pane)")
	mode_opt.add_item("Notify only (no capture, no routing)")
	var stop_row := _lbl("Stop after (ms):")
	var timeout_spin = SpinBox.new()
	timeout_spin.min_value = 50; timeout_spin.max_value = 5000
	timeout_spin.step = 50; timeout_spin.value = 300
	var stop_on_input_cb = CheckButton.new(); stop_on_input_cb.text = "Stop on input"
	stop_on_input_cb.button_pressed = true
	# Conditions are extra regexes ANDed with the trigger on the same line.
	# Both modes show the field: a notify-only concept can be narrowed too.
	var conditions_te = TextEdit.new()
	conditions_te.custom_minimum_size = Vector2(0, 60)
	conditions_te.placeholder_text = "one regex per line"

	# Notify-only concepts have no receiver, so the target and the capture stop
	# conditions are meaningless for them — hide rather than collect.
	var _apply_mode_visibility := func():
		var capturing: bool = mode_opt.selected == 0
		target_row.visible = capturing
		target_le.visible = capturing
		stop_row.visible = capturing
		timeout_spin.visible = capturing
		stop_on_input_cb.visible = capturing
	mode_opt.item_selected.connect(func(_sel: int): _apply_mode_visibility.call())

	if idx >= 0:
		var concepts = ConceptManager.get_concepts()
		if idx < concepts.size():
			var c = concepts[idx]
			name_le.text = c.get("name", "")
			regex_le.text = c.get("trigger", "")
			enabled_cb.button_pressed = c.get("enabled", true)
			var acts = c.get("actions", [])
			if acts.size() > 0:
				target_le.text = acts[0].get("target", "")
			mode_opt.selected = 1 if c.get("capture_mode", "until_stop") == "single_line" else 0
			timeout_spin.value = c.get("stop_timeout_ms", 300)
			stop_on_input_cb.button_pressed = c.get("stop_on_input", true)
			var conds = c.get("conditions", [])
			if conds is Array:
				var lines := PackedStringArray()
				for cond in conds:
					if cond is String:
						lines.append(cond)
				conditions_te.text = "\n".join(lines)
	v.add_child(_lbl("Name:")); v.add_child(name_le)
	v.add_child(_lbl("Regex:")); v.add_child(regex_le)
	v.add_child(_lbl("Conditions (one regex per line, all must match):")); v.add_child(conditions_te)
	v.add_child(_lbl("Mode:")); v.add_child(mode_opt)
	v.add_child(target_row); v.add_child(target_le)
	v.add_child(enabled_cb)
	v.add_child(stop_row); v.add_child(timeout_spin)
	v.add_child(stop_on_input_cb)
	_apply_mode_visibility.call()
	dlg.confirmed.connect(func():
		_save_concept(idx, name_le.text, regex_le.text, target_le.text,
			enabled_cb.button_pressed, "single_line" if mode_opt.selected == 1 else "until_stop",
			int(timeout_spin.value), stop_on_input_cb.button_pressed,
			conditions_te.text.split("\n"))
		dlg.queue_free()
	)
	dlg.popup_centered()

## Persist a concept. Concepts capture-and-route or notify; they never carry a
## command, so no command field is collected.
func _save_concept(idx: int, p_name: String, regex_pat: String, target: String,
	p_enabled: bool = true, p_capture_mode: String = "until_stop",
	stop_ms: int = 300, stop_input: bool = true, conditions: Array = []):
	if p_name.strip_edges() == "":
		return
	var condition_lines: Array = []
	for raw_line in conditions:
		if not (raw_line is String):
			continue
		var line: String = raw_line
		line = line.strip_edges()
		if line == "":
			continue
		if condition_lines.size() >= ConceptManager.MAX_CONDITIONS:
			ToastManager.warn("Only the first %d conditions per concept are kept" % ConceptManager.MAX_CONDITIONS)
			break
		condition_lines.append(line)
	var entry: Dictionary = {
		"name": p_name.strip_edges(),
		"trigger": regex_pat,
		"enabled": p_enabled,
		"capture_mode": p_capture_mode,
		"actions": [{"target": target.strip_edges()}],
		# Always written, even when empty: the merge overlays user keys onto
		# the shipped defaults, so omitting the key would let a default
		# concept's conditions come back the moment the user cleared them.
		"conditions": condition_lines,
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
	# A shipped default lives in a read-only file and a plugin's rule lives in
	# the plugin: neither can be removed by editing the user store, so
	# deleting one writes the disabled overlay that keeps it off (and that the
	# toggle flips back). The user's own rule is simply gone.
	var shipped := ConceptManager._default_names(ConceptManager._load_defaults()).has(concept_name)
	if shipped or ConceptManager.plugin_sources().has(concept_name):
		kept.append({"name": concept_name, "enabled": false})
	ConceptManager.save_concepts(kept)
	_refresh_concept_list()

# ── Commands ───────────────────────────────────────────────────────────

## The palette's "Save Command…" lands here: the Commands tab, and, when asked,
## the add form already open so the next thing typed is the command itself.
func open_commands(add_now := false) -> void:
	open()
	if _tabs != null and _command_tab != null:
		_tabs.current_tab = _tabs.get_tab_idx_from_control(_tab_control(_command_tab))
	_refresh_command_list()
	if add_now:
		_show_command_dialog(-1)

## The palette's "Keyboard Shortcuts": the About tab, where the list lives.
## Opening, never toggling, so a second run cannot close what it just opened.
func open_about() -> void:
	open()
	if _tabs != null and _about_tab != null:
		_tabs.current_tab = _tabs.get_tab_idx_from_control(_tab_control(_about_tab))
	# Read after the tab is up: the workspace registers its bindings once, and a
	# panel built before that would otherwise show the previous set.
	_refresh_shortcut_list()

## The direct child `TabContainer` indexes for a tab: `_create_tab` hands back
## the VBox *inside* the tab's ScrollContainer, and `get_tab_idx_from_control`
## answers only for a direct child (measured: it returns -1 and reports the
## parent mismatch).
func _tab_control(body: Control) -> Control:
	var node := body
	while node != null and node.get_parent() != _tabs:
		node = node.get_parent()
	return node

## Saved commands are the user's own list, so this tab is where they are
## authored and the palette only lists what is stored. There is deliberately no
## "reset tab to defaults" here: it would delete the one thing the tab holds.
func _add_command_section(v: VBoxContainer) -> void:
	var hint := Label.new()
	hint.text = "Saved commands appear in the command palette (Ctrl+Shift+P). " \
		+ "Choosing one types it into the active terminal; Run also presses Enter."
	hint.theme_type_variation = UiTheme.MUTED_LABEL
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", UiTokens.FS_SMALL)
	v.add_child(hint)

	_command_list = ItemList.new()
	_command_list.name = "CommandList"
	_command_list.custom_minimum_size = Vector2(0, 140)
	_command_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_command_list.item_selected.connect(func(_i: int): _sync_command_buttons())
	_command_list.item_activated.connect(func(_i: int): _edit_selected_command())
	v.add_child(_command_list)

	_command_empty = Label.new()
	_command_empty.name = "CommandEmpty"
	_command_empty.text = "No saved commands yet. Add\u2026 saves one here, and it appears in the palette."
	_command_empty.theme_type_variation = UiTheme.MUTED_LABEL
	_command_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_command_empty)

	var row := HBoxContainer.new()
	v.add_child(row)

	_command_actions["add"] = _command_button(row, "Add\u2026", "Append a command",
		func(): _show_command_dialog(-1))
	_command_actions["edit"] = _command_button(row, "Edit\u2026", "Edit the selected command",
		_edit_selected_command)
	var del_btn := _command_button(row, "", "Delete the selected command",
		_delete_selected_command)
	Icons.icon_button(del_btn, Icons.DELETE, "Delete the selected command")
	_command_actions["delete"] = del_btn
	_command_actions["up"] = _command_button(row, "Up", "Move the selected command up",
		func(): _move_selected_command(-1))
	_command_actions["down"] = _command_button(row, "Down", "Move the selected command down",
		func(): _move_selected_command(1))
	_refresh_command_list()

## One button in the Commands tab's row. `Add…` and `Edit…` take the generous
## share of the width and the icon/`Up`/`Down` buttons keep their natural size,
## so a long list never widens the card.
func _command_button(row: HBoxContainer, text: String, tooltip: String,
		pressed: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.tooltip_text = tooltip
	if text != "":
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(pressed)
	row.add_child(btn)
	return btn

## Rebuild the list from the store. The selection survives an edit (the row keeps
## its index) and lands on the neighbour after a delete.
func _refresh_command_list() -> void:
	if _command_list == null:
		return
	var selected := _command_list.get_selected_items()
	var keep := int(selected[0]) if not selected.is_empty() else -1
	_command_list.clear()
	var entries := SavedCommandStore.all()
	for entry in entries:
		var idx := _command_list.add_item("%s  (%s)" % [
			str(entry.get("name", "")),
			"Run" if bool(entry.get("run", false)) else "Insert",
		])
		# The command itself is the row's tooltip: the list is a name index, and
		# the text nobody can read at a glance is what a tooltip is for.
		_command_list.set_item_tooltip(idx, str(entry.get("command", "")))
	_command_list.visible = not entries.is_empty()
	_command_empty.visible = entries.is_empty()
	if keep >= 0 and keep < _command_list.item_count:
		_command_list.select(keep)
	_sync_command_buttons()

func _sync_command_buttons() -> void:
	if _command_list == null or _command_actions.is_empty():
		return
	var selected := _command_list.get_selected_items()
	var index := int(selected[0]) if not selected.is_empty() else -1
	var last := _command_list.item_count - 1
	(_command_actions["edit"] as Button).disabled = index < 0
	(_command_actions["delete"] as Button).disabled = index < 0
	(_command_actions["up"] as Button).disabled = index <= 0
	(_command_actions["down"] as Button).disabled = index < 0 or index >= last

## The add/edit form. `index` is -1 for a new command.
##
## The dialog does not close on OK by itself: a refusal (a duplicate name, an
## empty field) keeps the dialog and the text, and only a stored entry closes
## it. `run` starts off for a new command — the first encounter with a saved
## command is an insert the user can read before running.
func _show_command_dialog(index: int) -> void:
	var entries := SavedCommandStore.all()
	var editing := index >= 0 and index < entries.size()
	var existing: Dictionary = entries[index] if editing else {}
	var dlg := AppDialog.confirm(self, "Edit Command" if editing else "Add Command",
		"Save", "Cancel")
	# 90% of the settings menu width, the concept dialog's size: the command
	# field has to hold a real command line, not a word.
	dlg.min_size = Vector2i(int(_menu_width * 0.9), 0)
	dlg.dialog_hide_on_ok = false

	var v = VBoxContainer.new()
	AppDialog.content(dlg).add_child(v)

	var name_le = LineEdit.new()
	name_le.name = "CommandName"
	name_le.placeholder_text = "Name (e.g. Build)"
	name_le.text = str(existing.get("name", ""))
	var command_le = LineEdit.new()
	command_le.name = "CommandText"
	command_le.placeholder_text = "cargo build --workspace"
	command_le.text = str(existing.get("command", ""))
	var run_cb = CheckBox.new()
	run_cb.name = "CommandRun"
	run_cb.text = "Press Enter after inserting (run it)"
	run_cb.button_pressed = bool(existing.get("run", false))

	v.add_child(_lbl("Name:"))
	v.add_child(name_le)
	v.add_child(_lbl("Command:"))
	v.add_child(command_le)
	v.add_child(run_cb)

	dlg.confirmed.connect(func():
		var problem := ""
		if editing:
			problem = SavedCommandStore.update(index, name_le.text, command_le.text,
				run_cb.button_pressed)
		else:
			problem = SavedCommandStore.add(name_le.text, command_le.text,
				run_cb.button_pressed)
		if problem != "":
			ToastManager.warn(problem)
			return
		_refresh_command_list()
		dlg.queue_free()
	)
	# Cancelling frees it too: a hidden dialog left in the tree would be a
	# second "Add Command" the next time the form opens.
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()

func _edit_selected_command() -> void:
	var selected := _command_list.get_selected_items()
	if selected.is_empty():
		return
	_show_command_dialog(int(selected[0]))

func _delete_selected_command() -> void:
	var selected := _command_list.get_selected_items()
	if selected.is_empty():
		return
	SavedCommandStore.remove(int(selected[0]))
	_refresh_command_list()

func _move_selected_command(delta: int) -> void:
	var selected := _command_list.get_selected_items()
	if selected.is_empty():
		return
	var moved := SavedCommandStore.move(int(selected[0]), delta)
	_refresh_command_list()
	_command_list.select(moved)
	_sync_command_buttons()
