extends PaneBody
class_name FileTreePane
# Simple file tree pane — lists files in a directory and opens them in an
# in-app viewer (text via `code_viewer`, local media via `media`) or through
# the system's default handler.

@export var root_path := "/"
## How an activation opens a file: `viewer` (default) asks the workspace for
## a `code_viewer` pane when `ViewableFiles` supports the path; `system` keeps
## the confirm-then-system-handler path for every file. Per-tree rather than
## global: the tree is the origin of the action, and several trees may want
## different behavior. A file the table does not name always stays on the
## system path, because the in-app route is an allowlist, not a sniff.
@export var open_in := "viewer"

const OPEN_MODES: Array[String] = ["viewer", "system"]
const DEFAULT_OPEN_MODE := "viewer"

## Test seam: the one place this pane opens a folder for listing. Production
## leaves it as Godot's own static; a test replaces it to reach the gate a
## folder's permissions normally close (a path that exists but cannot be
## listed) without depending on the suite's privileges.
var open_dir: Callable = func(path: String) -> DirAccess: return DirAccess.open(path)

var _tree: Tree
## The pane's "nothing to show" surface and its two lines, rewritten per root
## state (the media pane's `_placeholder*` pattern). The tree and this surface
## are siblings at the full rect; exactly one of them is visible.
var _empty_host: Control
var _empty_title: Label
var _empty_hint: Label

func _ready():
	super._ready()
	
	_tree = Tree.new()
	_tree.name = "FileTree"
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_tree)
	_tree.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	
	var empty := PaneBody.empty_state(
		self,
		str(PaneTypes.ALL.get("file_tree", {}).get("icon", "/>")),
		"", "", font_size)
	_empty_host = empty["host"] as Control
	_empty_host.name = "EmptyState"
	_empty_title = empty["title"] as Label
	_empty_hint = empty["hint"] as Label

	_refresh_root()
	
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
			# Only fold what has rows: a folder that cannot be listed has
			# already toasted its reason, and an empty one has nothing to show
			# either way.
			if item.get_child_count() > 0:
				item.collapsed = not item.collapsed
		elif FileAccess.file_exists(path):
			_open_activated(path)
		else:
			# `file_exists` is a regular-file check in Godot (false for
			# directories, devices and FIFOs), so this covers everything the
			# tree can list but not hand to a system handler.
			ToastManager.warn("Not a regular file — refusing to open: %s" % path, 4.0, "File Tree")
	)

## Where an activated file goes. A supported text file opens in the code
## viewer and a supported local media file in the media pane — the pane set
## already renders or plays them, and the in-app route never hands the path to
## a desktop handler. Every other file (and every file when `open_in` is
## `system`) keeps the existing confirm-then-system path, so a binary, an image
## or a downloaded `.desktop` behaves exactly as before.
func _open_activated(path: String) -> void:
	if not BasePersistenceManager.is_real_absolute_path(path):
		ToastManager.warn("Refusing to open a non-filesystem path: %s" % path, 4.0, "File Tree")
		return
	if open_in != "system":
		var viewer := ViewableFiles.viewer_for(path)
		if viewer != "":
			# Panes never spawn panes: the workspace owns the spawn, the
			# same-path focus rule and activation.
			request_pane.emit(viewer, {"file_path": path})
			return
		var media := MediaFiles.pane_for(path)
		if media != "":
			request_pane.emit(media, {"file_path": path})
			return
	_confirm_open(path)

## Opening a file hands its path to the desktop's default handler, which is a
## sharper sink than it looks: a downloaded `.desktop` file is *run*, not
## displayed, by the mime handler. Three guards, mirroring `markdown_view`'s
## link policy:
##   1. Scheme allowlist: only an absolute local path is ever turned into a
##      `file://` URI, and that URI is constructed here — a file name cannot
##      contain `/`, so no other scheme can be injected through the tree.
##   2. Confirmation: the user sees the exact path before anything is opened.
##   3. Reporting: the handoff is `ExternalLink.open`, so a handler that
##      refuses the URI copies it and raises a WARN toast instead of nothing.
const OPEN_SCHEME := "file://"

func _confirm_open(path: String) -> void:
	if not BasePersistenceManager.is_real_absolute_path(path):
		ToastManager.warn("Refusing to open a non-filesystem path: %s" % path, 4.0, "File Tree")
		return
	var uri := OPEN_SCHEME + path
	var dialog := AppDialog.confirm(self, "Open file", "Open")
	AppDialog.set_body(dialog, "Open this file with the system's default application?\n\n%s" % path)
	dialog.confirmed.connect(func():
		dialog.queue_free()
		# The one outbound path: a system with no handler for the type answers
		# with an `Error` there, which copies the URI and warns instead of
		# leaving a dead press.
		ExternalLink.open(uri, "", ExternalLink.refused_file_message(uri), "File Tree")
	)
	dialog.canceled.connect(func(): dialog.queue_free())
	dialog.popup_centered()

## The one gate for a folder this pane is asked to list: `{dir, problem}`.
## `dir` is null exactly when `problem` says why; `{}` means the folder opened
## (it may still be empty). Each state is separate because each has a different
## fix, and each hint names the path and the field that fixes it.
static func open_for_listing(path: String, opener: Callable) -> Dictionary:
	if not BasePersistenceManager.is_real_absolute_path(path):
		return {"dir": null, "problem": no_folder_problem(path)}
	if not DirAccess.dir_exists_absolute(path):
		if FileAccess.file_exists(path):
			return {"dir": null, "problem": not_a_folder_problem(path)}
		return {"dir": null, "problem": missing_folder_problem(path)}
	var dir: DirAccess = opener.call(path)
	if dir == null:
		return {"dir": null, "problem": unlistable_folder_problem(path)}
	return {"dir": dir, "problem": {}}

static func no_folder_problem(path: String) -> Dictionary:
	if path == "":
		return {"title": "No folder open",
			"hint": "Set an absolute folder path in pane settings."}
	return {"title": "No folder open",
		"hint": "Not an absolute folder path: %s — set one in pane settings." % path}

static func not_a_folder_problem(path: String) -> Dictionary:
	return {"title": "Not a folder",
		"hint": "%s is a file — choose the folder that contains it." % path}

static func missing_folder_problem(path: String) -> Dictionary:
	return {"title": "Folder not found",
		"hint": "%s does not exist on this machine — fix the path in pane settings." % path}

static func unlistable_folder_problem(path: String) -> Dictionary:
	return {"title": "Cannot list this folder",
		"hint": "%s exists but cannot be read — check its permissions." % path}

static func empty_folder_problem(path: String) -> Dictionary:
	return {"title": "This folder is empty",
		"hint": "%s holds no entries — hidden files are not listed." % path}

## Add one row per non-hidden entry of the open `dir` under `parent`, naming
## children from the path the folder was opened with. Returns how many rows
## were added (0 means the folder holds no entries).
func _fill(parent: TreeItem, dir: DirAccess, path: String) -> int:
	var count := 0
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name.begins_with("."):
			file_name = dir.get_next()
			continue
		var item = _tree.create_item(parent)
		item.set_text(0, file_name)
		item.set_metadata(0, path.path_join(file_name))
		count += 1
		file_name = dir.get_next()
	dir.list_dir_end()
	return count

## List a directory's children on first expand. The root has the pane's own
## surface for a folder it cannot read; a nested folder has only a toast, so it
## says so there instead of staying silently blank.
func _populate(parent: TreeItem, path: String) -> void:
	var listed := open_for_listing(path, open_dir)
	var problem: Dictionary = listed.problem
	if not problem.is_empty():
		ToastManager.warn("%s — %s" % [problem["title"], problem["hint"]], 5.0, "File Tree")
		return
	var dir: DirAccess = listed.dir
	_fill(parent, dir, path)

## Rebuild the pane from `root_path`, or say why it cannot be listed: the
## surface is either the folder's rows or the one sentence that explains their
## absence. An empty list with no reason is the defect this replaced.
func _refresh_root() -> void:
	_tree.clear()
	var root := _tree.create_item()
	var listed := open_for_listing(root_path, open_dir)
	var problem: Dictionary = listed.problem
	if problem.is_empty():
		var dir: DirAccess = listed.dir
		if _fill(root, dir, root_path) == 0:
			problem = empty_folder_problem(root_path)
	_tree.visible = problem.is_empty()
	_empty_host.visible = not problem.is_empty()
	if not problem.is_empty():
		_empty_title.text = problem["title"]
		_empty_hint.text = problem["hint"]

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
		_refresh_root()

func _build_pane_settings_ui(panel: Control) -> Control:
	var v = VBoxContainer.new()
	v.add_theme_constant_override("separation", UiTokens.SPACE_MD)
	
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
	hb.add_child(lbl)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(control)
	parent.add_child(hb)
