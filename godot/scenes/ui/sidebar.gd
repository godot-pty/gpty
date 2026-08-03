extends Control
class_name Sidebar

signal request_new_pane(type_name: String)
signal request_bulk_spawn(count: int)
signal request_close(body: Control)
signal request_settings
signal request_reset
signal request_focus(body: Control)
signal toggled
signal request_profile(name: String)
signal request_save_profile
signal request_delete_profile(index: int)
signal request_toggle_window_mode


var bg: ColorRect
var _fps_label: Label
var _pane_list: VBoxContainer
var _profile_list: VBoxContainer


func _ready():
	clip_contents = true
	anchor_top = 0.0
	anchor_bottom = 1.0

func build(bg_rect: ColorRect):
	bg = bg_rect
	var v = VBoxContainer.new(); v.name = "SidebarContent"
	v.add_theme_constant_override("separation", 4)
	add_child(v)
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_add_header(v)
	_add_fps(v)
	_add_buttons(v)
	_add_profile_section(v)
	_add_pane_list_ui(v)
	_add_collapsed_button()

func update_fps(fps: int, fetch_ms: int = -1, draw_ms: int = -1):
	if not _fps_label: return
	var txt = "FPS: %d" % fps
	if fetch_ms >= 0:
		txt += "\nFetch: %dms\nDraw: %dms" % [fetch_ms, draw_ms]
	_fps_label.text = txt

func update_pane_list(panes: Array):
	if not _pane_list: return
	for c in _pane_list.get_children(): c.queue_free()
	for i in panes.size():
		var body = panes[i]
		var row = HBoxContainer.new()
		var btn = Button.new()
		btn.text = body.get("pane_label") if body.get("pane_label") != "" else "%s?" % PaneTypes.ALL.get(body._pane_type(), {}).get("label_prefix", "?")
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(func(): request_focus.emit(body))
		row.add_child(btn)
		var x = Button.new(); x.text = Icons.CLOSE; x.flat = true
		Icons.style_button(x)
		x.custom_minimum_size = Vector2(22, 0)
		x.pressed.connect(func(): request_close.emit(body))
		row.add_child(x)
		_pane_list.add_child(row)

func _add_header(v: VBoxContainer):
	var h = HBoxContainer.new(); h.name = "Header"
	h.add_theme_constant_override("separation", 0)
	var title = Label.new(); title.text = " godopty"; title.add_theme_font_size_override("font_size", 16)
	title.name = "SidebarTitle"; title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(title)
	var arrow = Button.new()
	arrow.text = Icons.COLLAPSE; arrow.name = "SidebarArrow"
	Icons.style_button(arrow)
	arrow.custom_minimum_size = Vector2(22, 22)
	arrow.pressed.connect(_toggle_sidebar)
	h.add_child(arrow)
	v.add_child(h)

func _add_fps(v: VBoxContainer):
	_fps_label = Label.new()
	_fps_label.name = "FpsLabel"
	_fps_label.add_theme_font_size_override("font_size", 11)
	_fps_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_fps_label.text = "FPS: --"
	v.add_child(_fps_label)

func _add_buttons(v: VBoxContainer):
	# Add Pane button with PopupMenu listing all pane types
	_add_pane_buttons(v)

	# Window mode toggle button
	var wm_btn = Button.new()
	wm_btn.text = Icons.WINDOW_MODE + " Window"
	Icons.style_button(wm_btn)
	wm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wm_btn.pressed.connect(func(): request_toggle_window_mode.emit())
	v.add_child(wm_btn)

	# Remaining actions
	for b in [
		[Icons.SETTINGS + " Settings", func(): request_settings.emit()],
		[Icons.RESET + " Reset", func(): request_reset.emit()],
	]:
		var btn = Button.new(); btn.text = b[0]
		Icons.style_button(btn)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(b[1]); v.add_child(btn)

func _add_pane_buttons(v: VBoxContainer):
	var add_btn = Button.new()
	add_btn.text = Icons.ADD + " Add Pane"
	Icons.style_button(add_btn)
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_btn.pressed.connect(func():
		var menu = PopupMenu.new()
		var keys = PaneTypes.ALL.keys()
		for i in keys.size():
			var info = PaneTypes.ALL[keys[i]]
			menu.add_item(info["icon"] + " " + info["name"])
		menu.add_separator()
		menu.add_item("Terminal (x16)")
		menu.id_pressed.connect(func(id: int):
			if id < keys.size():
				request_new_pane.emit(keys[id])
			else:
				request_bulk_spawn.emit(16)
		)
		add_child(menu)
		menu.popup(Rect2(add_btn.get_screen_position(), add_btn.size))
	)
	v.add_child(add_btn)

func _add_pane_list_ui(v: VBoxContainer):
	var lbl = Label.new(); lbl.text = " Panes:"; lbl.add_theme_font_size_override("font_size", 12)
	v.add_child(lbl)
	var sc = ScrollContainer.new(); sc.name = "PaneScroll"
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL; v.add_child(sc)
	_pane_list = VBoxContainer.new(); _pane_list.name = "PaneList"
	_pane_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL; sc.add_child(_pane_list)

func _add_collapsed_button():
	var btn = Button.new()
	btn.text = Icons.EXPAND; btn.name = "SidebarCollapsedBtn"
	Icons.style_button(btn)
	btn.custom_minimum_size = Vector2(18, 22)
	btn.offset_left = 1; btn.offset_top = 2
	btn.offset_right = 19; btn.visible = false
	btn.pressed.connect(_toggle_sidebar)
	add_child(btn)

func _toggle_sidebar():
	var on = (offset_right != 180)
	var content = get_node_or_null("SidebarContent")
	var title = get_node_or_null("SidebarContent/Header/SidebarTitle")
	var a = get_node_or_null("SidebarContent/Header/SidebarArrow")
	var coll = get_node_or_null("SidebarCollapsedBtn")
	if on:
		offset_right = 180; bg.size.x = 180
		if content: content.show()
		if title: title.visible = true
		if a: a.visible = true
		if coll: coll.visible = false
	else:
		offset_right = 20; bg.size.x = 20
		if content: content.hide()
		if title: title.visible = false
		if a: a.visible = false
		if coll: coll.visible = true
	toggled.emit()

func _add_profile_section(parent: VBoxContainer):
	var section = VBoxContainer.new(); section.name = "ProfileSection"

	var header = HBoxContainer.new(); header.name = "ProfileHeader"
	var lbl = Label.new(); lbl.text = "Profiles:"; lbl.add_theme_font_size_override("font_size", 12)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(lbl)
	var save_btn = Button.new(); save_btn.text = Icons.ADD; save_btn.name = "SaveProfileBtn"
	Icons.style_button(save_btn)
	save_btn.tooltip_text = "Save current layout as profile"
	save_btn.flat = true
	save_btn.custom_minimum_size = Vector2(22, 0)
	save_btn.pressed.connect(func(): request_save_profile.emit())
	header.add_child(save_btn)
	section.add_child(header)

	var sc = ScrollContainer.new(); sc.name = "ProfileScroll"
	section.add_child(sc)

	_profile_list = VBoxContainer.new(); _profile_list.name = "ProfileList"
	_profile_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_profile_list)

	parent.add_child(section)

func update_profile_list(profiles: Array[Dictionary]):
	if not _profile_list: return
	for c in _profile_list.get_children(): c.queue_free()
	for i in profiles.size():
		var p = profiles[i]
		var p_name = p.get("name", "Unnamed")
		var row = HBoxContainer.new()
		var btn = Button.new(); btn.text = p_name
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(func(): request_profile.emit(p_name))
		row.add_child(btn)
		var x = Button.new(); x.text = Icons.DELETE; x.flat = true
		Icons.style_button(x)
		x.custom_minimum_size = Vector2(22, 0)
		x.pressed.connect(func(): request_delete_profile.emit(i))
		row.add_child(x)
		_profile_list.add_child(row)

	var sc = _profile_list.get_parent() as ScrollContainer
	if sc: sc.custom_minimum_size.y = mini(200, profiles.size() * 35)
