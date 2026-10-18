extends PaneBody
class_name FileTreePane
# Simple file tree pane — lists files in a directory and opens them either in
# an in-app code viewer or through the system's default handler.

@export var root_path := "/"
## How an activation opens a file: `viewer` (default) asks the workspace for
## a `code_viewer` pane when `ViewableFiles` supports the path; `system` keeps
## the confirm-then-`OS.shell_open` path for every file. Per-tree rather than
## global: the tree is the origin of the action, and several trees may want
## different behavior. A file the table does not name always stays on the
## system path, because the in-app route is an allowlist, not a sniff.
@export var open_in := "viewer"

const OPEN_MODES: Array[String] = ["viewer", "system"]
const DEFAULT_OPEN_MODE := "viewer"

## Test seam: the one place a path reaches the system's default handler.
## Production leaves it as the OS call; a test replaces it to prove an in-app
## open never touches the system path.
var open_external: Callable = func(uri: String) -> void: OS.shell_open(uri)

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
			_open_activated(path)
		else:
			# `file_exists` is a regular-file check in Godot (false for
			# directories, devices and FIFOs), so this covers everything the
			# tree can list but not hand to a system handler.
			ToastManager.warn("Not a regular file — refusing to open: %s" % path, 4.0, "File Tree")
	)

## Where an activated file goes. A supported text file opens in the viewer by
## default — the pane set already renders it, and the in-app route never hands
## the path to a desktop handler. Every other file (and every file when
## `open_in` is `system`) keeps the existing confirm-then-system path, so a
## binary, an image or a downloaded `.desktop` behaves exactly as before.
func _open_activated(path: String) -> void:
	if not path.is_absolute_path():
		ToastManager.warn("Refusing to open a non-absolute path: %s" % path, 4.0, "File Tree")
		return
	if open_in != "system":
		var viewer := ViewableFiles.viewer_for(path)
		if viewer != "":
			# Panes never spawn panes: the workspace owns the spawn, the
			# same-path focus rule and activation.
			request_pane.emit(viewer, {"file_path": path})
			return
	_confirm_open(path)

## Opening a file hands its path to the desktop's default handler, which is a
## sharper sink than it looks: a downloaded `.desktop` file is *run*, not
## displayed, by the mime handler. Two guards, mirroring `markdown_view`'s
## link policy:
##   1. Scheme allowlist: only an absolute local path is ever turned into a
##      `file://` URI, and that URI is constructed here — a file name cannot
##      contain `/`, so no other scheme can be injected through the tree.
##   2. Confirmation: the user sees the exact path before anything is opened.
const OPEN_SCHEME := "file://"

func _confirm_open(path: String) -> void:
	if not path.is_absolute_path():
		ToastManager.warn("Refusing to open a non-absolute path: %s" % path, 4.0, "File Tree")
		return
	var uri := OPEN_SCHEME + path
	var dialog := ConfirmationDialog.new()
	dialog.title = "Open file"
	dialog.dialog_text = "Open this file with the system's default application?\n\n%s" % path
	dialog.ok_button_text = "Open"
	add_child(dialog)
	dialog.confirmed.connect(func():
		dialog.queue_free()
		open_external.call(uri)
	)
	dialog.canceled.connect(func(): dialog.queue_free())
	dialog.popup_centered()

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
	state.merge({"root_path": root_path, "open_in": open_in})
	return state

func apply_settings(settings: Dictionary):
	super.apply_settings(settings)
	# `open_in` is a closed vocabulary; the base typed setter accepts any
	# string from a saved layout, so the pane re-derives it here. An unknown
	# value falls back to the default rather than leaving neither route
	# authoritative.
	open_in = DEFAULT_OPEN_MODE
	if settings.get("open_in") is String and settings["open_in"] in OPEN_MODES:
		open_in = settings["open_in"]
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

	# The row's labels must stay in `OPEN_MODES` order: the selected index is
	# the stored value.
	var open_opt = OptionButton.new()
	open_opt.add_item("Viewer pane")
	open_opt.add_item("System application")
	open_opt.selected = maxi(0, OPEN_MODES.find(open_in))
	open_opt.item_selected.connect(func(_idx): panel._debounce_timer.start())
	_add_setting_row(v, "Open files:", open_opt)
	
	panel._gather_func = func():
		return {
			"pane_name": name_le.text.strip_edges(),
			"font_size": int(font_spin.value),
			"root_path": root_le.text.strip_edges(),
			"open_in": OPEN_MODES[open_opt.selected] if open_opt.selected >= 0 else DEFAULT_OPEN_MODE,
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
