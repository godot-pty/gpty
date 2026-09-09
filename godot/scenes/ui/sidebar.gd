extends Control
class_name Sidebar

signal request_new_pane(type_name: String)
signal request_close(body: Control)
signal request_settings
signal request_reset
signal request_focus(body: Control)
signal request_minimize(body: Control)
signal request_position_swap(body: Control, source_btn: Button)
signal request_type_swap(body: Control, source_btn: Button)
signal request_pane_settings(body: Control)
signal toggled
signal request_profile(name: String)
signal request_profile_rename(index: int, name: String)
signal request_save_profile
signal request_delete_profile(index: int)
signal request_window_mode(mode: int)
signal request_search
signal request_workspace_switch(index: int)
signal request_workspace_add
signal request_workspace_close(index: int)
signal request_workspace_rename(index: int, name: String)


var bg: ColorRect
var _wm_dropdown: OptionButton
var _pane_list: VBoxContainer
var _profile_list: VBoxContainer
var _workspace_list: VBoxContainer
var _active_pane: Control = null


func _ready():
	clip_contents = true
	anchor_top = 0.0
	anchor_bottom = 1.0

func build(bg_rect: ColorRect):
	bg = bg_rect
	var margin = MarginContainer.new()
	margin.name = "SidebarMargin"
	# Left/right 8px ≈ scrollbar width: rows never start at the sidebar's
	# edge, and an appearing scrollbar fills the reserved space.
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(margin)

	var v = VBoxContainer.new(); v.name = "SidebarContent"
	v.add_theme_constant_override("separation", 4)
	margin.add_child(v)

	_add_header(v)
	_add_window_mode(v)
	_add_buttons(v)
	_add_workspace_section(v)
	_add_profile_section(v)
	_add_pane_list_ui(v)
	_add_collapsed_button()

	SettingsManager.settings_changed.connect(_sync_window_mode)

func update_pane_list(panes: Array, active_body: Control = null):
	if not _pane_list: return
	_active_pane = active_body
	for c in _pane_list.get_children(): c.queue_free()
	for i in panes.size():
		var body = panes[i]
		var row = HBoxContainer.new()
		row.add_theme_constant_override("separation", 1)
		row.set_meta("body", body)

		var btn = Button.new()
		btn.text = body.get("pane_label") if body.get("pane_label") != "" else "%s?" % PaneTypes.ALL.get(body._pane_type(), {}).get("label_prefix", "?")
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_apply_row_accent(btn, body == active_body)
		btn.pressed.connect(func(): request_focus.emit(body))
		row.add_child(btn)

		var min_btn = _make_pane_action_button(Icons.RESTORE if not body.visible else Icons.MINIMIZE, "Minimize / Restore")
		min_btn.pressed.connect(func(): request_minimize.emit(body))
		row.add_child(min_btn)

		var pos_btn = _make_pane_action_button(Icons.SWAP, "Swap position")
		pos_btn.pressed.connect(func(): request_position_swap.emit(body, pos_btn))
		row.add_child(pos_btn)

		var type_btn = _make_pane_action_button(Icons.RESET, "Change pane type")
		type_btn.pressed.connect(func(): request_type_swap.emit(body, type_btn))
		row.add_child(type_btn)

		var set_btn = _make_pane_action_button(Icons.SETTINGS, "Pane settings")
		set_btn.pressed.connect(func(): request_pane_settings.emit(body))
		row.add_child(set_btn)

		var cls_btn = _make_pane_action_button(Icons.CLOSE, "Close pane")
		cls_btn.pressed.connect(func(): request_close.emit(body))
		row.add_child(cls_btn)
		_pane_list.add_child(row)

## Move the active-row accent without rebuilding the list — called on pane
## focus changes (the workspace polls `_tm.last_body` each frame).
func set_active_pane(body: Control):
	if body == _active_pane:
		return
	_active_pane = body
	for row in _pane_list.get_children():
		var btn = row.get_child(0) as Button
		if btn == null:
			continue
		_apply_row_accent(btn, row.get_meta("body") == body)

func _make_pane_action_button(icon: String, tooltip: String) -> Button:
	var btn = Button.new()
	btn.text = icon; btn.flat = true
	btn.tooltip_text = tooltip
	btn.custom_minimum_size = Vector2(20, 0)
	Icons.style_button(btn)
	return btn

func _add_header(v: VBoxContainer):
	var h = HBoxContainer.new(); h.name = "Header"
	h.add_theme_constant_override("separation", 0)
	var title = Label.new(); title.text = " gPTY"; title.add_theme_font_size_override("font_size", 16)
	title.name = "SidebarTitle"; title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(title)
	var arrow = Button.new()
	arrow.text = Icons.COLLAPSE; arrow.name = "SidebarArrow"
	Icons.style_button(arrow)
	arrow.custom_minimum_size = Vector2(22, 22)
	arrow.pressed.connect(_toggle_sidebar)
	h.add_child(arrow)
	v.add_child(h)

func _add_buttons(v: VBoxContainer):
	_add_pane_buttons(v)

	var search_btn = _make_icon_text_button(Icons.SEARCH, "Search")
	search_btn.tooltip_text = "Search the active terminal (Ctrl+F)"
	search_btn.pressed.connect(func(): request_search.emit())
	v.add_child(search_btn)

	var settings_btn = _make_icon_text_button(Icons.SETTINGS, "Settings")
	settings_btn.pressed.connect(func(): request_settings.emit())
	v.add_child(settings_btn)

	var reset_btn = _make_icon_text_button(Icons.RESET, "Reset", Color(0.85, 0.2, 0.2, 1.0))
	reset_btn.pressed.connect(func(): request_reset.emit())
	v.add_child(reset_btn)

## One clickable button holding an icon Label and a text Label in an HBox —
## the container aligns the PUA glyph and the label on the same baseline,
## which a sibling-icon layout could never do reliably.
func _make_icon_text_button(icon: String, text: String, tint := Color.WHITE) -> Button:
	var btn = Button.new()
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# A Button does not derive its minimum size from child Controls and this
	# one has no text of its own — without an explicit height it collapses.
	btn.custom_minimum_size.y = 28

	var h = HBoxContainer.new()
	h.name = "IconTextRow"
	h.add_theme_constant_override("separation", 6)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 6  # breathing room before the icon (nbsp-equivalent)
	h.alignment = BoxContainer.ALIGNMENT_BEGIN
	btn.add_child(h)

	var icon_lbl = Label.new()
	icon_lbl.text = icon
	icon_lbl.add_theme_font_override("font", Icons.font_resource)
	# Same size as the text label so both center on the same axis in the
	# stretched full-height labels (a smaller glyph font centers on a
	# different baseline and looks misaligned).
	icon_lbl.add_theme_font_size_override("font_size", 16)
	icon_lbl.add_theme_color_override("font_color", tint)
	icon_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	icon_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(icon_lbl)

	var text_lbl = Label.new()
	text_lbl.text = text
	text_lbl.add_theme_font_size_override("font_size", 16)
	text_lbl.add_theme_color_override("font_color", tint)
	text_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	text_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(text_lbl)
	return btn

func _add_window_mode(v: VBoxContainer):
	var wm_dropdown = OptionButton.new()
	wm_dropdown.name = "WindowModeDropdown"
	wm_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for label in SettingsManager.WINDOW_MODE_LABELS:
		wm_dropdown.add_item(label)
	wm_dropdown.select(SettingsManager.cfg_window_mode)
	wm_dropdown.item_selected.connect(func(idx: int): request_window_mode.emit(idx))
	v.add_child(wm_dropdown)
	_wm_dropdown = wm_dropdown

func _add_pane_buttons(v: VBoxContainer):
	var lbl = Label.new()
	lbl.text = " Add Pane:"
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	v.add_child(lbl)

	var row = HBoxContainer.new()
	row.name = "PaneTypeRow"
	row.add_theme_constant_override("separation", 2)

	for key in PaneTypes.ALL:
		var info = PaneTypes.ALL[key]
		var btn = Button.new()
		btn.text = info["icon"]
		var shortcut := str(info.get("shortcut", ""))
		btn.tooltip_text = "New " + info["name"]
		if shortcut != "":
			btn.tooltip_text += " (" + shortcut + ")"
		Icons.style_button(btn)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(0, 28)
		btn.pressed.connect(func(): request_new_pane.emit(key))
		row.add_child(btn)

	v.add_child(row)

func _sync_window_mode():
	if _wm_dropdown:
		_wm_dropdown.select(SettingsManager.cfg_window_mode)

## Every section list (workspaces, profiles, panes) shares these: a
## five-row visibility cap before an inner scrollbar, one accent color for
## the active row, and measured (not hard-coded) section heights.
const SECTION_MAX_VISIBLE_ROWS = 5
const ACCENT_COLOR = Color(0.45, 0.7, 1.0)
const ACCENT_HOVER_COLOR = Color(0.6, 0.8, 1.0)

func _add_workspace_section(parent: VBoxContainer):
	var section = VBoxContainer.new(); section.name = "WorkspaceSection"

	var header = HBoxContainer.new(); header.name = "WorkspaceHeader"
	var lbl = Label.new(); lbl.text = "Workspaces:"
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(lbl)
	var add_btn = Button.new(); add_btn.text = Icons.ADD; add_btn.name = "AddWorkspaceBtn"
	Icons.style_button(add_btn)
	add_btn.tooltip_text = "New workspace (max 8)"
	add_btn.flat = true
	add_btn.custom_minimum_size = Vector2(22, 0)
	add_btn.pressed.connect(func(): request_workspace_add.emit())
	header.add_child(add_btn)
	section.add_child(header)

	# No fixed cap on visible rows beyond 5: five rows fully shown, an
	# inner scrollbar appears only when there are more.
	var sc = ScrollContainer.new(); sc.name = "WorkspaceScroll"
	section.add_child(sc)

	_workspace_list = VBoxContainer.new(); _workspace_list.name = "WorkspaceList"
	_workspace_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_workspace_list)

	parent.add_child(section)

func update_workspace_list(names: Array[String], active: int):
	if not _workspace_list: return
	for c in _workspace_list.get_children(): c.queue_free()
	var show_close := names.size() > 1
	var rows: Array[Control] = []
	for i in names.size():
		var row := _make_workspace_row(i, names[i], i == active, show_close)
		_workspace_list.add_child(row)
		rows.append(row)
	var sc = _workspace_list.get_parent() as ScrollContainer
	if sc:
		sc.custom_minimum_size.y = _measured_section_height(_workspace_list, rows)

## Sum the real combined minimum heights of `rows` (plus the list's
## separation), capped at SECTION_MAX_VISIBLE_ROWS fully-visible rows. No
## hard-coded row heights — theme metrics decide, so a row can never be
## truncated.
func _measured_section_height(list: VBoxContainer, rows: Array[Control]) -> int:
	var separation := float(list.get_theme_constant("separation"))
	var shown := mini(rows.size(), SECTION_MAX_VISIBLE_ROWS)
	var total := 0.0
	for i in shown:
		total += rows[i].get_combined_minimum_size().y
	if shown > 0:
		total += separation * (shown - 1)
	return int(total)

## Style a section-row button as the active row (accent text + pressed
## look) or clear it. Shared by workspace, profile, and pane rows so the
## active-row semantics stay identical across sections.
func _apply_row_accent(btn: Button, active: bool):
	# `button_pressed` only sticks on toggle-mode buttons; row state is
	# managed by this helper on every refresh, so clicks never corrupt it.
	btn.toggle_mode = true
	btn.button_pressed = active
	if active:
		# A pressed button resolves text from font_pressed_color, which
		# otherwise falls back to the theme default — override all three
		# states or the accent vanishes exactly when the row is active.
		btn.add_theme_color_override("font_color", ACCENT_COLOR)
		btn.add_theme_color_override("font_hover_color", ACCENT_HOVER_COLOR)
		btn.add_theme_color_override("font_pressed_color", ACCENT_COLOR)
	else:
		btn.remove_theme_color_override("font_color")
		btn.remove_theme_color_override("font_hover_color")
		btn.remove_theme_color_override("font_pressed_color")

func _make_workspace_row(idx: int, ws_name: String, is_active: bool, show_close: bool) -> HBoxContainer:
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)

	var btn = Button.new()
	btn.text = ws_name
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.tooltip_text = "Switch workspace (double-click to rename)"
	_apply_row_accent(btn, is_active)
	btn.pressed.connect(func(): request_workspace_switch.emit(idx))
	btn.gui_input.connect(func(ev: InputEvent): _on_workspace_row_input(idx, btn, ev))
	row.add_child(btn)

	# Close button only when more than one workspace exists (min-1 invariant).
	if show_close:
		var x = Button.new(); x.text = Icons.CLOSE; x.flat = true
		Icons.style_button(x)
		x.tooltip_text = "Close workspace"
		x.custom_minimum_size = Vector2(22, 0)
		x.pressed.connect(func(): request_workspace_close.emit(idx))
		row.add_child(x)
	return row

## Swap a row label Button for an inline LineEdit; commits exactly once
## (Enter, blur, or Escape — Escape restores the original name). The
## once-only guard matters: after a commit rebuilds the list, the freed
## LineEdit still fires focus_exited, and a second commit on a freed
## object corrupted the rebuild (rows vanished until restart).
func _begin_inline_rename(btn: Button, on_commit: Callable):
	var le = LineEdit.new()
	le.text = btn.text
	le.custom_minimum_size.y = btn.size.y
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.get_parent().add_child(le)
	btn.visible = false
	le.grab_focus()
	le.select_all()
	var committed := [false]
	le.text_submitted.connect(func(t: String):
		if committed[0]:
			return
		committed[0] = true
		on_commit.call(t)
	)
	le.focus_exited.connect(func():
		if committed[0] or not is_instance_valid(le):
			return
		committed[0] = true
		on_commit.call(le.text)
	)
	le.gui_input.connect(func(e2: InputEvent):
		if e2 is InputEventKey and e2.pressed and e2.keycode == KEY_ESCAPE:
			if committed[0]:
				return
			committed[0] = true
			on_commit.call(btn.text)
	)

func _on_workspace_row_input(idx: int, btn: Button, ev: InputEvent):
	if not (ev is InputEventMouseButton):
		return
	if not ev.double_click or ev.button_index != MOUSE_BUTTON_LEFT:
		return
	_begin_inline_rename(btn, func(t: String): request_workspace_rename.emit(idx, t))

func _add_pane_list_ui(v: VBoxContainer):
	var lbl = Label.new()
	lbl.text = " Panes:"
	lbl.add_theme_font_size_override("font_size", 12)
	v.add_child(lbl)

	var sc = ScrollContainer.new()
	sc.name = "PaneScroll"
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(sc)

	_pane_list = VBoxContainer.new()
	_pane_list.name = "PaneList"
	_pane_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_pane_list)

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
	var content = get_node_or_null("SidebarMargin/SidebarContent")
	var title = get_node_or_null("SidebarMargin/SidebarContent/Header/SidebarTitle")
	var a = get_node_or_null("SidebarMargin/SidebarContent/Header/SidebarArrow")
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
	var lbl = Label.new(); lbl.text = "Profiles:"
	lbl.add_theme_font_size_override("font_size", 12)
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

func update_profile_list(profiles: Array[Dictionary], active_name := ""):
	if not _profile_list: return
	for c in _profile_list.get_children(): c.queue_free()
	var rows: Array[Control] = []
	for i in profiles.size():
		var p = profiles[i]
		var p_name = p.get("name", "Unnamed")
		var row = HBoxContainer.new()
		var btn = Button.new(); btn.text = p_name
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.tooltip_text = str(p.get("description", ""))
		_apply_row_accent(btn, p_name == active_name)
		# Toggle-mode buttons flip on click; re-assert so a canceled
		# activation dialog doesn't leave a phantom pressed row.
		btn.pressed.connect(func():
			request_profile.emit(p_name)
			_apply_row_accent(btn, p_name == active_name)
		)
		row.add_child(btn)
		if not p.get("builtin", false):
			var user_index := int(p.get("_user_index", i))
			btn.tooltip_text += "\nDouble-click to rename"
			btn.gui_input.connect(func(ev: InputEvent):
				if ev is InputEventMouseButton and ev.double_click \
						and ev.button_index == MOUSE_BUTTON_LEFT:
					_begin_inline_rename(btn, func(t: String):
						request_profile_rename.emit(user_index, t))
			)
			var x = Button.new(); x.text = Icons.DELETE; x.flat = true
			Icons.style_button(x)
			x.custom_minimum_size = Vector2(22, 0)
			x.pressed.connect(func(): request_delete_profile.emit(user_index))
			row.add_child(x)
		_profile_list.add_child(row)
		rows.append(row)

	# Show up to SECTION_MAX_VISIBLE_ROWS rows at full measured height; a
	# scrollbar appears only beyond that.
	var sc = _profile_list.get_parent() as ScrollContainer
	if sc: sc.custom_minimum_size.y = _measured_section_height(_profile_list, rows)
