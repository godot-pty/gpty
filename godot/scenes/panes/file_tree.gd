extends PaneBody
class_name FileTreePane
# Simple file tree pane — lists files in a directory.

@export var root_path := "/"

var _tree: Tree

func _ready():
	super._ready()
	
	_tree = Tree.new()
	_tree.name = "FileTree"
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_tree)
	_tree.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	
	_tree.create_item()
	_populate(_tree.get_root(), root_path)
	
	_tree.item_activated.connect(func():
		var item = _tree.get_selected()
		if not item:
			return
		var path = item.get_metadata(0)
		if not path:
			return
		if DirAccess.dir_exists_absolute(path):
			# Lazy-load children on first expand
			if item.get_child_count() == 0:
				_populate(item, path)
			item.collapsed = not item.collapsed
		elif FileAccess.file_exists(path):
			OS.shell_open("file://" + path)
	)

func _populate(parent: TreeItem, path: String):
	if path == "" or not path.is_absolute_path() or not DirAccess.dir_exists_absolute(path):
		return
	var dir = DirAccess.open(path)
	if not dir: return
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name.begins_with("."):
			file_name = dir.get_next()
			continue
		var item = _tree.create_item(parent)
		item.set_text(0, file_name)
		var full = path.path_join(file_name)
		item.set_metadata(0, full)
		file_name = dir.get_next()
	dir.list_dir_end()

func _pane_type() -> String:
	return "file_tree"

func _get_layout_state() -> Dictionary:
	var state = super._get_layout_state()
	state.merge({"root_path": root_path})
	return state

func apply_settings(settings: Dictionary):
	super.apply_settings(settings)
	if settings.has("root_path") and settings["root_path"] is String and _tree != null:
		_tree.clear()
		_tree.create_item()
		_populate(_tree.get_root(), settings["root_path"])

func _build_pane_settings_ui(panel: Control) -> Control:
	var v = VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	
	# ── Shared pane controls ──
	var name_le = LineEdit.new()
	name_le.text = pane_name
	name_le.placeholder_text = "File Tree"
	name_le.text_changed.connect(func(_s): panel._debounce_timer.start())
	_add_setting_row(v, "Name:", name_le)
	
	var font_spin = SpinBox.new()
	font_spin.min_value = 8; font_spin.max_value = 32
	font_spin.value = font_size
	font_spin.value_changed.connect(func(_v): panel._debounce_timer.start())
	_add_setting_row(v, "Font size:", font_spin)
	
	v.add_child(HSeparator.new())
	
	# ── File tree controls ──
	var root_le = LineEdit.new()
	root_le.text = root_path
	root_le.placeholder_text = "/path/to/dir"
	root_le.text_changed.connect(func(_s): panel._debounce_timer.start())
	_add_setting_row(v, "Root path:", root_le)
	
	panel._gather_func = func():
		return {
			"pane_name": name_le.text.strip_edges(),
			"font_size": int(font_spin.value),
			"root_path": root_le.text.strip_edges(),
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
