extends PaneBody
class_name WikiPane
## Vault browser and note editor: lists a directory's Markdown notes, searches
## the vault's index, renders a note through the sanitized Markdown pipeline,
## and edits it — live preview, explicit save.
##
## `vault_path` is untrusted file input (layout/profile) and is validated at
## use — absolute + existing directory — the same rule `file_tree` applies to
## its root. Nothing writes on its own: `_save` is the only caller of
## `GptyTerminal.vault_note_write`, it runs on an explicit Save (button or
## Ctrl+S), and the Rust side refuses any path that leaves the vault. The walk
## that decides what a note is, the search index, and the write rules live in
## `gpty_core::vault` (reached through `GptyTerminal.vault_index`,
## `vault_search`, `vault_note_read`, `vault_note_write`), so the pane and the
## index cannot disagree about which files are notes.

@export var vault_path := ""
## Note view: `edit` (source only) | `split` (source + live preview) |
## `preview` (rendered only). Split is what makes the preview live.
@export var view_mode := "split"

## Longest path the invalid-vault placeholder shows (it is file-supplied).
const MAX_SHOWN_PATH := 200
## Longest search query the placeholder echoes back.
const MAX_SHOWN_QUERY := 60
## Hits one search asks for (the store clamps to 1..=500).
const SEARCH_LIMIT := 200
## Wait after a keystroke before querying the index.
const SEARCH_DEBOUNCE := 0.15
## The note view's modes, in toolbar order.
const VIEW_MODES := ["edit", "split", "preview"]

var _back: Button
var _search: LineEdit
var _list: ItemList
var _note_box: VBoxContainer
var _note_title: Label
var _editor: CodeEdit
var _reader: MarkdownView
var _save_button: Button
var _dirty_label: Label
var _mode_buttons: Dictionary = {}
var _placeholder: Label
var _footer: Label
var _search_timer: Timer

## The open note: its vault-relative path (the index's spelling), the text as
## loaded — what "dirty" is measured against — and the stamp the save checks.
var _current_rel := ""
var _saved_text := ""
var _loaded_mtime := 0
var _loaded_size := 0
## The file uses CRLF endings; the editor works in LF and `_payload` puts them
## back on save (a one-word edit must not rewrite every line).
var _crlf := false
## False when the load hit the 1 MiB cap: a save would replace the whole file
## with its first MiB, so that note is shown read-only.
var _editable_note := false

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
	_back.pressed.connect(func(): _request_leave(func(proceed: bool):
		if proceed:
			_show_list()
	))
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

	# ── The note view: toolbar, then source | live preview ──
	_note_box = VBoxContainer.new()
	_note_box.name = "NoteView"
	_note_box.visible = false
	_note_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_note_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_note_box)

	var toolbar = HBoxContainer.new()
	toolbar.name = "NoteToolbar"
	_note_box.add_child(toolbar)

	_note_title = Label.new()
	_note_title.name = "NoteTitle"
	_note_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_note_title.clip_text = true
	_note_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_note_title.add_theme_font_size_override("font_size", 12)
	toolbar.add_child(_note_title)

	var group := ButtonGroup.new()
	for mode in VIEW_MODES:
		var button := Button.new()
		button.name = "Mode_" + mode
		button.text = mode.capitalize()
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.button_group = group
		button.tooltip_text = {
			"edit": "Source only (Ctrl+S saves)",
			"split": "Source and live preview",
			"preview": "Rendered Markdown only",
		}.get(mode, "")
		button.toggled.connect(func(on):
			if on:
				_set_view_mode(mode)
		)
		toolbar.add_child(button)
		_mode_buttons[mode] = button

	_dirty_label = Label.new()
	_dirty_label.name = "DirtyState"
	_dirty_label.visible = false
	_dirty_label.add_theme_font_size_override("font_size", 12)
	toolbar.add_child(_dirty_label)

	_save_button = Button.new()
	_save_button.name = "Save"
	_save_button.text = "Save"
	_save_button.focus_mode = Control.FOCUS_NONE
	_save_button.tooltip_text = "Write the note back to disk (Ctrl+S)"
	_save_button.pressed.connect(func(): _save())
	toolbar.add_child(_save_button)

	var split := HSplitContainer.new()
	split.name = "NoteSplit"
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_note_box.add_child(split)

	_editor = CodeEdit.new()
	_editor.name = "Editor"
	_editor.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_editor.placeholder_text = "Write Markdown…"
	_editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_editor.text_changed.connect(_on_editor_changed)
	_editor.gui_input.connect(_on_editor_input)
	split.add_child(_editor)

	_reader = MarkdownView.new()
	_reader.name = "MarkdownView"
	_reader.visible = false
	_reader.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reader.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(_reader)

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

	_apply_font_size()

	# The spawn/restore apply_settings call runs before the node enters the
	# tree, so the initial index pass belongs here (code_viewer's pattern).
	_refresh()

## The editor and the preview share the pane's font size, which the settings
## panel can change after `_ready`.
func _apply_font_size() -> void:
	if _editor == null:
		return
	_editor.add_theme_font_size_override("font_size", font_size)
	_reader.add_theme_font_size_override("normal_font_size", font_size)
	_reader.add_theme_font_size_override("mono_font_size", font_size)

## The view state machine: exactly one of {note list, note editor,
## placeholder} is visible, and the back button only while a note is open.
## The list comes from the vault index — `vault_index` walks the vault, brings
## the index up to date and answers the list in one call.
func _refresh():
	_clear_note()
	_back.visible = false
	_note_box.visible = false
	_footer.visible = false
	_list.clear()
	var problem := _vault_problem()
	if problem != "":
		_show_placeholder(problem, false)
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
			# The metadata is the vault-relative path (the index's own
			# spelling): what `_open_note` reads and `_save` writes.
			var idx := _list.add_item(note)
			_list.set_item_metadata(idx, note)
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
	if _list == null or _note_box.visible or _vault_problem() != "":
		return
	var query := _search.text.strip_edges()
	if query == "":
		_refresh()
		return
	var answer = JSON.parse_string(str(GptyTerminal.vault_search(vault_path, query, SEARCH_LIMIT)))
	_clear_note()
	_list.clear()
	_footer.visible = false
	_note_box.visible = false
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
		_list.set_item_metadata(idx, rel)
		_list.set_item_tooltip(idx, rel)
	if _list.item_count == 0:
		_show_placeholder("No notes match \"%s\"." % query.left(MAX_SHOWN_QUERY))
		return
	_placeholder.visible = false
	_list.visible = true

## Replace the content area with a message. `searchable` says whether the
## search box stays in the top row: a query can be amended and cleared (a
## zero-hit search must not strand the pane with no way back to the notes),
## while a vault that cannot be opened has nothing to search at all.
func _show_placeholder(text: String, searchable := true) -> void:
	_placeholder.text = text
	_placeholder.visible = true
	_list.visible = false
	_note_box.visible = false
	_back.visible = false
	_search.visible = searchable

## Leave the note and show the list. The Back button routes through
## `_request_leave`, so an unsaved note asks first; `_refresh` is the
## unguarded action that runs once the user has answered — it re-walks the
## vault, so the list also reflects an edit that just landed.
func _show_list() -> void:
	_refresh()

## Forget the open note. Only drops state — saving before leaving is
## `_request_leave`'s business — so a stale path can never be written by a
## later save.
func _clear_note() -> void:
	if _editor != null:
		_editor.text = ""
		_editor.editable = false
		# The note view's own flags go with the state: a caller that hides
		# `_note_box` must not leave a child claiming to be visible.
		_editor.visible = false
		_reader.visible = false
	_current_rel = ""
	_saved_text = ""
	_loaded_mtime = 0
	_loaded_size = 0
	_crlf = false
	_editable_note = false

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

## Load a note — the list's vault-relative path — into the editor and the
## preview. The read comes from the vault module, so the editor holds exactly
## what the index holds, and the file's own shape (CRLF endings, the 1 MiB
## cut) is applied to what the user can do with it.
func _open_note(rel: String) -> void:
	var answer = JSON.parse_string(str(GptyTerminal.vault_note_read(vault_path, rel)))
	if not (answer is Dictionary) or answer.has("error"):
		# The path came from a just-completed walk or search; a failure here
		# means the note moved or was replaced between the two.
		var why := str(answer["error"]) if answer is Dictionary and answer.has("error") else "unreadable"
		ToastManager.warn("Could not open note: " + why, 4.0, "Wiki")
		return
	_current_rel = rel
	_saved_text = str(answer.get("text", ""))
	_loaded_mtime = int(answer.get("mtime", 0))
	_loaded_size = int(answer.get("size", 0))
	_crlf = bool(answer.get("crlf", false))
	# A truncated read is a prefix; editing it and saving would drop the rest
	# of the file, so that note stays read-only.
	_editable_note = not bool(answer.get("truncated", false))
	# The editor works in LF; `_payload` puts the CRLFs back on save. (Setting
	# `text` reaches `_on_editor_changed` a frame later, like every TextEdit
	# change — harmless, because that handler recomputes the state instead of
	# trusting the signal.)
	_editor.text = _saved_text.replace("\r\n", "\n") if _crlf else _saved_text
	_editor.editable = _editable_note
	_editor.scroll_vertical = 0
	_note_title.text = rel
	_note_title.tooltip_text = rel
	_list.visible = false
	_footer.visible = false
	_placeholder.visible = false
	_search.visible = false
	_note_box.visible = true
	_back.visible = true
	_apply_view_mode()
	_update_dirty()
	_reader.scroll_to_line(0)

## Show the mode's views and keep the toolbar's buttons on the active one.
func _apply_view_mode() -> void:
	if not _note_box.visible:
		_editor.visible = false
		_reader.visible = false
		return
	var editing := view_mode != "preview"
	var preview := view_mode != "edit"
	_editor.visible = editing
	_reader.visible = preview
	for mode in _mode_buttons:
		_mode_buttons[mode].button_pressed = (mode == view_mode)
	if preview:
		_reader.render_now(_preview_text())
		_reader.scroll_to_line(0)

func _set_view_mode(mode: String) -> void:
	if not (mode in VIEW_MODES) or mode == view_mode:
		return
	view_mode = mode
	_apply_view_mode()

## Whether the preview is on screen — rendering into a hidden node is work
## nobody sees.
func _preview_visible() -> bool:
	return _note_box.visible and _reader.visible

## What the preview renders: the buffer, not the file (that is what makes it a
## live preview), plus the one truncation notice when the file was cut.
func _preview_text() -> String:
	var text := _editor.text
	if _current_rel != "" and not _editable_note:
		text += TextRead.truncation_notice(TextRead.DEFAULT_MAX_BYTES, _loaded_size)
	return text

## A TextEdit change — user typing or a programmatic `text` assignment; the
## signal arrives one frame after the edit, so this recomputes from the
## current buffer rather than trusting the signal's timing.
func _on_editor_changed() -> void:
	_update_dirty()
	if _preview_visible():
		_reader.set_markdown(_preview_text())

## Ctrl+S saves, the same as the button — an editor that only saves by mouse
## is a trap for anyone who lives on the keyboard.
func _on_editor_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.ctrl_pressed and not event.shift_pressed and event.keycode == KEY_S:
		_editor.accept_event()
		_save()

## Whether the buffer differs from what was loaded.
func _is_dirty() -> bool:
	return _editable_note and _editor.text != _saved_text

func _update_dirty() -> void:
	if not _editable_note:
		# A truncated note is the one read-only case the user must understand:
		# the pane holds a prefix of the file.
		_dirty_label.text = "Read-only — larger than %s" % String.humanize_size(TextRead.DEFAULT_MAX_BYTES)
		_dirty_label.visible = _note_box.visible and _current_rel != ""
		_save_button.disabled = true
		return
	var dirty := _is_dirty()
	_dirty_label.text = "● Unsaved changes"
	_dirty_label.visible = dirty
	_save_button.disabled = not dirty

## The buffer as it goes to disk: the editor's LF line endings converted back
## to the file's CRLF when it had them.
func _payload() -> String:
	return _editor.text.replace("\n", "\r\n") if _crlf else _editor.text

## Write the open note back. `answer` (optional) hears the outcome when a save
## is what lets something else proceed — leaving the note, closing the pane,
## quitting: `true` once the write landed, `false` when it did not (a conflict
## the user cancels, an I/O failure), so the caller can cancel its own action
## instead of proceeding over a failed write.
func _save(force := false, answer := Callable()) -> void:
	if _current_rel == "" or not _editable_note:
		if answer.is_valid():
			answer.call(false)
		return
	var reply = JSON.parse_string(str(GptyTerminal.vault_note_write(
		vault_path, _current_rel, _payload(), _loaded_mtime, _loaded_size, force
	)))
	if not (reply is Dictionary):
		ToastManager.warn("Could not save %s: no answer from the vault" % _current_rel, 5.0, "Wiki")
		if answer.is_valid():
			answer.call(false)
		return
	if reply.has("error"):
		if str(reply.get("code", "")) == "changed_on_disk" and not force:
			_ask_overwrite(answer)
			return
		ToastManager.warn("Could not save %s: %s" % [_current_rel, str(reply["error"])], 5.0, "Wiki")
		if answer.is_valid():
			answer.call(false)
		return
	_saved_text = _editor.text
	_loaded_mtime = int(reply.get("mtime", 0))
	_loaded_size = int(reply.get("size", 0))
	_update_dirty()
	if not bool(reply.get("indexed", true)):
		ToastManager.warn("Saved %s, but the search index could not be updated" % _current_rel, 5.0, "Wiki")
	if answer.is_valid():
		answer.call(true)

## The note changed on disk since it was opened (another editor, a git
## checkout): overwriting it is the user's call, never the pane's. `answer`
## hears `false` when the overwrite is declined, so a close behind this save
## is cancelled rather than left waiting.
func _ask_overwrite(answer := Callable()) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.name = "OverwriteConfirm"
	dialog.title = "Note changed on disk"
	dialog.dialog_text = "%s changed on disk since it was opened.\n\nOverwrite it with your version?" % _current_rel
	dialog.ok_button_text = "Overwrite"
	add_child(dialog)
	dialog.confirmed.connect(func(): _save_after_dialog(dialog, answer, true))
	dialog.canceled.connect(func():
		dialog.queue_free()
		if answer.is_valid():
			answer.call(false)
	)
	dialog.popup_centered()

## Run the save once `dialog` is really gone. An exclusive child window
## outlives `queue_free` by a frame, and Godot refuses a second exclusive
## dialog while one is still registered — the overwrite question would never
## appear, and the answer behind it would never come. Shared by both dialogs
## that end in a save: the discard ask (whose save may then raise the
## overwrite question) and that overwrite question itself (`force`, so the
## confirmed overwrite does not ask again).
func _save_after_dialog(dialog: Window, answer: Callable, force := false) -> void:
	dialog.queue_free()
	await get_tree().process_frame
	_save(force, answer)

## Ask before the buffer is lost. Every path that would end its life comes
## here — leaving the note, a pane close, a layout reset, quitting the app —
## and the answers are the editor convention: Save (write it, then continue),
## Discard (continue without it), Cancel (nothing happens, the pane stays as
## it is). A clean buffer just continues, and the pane never writes on its own.
func _request_leave(answer: Callable) -> void:
	if not _is_dirty():
		answer.call(true)
		return
	# One question at a time: a second ask while this pane is already asking
	# (a close request during a pending discard, a quit during the overwrite
	# dialog) is declined, so the dialogs cannot stack.
	if _has_open_ask():
		answer.call(false)
		return
	var dialog := ConfirmationDialog.new()
	dialog.name = "DiscardConfirm"
	dialog.title = "Unsaved changes"
	dialog.dialog_text = "%s has unsaved changes." % _current_rel
	dialog.ok_button_text = "Save"
	dialog.add_button("Discard", true, "discard")
	add_child(dialog)
	dialog.confirmed.connect(func(): _save_after_dialog(dialog, answer))
	dialog.custom_action.connect(func(action):
		if action == "discard":
			dialog.queue_free()
			answer.call(true)
	)
	dialog.canceled.connect(func():
		dialog.queue_free()
		answer.call(false)
	)
	dialog.popup_centered()

func _has_open_ask() -> bool:
	return find_child("DiscardConfirm", false, false) != null \
		or find_child("OverwriteConfirm", false, false) != null

## The close contract (`PaneBody.request_close`): the pane is about to be
## destroyed, so the buffer is about to be lost for good — the same ask the
## Back button makes runs first, and a Cancel cancels the close.
func request_close(answer: Callable) -> void:
	_request_leave(answer)

## The close contract's state half: an IPC caller cannot answer a dialog, so
## it refuses a pane that holds unsaved work instead (its own guard, and
## `PaneBody.has_unsaved_state` for the default).
func has_unsaved_state() -> bool:
	return _is_dirty()

func apply_settings(settings: Dictionary):
	var previous_vault := vault_path
	var previous_mode := view_mode
	super.apply_settings(settings)
	# `view_mode` is a pane property only for its declared values; anything
	# else (a typo in an untrusted layout) keeps the pane's own value.
	if settings.get("view_mode") is String:
		view_mode = settings["view_mode"] if settings["view_mode"] in VIEW_MODES else previous_mode
	if not is_inside_tree():
		return
	# The base assigned `vault_path` (its name is the settings key); re-scan
	# rather than reassign, so a half-typed path stays in the settings field.
	if vault_path != previous_vault:
		if _note_box.visible and _is_dirty():
			# A different vault makes the open note meaningless, and the
			# settings panel's debounce makes a dialog here unusable — say
			# what was lost instead of discarding it silently.
			ToastManager.warn("Discarded unsaved changes to %s (vault changed)" % _current_rel, 5.0, "Wiki")
		# A different vault makes the old query meaningless.
		_search.text = ""
		_apply_font_size()
		_refresh()
		return
	# Everything else is a property of this pane, not of the vault: applying
	# it must not close the note the user is editing.
	_apply_font_size()
	_apply_view_mode()

func _get_layout_state() -> Dictionary:
	var state = super._get_layout_state()
	state.merge({"vault_path": vault_path, "view_mode": view_mode})
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

	var mode_opt = OptionButton.new()
	for mode in VIEW_MODES:
		mode_opt.add_item(mode.capitalize())
	mode_opt.selected = maxi(0, VIEW_MODES.find(view_mode))
	mode_opt.item_selected.connect(func(_idx): panel._debounce_timer.start())
	_add_setting_row(v, "Note view:", mode_opt)

	panel._gather_func = func():
		return {
			"pane_name": name_le.text.strip_edges(),
			"font_size": int(font_spin.value),
			"vault_path": vault_le.text.strip_edges(),
			"view_mode": VIEW_MODES[mode_opt.selected] if mode_opt.selected >= 0 else "split",
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
