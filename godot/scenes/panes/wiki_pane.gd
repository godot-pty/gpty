extends PaneBody
class_name WikiPane
## Read-only vault browser: lists a directory's Markdown notes and renders one
## through the sanitized Markdown pipeline.
##
## `vault_path` is untrusted file input (layout/profile) and is validated at
## use — absolute + existing directory — the same rule `file_tree` applies to
## its root. The pane only reads and renders: no spawn, no write, no handoff to
## the OS.

@export var vault_path := ""

## Bounds for the eager scan. The walk runs on the GUI thread (file_tree walks
## lazily per expand; this pane scans the whole vault at once), so it is capped
## in entries and depth. The depth cap also stops a symlinked-directory loop.
const MAX_NOTES := 2000
const MAX_DEPTH := 16
## Longest path the invalid-vault placeholder shows (it is file-supplied).
const MAX_SHOWN_PATH := 200

var _back: Button
var _list: ItemList
var _reader: MarkdownView
var _placeholder: Label
var _footer: Label

func _ready():
	super._ready()

	var root = VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root)

	_back = Button.new()
	_back.name = "BackToNotes"
	_back.text = "Back to notes"
	_back.focus_mode = Control.FOCUS_NONE
	_back.pressed.connect(_show_list)
	root.add_child(_back)

	var content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(content)

	_list = ItemList.new()
	_list.name = "NoteList"
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_activated.connect(_on_note_activated)
	content.add_child(_list)

	_footer = Label.new()
	_footer.name = "ListFooter"
	_footer.visible = false
	content.add_child(_footer)

	_reader = MarkdownView.new()
	_reader.name = "MarkdownView"
	_reader.visible = false
	_reader.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reader.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_reader.add_theme_font_size_override("normal_font_size", font_size)
	_reader.add_theme_font_size_override("mono_font_size", font_size)
	content.add_child(_reader)

	_placeholder = Label.new()
	_placeholder.name = "Placeholder"
	_placeholder.visible = false
	_placeholder.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_placeholder.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_placeholder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_placeholder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_placeholder)

	# The spawn/restore apply_settings call runs before the node enters the
	# tree, so the initial scan belongs here (code_viewer's pattern).
	_refresh()

## The vault state machine: exactly one of {note list, rendered note,
## placeholder} is visible, and the back button only while reading a note.
func _refresh():
	_back.visible = false
	_reader.visible = false
	_footer.visible = false
	_list.clear()
	var problem := _vault_problem()
	if problem != "":
		_show_placeholder(problem)
		return
	var scan := _scan_vault()
	var notes: Array = scan["notes"]
	if notes.is_empty():
		_show_placeholder("No Markdown notes in this vault.")
		return
	for note in notes:
		var idx := _list.add_item(note)
		_list.set_item_metadata(idx, vault_path.path_join(note))
	_placeholder.visible = false
	_list.visible = true
	if scan["truncated"]:
		_footer.text = "… listing stopped at %d notes." % MAX_NOTES
		_footer.visible = true

func _show_placeholder(text: String) -> void:
	_placeholder.text = text
	_placeholder.visible = true
	_list.visible = false

func _show_list() -> void:
	_reader.visible = false
	_back.visible = false
	_list.visible = true

## Why `vault_path` cannot be opened, or "" when it can.
func _vault_problem() -> String:
	if vault_path == "":
		return "No vault selected — set a vault path in the pane settings."
	if not vault_path.is_absolute_path() or not DirAccess.dir_exists_absolute(vault_path):
		return "Not a vault directory: " + _shown_path(vault_path)
	return ""

func _shown_path(path: String) -> String:
	return path if path.length() <= MAX_SHOWN_PATH else path.left(MAX_SHOWN_PATH) + "…"

## The vault's Markdown notes, relative paths, sorted.
## `{"notes": Array[String], "truncated": bool}` — `truncated` when the walk
## hit `limit` with a note still to list.
func _scan_vault(limit: int = MAX_NOTES) -> Dictionary:
	var state := {"notes": [], "truncated": false}
	if vault_path == "" or not vault_path.is_absolute_path() or not DirAccess.dir_exists_absolute(vault_path):
		return state
	_scan_dir(vault_path, "", 0, limit, state)
	state["notes"].sort()
	return state

func _scan_dir(abs_dir: String, rel: String, depth: int, limit: int, state: Dictionary) -> void:
	if state["truncated"] or depth > MAX_DEPTH:
		return
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return
	# Hidden entries are skipped at every level (`.obsidian`, `.git`, `.trash`).
	for file_name in dir.get_files():
		if not (file_name is String):
			continue
		if file_name.begins_with(".") or file_name.get_extension().to_lower() != "md":
			continue
		if state["notes"].size() >= limit:
			state["truncated"] = true
			return
		state["notes"].append(rel.path_join(file_name) if rel != "" else file_name)
	for dir_name in dir.get_directories():
		if not (dir_name is String) or dir_name.begins_with("."):
			continue
		var child_rel := rel.path_join(dir_name) if rel != "" else dir_name
		_scan_dir(abs_dir.path_join(dir_name), child_rel, depth + 1, limit, state)

func _on_note_activated(index: int) -> void:
	_open_note(str(_list.get_item_metadata(index)))

func _open_note(abs_path: String) -> void:
	var r := TextRead.read_prefix(abs_path)
	if not r.ok:
		# The path came from a just-completed scan; a failure here means the
		# note moved between the scan and the click.
		ToastManager.warn("Could not read note: %s" % abs_path, 4.0, "Wiki")
		return
	var text: String = r.text
	if r.truncated:
		text += TextRead.truncation_notice(TextRead.DEFAULT_MAX_BYTES, r.size)
	_reader.render_now(text)
	_reader.scroll_to_line(0)
	_list.visible = false
	_footer.visible = false
	_placeholder.visible = false
	_reader.visible = true
	_back.visible = true

func apply_settings(settings: Dictionary):
	super.apply_settings(settings)
	# The base assigned `vault_path` (its name is the settings key); re-scan
	# rather than reassign, so a half-typed path stays in the settings field.
	if is_inside_tree():
		_refresh()

func _get_layout_state() -> Dictionary:
	var state = super._get_layout_state()
	state.merge({"vault_path": vault_path})
	return state

func _pane_type() -> String:
	return "wiki"

func _build_pane_settings_ui(panel: Control) -> Control:
	var v = VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)

	# ── Shared pane controls ──
	var name_le = LineEdit.new()
	name_le.text = pane_name
	name_le.placeholder_text = "Wiki"
	name_le.text_changed.connect(func(_s): panel._debounce_timer.start())
	_add_setting_row(v, "Name:", name_le)

	var font_spin = SpinBox.new()
	font_spin.min_value = 8; font_spin.max_value = 32
	font_spin.value = font_size
	font_spin.value_changed.connect(func(_v): panel._debounce_timer.start())
	_add_setting_row(v, "Font size:", font_spin)

	v.add_child(HSeparator.new())

	# ── Vault controls ──
	var vault_le = LineEdit.new()
	vault_le.text = vault_path
	vault_le.placeholder_text = "/path/to/vault"
	vault_le.text_changed.connect(func(_s): panel._debounce_timer.start())
	_add_setting_row(v, "Vault path:", vault_le)

	panel._gather_func = func():
		return {
			"pane_name": name_le.text.strip_edges(),
			"font_size": int(font_spin.value),
			"vault_path": vault_le.text.strip_edges(),
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
