extends PaneBody
class_name CodeViewerPane
# Simple read-only code viewer with syntax highlighting.

@export var file_path := ""
@export var language := ""

var _editor: CodeEdit

static var _langs := ["", "gd", "py", "rs", "c", "cpp", "h", "js", "ts"]

func _ready():
	super._ready()
	
	_editor = CodeEdit.new()
	_editor.name = "CodeEdit"
	_editor.editable = false
	_editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_editor)
	_editor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	
	if file_path != "":
		load_file(file_path)

func load_file(path: String):
	if path == "" or not path.is_absolute_path():
		return
	file_path = path
	if not FileAccess.file_exists(path): return
	var f = FileAccess.open(path, FileAccess.READ)
	if not f: return
	var text = f.get_as_text()
	_editor.text = text
	
	# Basic syntax detection from extension
	var ext = path.get_extension().to_lower()
	match ext:
		"gd": _editor.add_comment_string("#")
		"py": _editor.add_comment_string("#")
		"rs": _editor.add_comment_string("//")
		"c", "cpp", "h", "hpp": _editor.add_comment_string("//")


## Receive text content from concept routing (e.g., captured command output).
## Replaces the editor content and scrolls to the top.
func receive_content(text: String):
	_editor.text = text
	_editor.set_caret_line(0)

func _pane_type() -> String:
	return "code_viewer"

func _get_layout_state() -> Dictionary:
	var state = super._get_layout_state()
	state.merge({"file_path": file_path, "language": language})
	return state

func apply_settings(settings: Dictionary):
	super.apply_settings(settings)
	if settings.has("file_path") and settings["file_path"] is String and _editor != null:
		load_file(settings["file_path"])

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
	
	panel._gather_func = func():
		return {
			"pane_name": name_le.text.strip_edges(),
			"font_size": int(font_spin.value),
			"file_path": file_le.text.strip_edges(),
			"language": _langs[lang_opt.selected] if lang_opt.selected >= 0 else "",
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
