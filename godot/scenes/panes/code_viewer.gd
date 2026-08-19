extends PaneBody
class_name CodeViewerPane
# Simple read-only code viewer with syntax highlighting.

@export var file_path := ""
@export var language := ""
## auto | source | rendered
@export var view_mode := "auto"

var _editor: CodeEdit
var _markdown: MarkdownView
var _view_toggle: Button
var _content := ""
var _show_rendered := false

static var _langs := ["", "md", "gd", "py", "rs", "c", "cpp", "h", "js", "ts"]
static var _view_modes := ["auto", "source", "rendered"]

func _ready():
	super._ready()

	var root = VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root)

	_view_toggle = Button.new()
	_view_toggle.name = "ViewToggle"
	_view_toggle.focus_mode = Control.FOCUS_NONE
	_view_toggle.pressed.connect(_toggle_view)
	root.add_child(_view_toggle)

	var content_root = Control.new()
	content_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(content_root)

	_editor = CodeEdit.new()
	_editor.name = "CodeEdit"
	_editor.editable = false
	_editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_editor.add_theme_font_size_override("font_size", font_size)
	content_root.add_child(_editor)
	_editor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_markdown = MarkdownView.new()
	_markdown.name = "MarkdownView"
	_markdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_markdown.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_markdown.add_theme_font_size_override("normal_font_size", font_size)
	_markdown.add_theme_font_size_override("mono_font_size", font_size)
	content_root.add_child(_markdown)
	_markdown.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	if file_path != "":
		load_file(file_path)
	else:
		_refresh_view()

func load_file(path: String):
	if path == "" or not path.is_absolute_path():
		_clear_content()
		return
	if not FileAccess.file_exists(path):
		_clear_content()
		return
	var f = FileAccess.open(path, FileAccess.READ)
	if not f:
		_clear_content()
		return
	file_path = path
	_content = f.get_as_text()
	_editor.text = _content

	# Basic syntax detection from extension
	var ext = path.get_extension().to_lower()
	match ext:
		"gd": _editor.add_comment_string("#")
		"py": _editor.add_comment_string("#")
		"rs": _editor.add_comment_string("//")
		"c", "cpp", "h", "hpp": _editor.add_comment_string("//")
	_refresh_view()

func _clear_content():
	file_path = ""
	_content = ""
	if _editor != null:
		_editor.text = ""
	_refresh_view()

func _is_markdown() -> bool:
	var effective = language.to_lower()
	if effective == "":
		effective = file_path.get_extension().to_lower()
	return effective == "md" or effective == "markdown"

func _refresh_view():
	if _editor == null or _markdown == null or _view_toggle == null:
		return
	var can_render = _is_markdown()
	_show_rendered = can_render and view_mode != "source"
	_editor.visible = not _show_rendered
	_markdown.visible = _show_rendered
	_view_toggle.visible = can_render
	_view_toggle.text = "View source" if _show_rendered else "Render Markdown"
	if _show_rendered:
		_markdown.render_now(_content)
	_markdown.scroll_to_line(0)

func _toggle_view():
	if not _is_markdown():
		return
	view_mode = "source" if _show_rendered else "rendered"
	_refresh_view()

## Receive text content from concept routing (e.g., captured command output).
## Replaces the editor content and scrolls to the top.
func can_receive_content(_event: Dictionary = {}) -> bool:
	return _editor != null

func receive_content(text: String, _event: Dictionary = {}) -> bool:
	if not can_receive_content(_event):
		return false
	_content = text
	_editor.text = text
	_editor.set_caret_line(0)
	_refresh_view()
	return true

func _pane_type() -> String:
	return "code_viewer"

func _get_layout_state() -> Dictionary:
	var state = super._get_layout_state()
	state.merge({"file_path": file_path, "language": language, "view_mode": view_mode})
	return state

func apply_settings(settings: Dictionary):
	super.apply_settings(settings)
	if settings.get("language") is String:
		language = settings["language"]
	if settings.get("view_mode") is String and settings["view_mode"] in _view_modes:
		view_mode = settings["view_mode"]
	if settings.get("file_path") is String and _editor != null:
		load_file(settings["file_path"])
	elif is_inside_tree():
		_refresh_view()

func _build_pane_settings_ui(panel: Control) -> Control:
	var v = VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	
	# ── Shared pane controls ──
	var name_le = LineEdit.new()
	name_le.text = pane_name
	name_le.placeholder_text = "Code Viewer"
	name_le.text_changed.connect(func(_s): panel._debounce_timer.start())
	_add_setting_row(v, "Name:", name_le)
	
	var font_spin = SpinBox.new()
	font_spin.min_value = 8; font_spin.max_value = 32
	font_spin.value = font_size
	font_spin.value_changed.connect(func(_v): panel._debounce_timer.start())
	_add_setting_row(v, "Font size:", font_spin)
	
	v.add_child(HSeparator.new())
	
	# ── Code viewer controls ──
	var file_le = LineEdit.new()
	file_le.text = file_path
	file_le.placeholder_text = "/path/to/file"
	file_le.text_changed.connect(func(_s): panel._debounce_timer.start())
	_add_setting_row(v, "File:", file_le)
	
	var lang_opt = OptionButton.new()
	for lang in _langs:
		lang_opt.add_item(lang if lang != "" else "(auto)")
	var sel = maxi(0, _langs.find(language))
	lang_opt.selected = sel
	lang_opt.item_selected.connect(func(_idx): panel._debounce_timer.start())
	_add_setting_row(v, "Language:", lang_opt)

	var view_opt = OptionButton.new()
	for mode in _view_modes:
		view_opt.add_item(mode.capitalize())
	view_opt.selected = maxi(0, _view_modes.find(view_mode))
	view_opt.item_selected.connect(func(_idx): panel._debounce_timer.start())
	_add_setting_row(v, "View:", view_opt)

	panel._gather_func = func():
		return {
			"pane_name": name_le.text.strip_edges(),
			"font_size": int(font_spin.value),
			"file_path": file_le.text.strip_edges(),
			"language": _langs[lang_opt.selected] if lang_opt.selected >= 0 else "",
			"view_mode": _view_modes[view_opt.selected] if view_opt.selected >= 0 else "auto",
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
