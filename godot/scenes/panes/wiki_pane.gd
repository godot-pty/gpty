extends PaneBody
class_name WikiPane
## Read-only vault browser: lists a directory's Markdown notes, searches the
## vault's index, and renders one note through the sanitized Markdown pipeline.
##
## `vault_path` is untrusted file input (layout/profile) and is validated at
## use — absolute + existing directory — the same rule `file_tree` applies to
## its root. The pane only reads and renders: no spawn, no write, no handoff to
## the OS. The walk that decides what a note is and the search index behind the
## list live in `gpty_core::vault` (reached through `GptyTerminal.vault_index`
## and `vault_search`), so the pane and the index cannot disagree about which
## files are notes.

@export var vault_path := ""

## Longest path the invalid-vault placeholder shows (it is file-supplied).
const MAX_SHOWN_PATH := 200
## Longest search query the placeholder echoes back.
const MAX_SHOWN_QUERY := 60
## Hits one search asks for (the store clamps to 1..=500).
const SEARCH_LIMIT := 200
## Wait after a keystroke before querying the index.
const SEARCH_DEBOUNCE := 0.15

var _back: Button
var _search: LineEdit
var _list: ItemList
var _reader: MarkdownView
var _placeholder: Label
var _footer: Label
var _search_timer: Timer

func _ready():
	super._ready()

	var root = VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root)

	var top = HBoxContainer.new()
	top.name = "TopRow"
	root.add_child(top)

	_back = Button.new()
	_back.name = "BackToNotes"
	_back.text = "Back to notes"
	_back.focus_mode = Control.FOCUS_NONE
	_back.pressed.connect(_show_list)
	top.add_child(_back)

	_search = LineEdit.new()
	_search.name = "Search"
	_search.placeholder_text = "Search notes"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(func(_text): _search_timer.start())
	_search.text_submitted.connect(func(_text): _run_search())
	top.add_child(_search)

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

	_search_timer = Timer.new()
	_search_timer.one_shot = true
	_search_timer.wait_time = SEARCH_DEBOUNCE
	_search_timer.timeout.connect(_run_search)
	add_child(_search_timer)

	# The spawn/restore apply_settings call runs before the node enters the
	# tree, so the initial index pass belongs here (code_viewer's pattern).
	_refresh()

## The view state machine: exactly one of {note list, rendered note,
## placeholder} is visible, and the back button only while reading a note.
## The list comes from the vault index — `vault_index` walks the vault, brings
## the index up to date and answers the list in one call.
func _refresh():
	_back.visible = false
	_reader.visible = false
	_footer.visible = false
	_list.clear()
	var problem := _vault_problem()
	if problem != "":
		_show_placeholder(problem)
		return
	_search.visible = true
	if _search.text.strip_edges() != "":
		_run_search()
		return
	var answer = JSON.parse_string(str(GptyTerminal.vault_index(vault_path)))
	if not (answer is Dictionary):
		_show_placeholder("Vault index unavailable.")
		return
	if answer.has("error"):
		_show_placeholder("Vault index failed: " + _shown_path(str(answer["error"])))
		return
	for note in answer.get("notes", []):
		if note is String:
			var idx := _list.add_item(note)
			_list.set_item_metadata(idx, vault_path.path_join(note))
	if _list.item_count == 0:
		_show_placeholder("No Markdown notes in this vault.")
		return
	_placeholder.visible = false
	_list.visible = true
	if answer.get("truncated", false):
		_footer.text = "… listing stopped; this vault has more notes than the pane lists."
		_footer.visible = true

## Query the index for the search box's text and show matching notes.
## Empty text falls back to the plain note list.
func _run_search() -> void:
	if _list == null or _vault_problem() != "":
		return
	var query := _search.text.strip_edges()
	if query == "":
		_refresh()
		return
	var answer = JSON.parse_string(str(GptyTerminal.vault_search(vault_path, query, SEARCH_LIMIT)))
	_list.clear()
	_footer.visible = false
	_reader.visible = false
	_back.visible = false
	if not (answer is Dictionary):
		_show_placeholder("Vault search unavailable.")
		return
	if answer.has("error"):
		_show_placeholder("Vault search failed: " + _shown_path(str(answer["error"])))
		return
	for hit in answer.get("results", []):
		if not (hit is Dictionary):
			continue
		var rel := str(hit.get("path", ""))
		if rel == "":
			continue
		var title := str(hit.get("title", rel))
		var snippet := str(hit.get("snippet", ""))
		var idx := _list.add_item("%s — %s" % [title, snippet] if snippet != "" else title)
		_list.set_item_metadata(idx, vault_path.path_join(rel))
		_list.set_item_tooltip(idx, rel)
	if _list.item_count == 0:
		_show_placeholder("No notes match \"%s\"." % query.left(MAX_SHOWN_QUERY))
		return
	_placeholder.visible = false
	_list.visible = true

func _show_placeholder(text: String) -> void:
	_placeholder.text = text
	_placeholder.visible = true
	_list.visible = false
	if _search != null:
		_search.visible = false

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

func _on_note_activated(index: int) -> void:
	_open_note(str(_list.get_item_metadata(index)))

func _open_note(abs_path: String) -> void:
	var r := TextRead.read_prefix(abs_path)
	if not r.ok:
		# The path came from a just-completed walk or search; a failure here
		# means the note moved between the two.
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
		# A different vault makes the old query meaningless.
		_search.text = ""
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
