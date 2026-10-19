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
##
## The pane also has a **link graph view** — the vault's own link structure
## drawn as a canvas, not a second file format. `GptyTerminal.vault_graph`
## answers every indexed note plus one ghost per unresolved target, with links
## aggregated per pair; `VaultGraphModel` lays it out deterministically and
## `VaultGraphView` draws it. Geometry is session state in the view (a drag
## lasts as long as the pane), and nothing there writes to the vault: clicking
## a note opens it through the same leave guard the list uses, and clicking a
## ghost runs the same resolution a preview mention does. A right-click on an
## edge sets or clears a **declared weight** — the authored layer over measured
## mentions, kept in the user's `user://link_weights.json` (never `vaults.db`,
## which a rebuild may replace) and display-only: it changes thickness, layout
## stiffness and link-panel order, never which edges exist or what a click can
## reach.
##
## The close guards cover every deliberate way a buffer can end; a crash (or an
## outside kill) has no guard to run, so the pane also keeps a *recovery copy*
## of a dirty buffer outside the vault (`GptyTerminal.vault_scratch_write`,
## under gpty's state directory — never a second write path into the vault) and
## offers it back when the same note is reopened: never applied on its own, and
## dropped the moment the buffer reaches the file or the user discards it.

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
## Wait after a buffer turns dirty before its recovery copy is written. The
## copy is throttled, not restarted per keystroke — a debounce that resets on
## every keystroke never fires during a long typing run, which is exactly when
## the most work is at risk — so at most this much typing can be lost.
const SCRATCH_DEBOUNCE := 1.5
## The note view's modes, in toolbar order.
const VIEW_MODES := ["edit", "split", "preview"]
## Rows the link panel shows per section. One note can hold the parser's 512
## mentions and a popular one gathers many backlinks, so the panel is a
## summary — the rest is counted in its footer instead of pushing the editor
## out of the pane.
const MAX_LINK_ROWS := 50
## Longest target or path a link row prints (the text is note-supplied).
const MAX_SHOWN_LINK := 72
## Height of the link panel's scroll area: a bounded strip, so the editor and
## the preview keep their space whether a note has one link or fifty.
const LINK_PANEL_HEIGHT := 132
## What the New-note prompt starts with: one word to edit beats an empty field.
const NEW_NOTE_NAME := "Untitled.md"

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
var _scratch_timer: Timer
## File verbs on the list and note views: new (list), rename/delete (note).
var _new_button: Button
var _rename_button: Button
var _delete_button: Button
## The link graph: its entry in the top row and the canvas itself. The canvas
## keeps the session's node geometry, so hiding and reopening it never
## reshuffles a graph the user arranged.
var _graph_button: Button
var _graph_view: VaultGraphView

## The link panel's parts: this note's outgoing mentions and its backlinks,
## both from the index (`GptyTerminal.vault_links`). Rows are rebuilt whenever
## a note opens or a save lands (the save re-indexes), never polled.
var _links_box: VBoxContainer
var _links_outgoing_heading: Label
var _outgoing_rows: VBoxContainer
var _links_backlinks_heading: Label
var _backlinks_rows: VBoxContainer
var _links_footer: Label

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
## The recovery copy a restore question is about, and the note it belongs to,
## for as long as that question is on screen.
var _restore_copy: Dictionary = {}
var _restore_rel := ""

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

	_new_button = Button.new()
	_new_button.name = "NewNote"
	_new_button.text = "New note"
	_new_button.focus_mode = Control.FOCUS_NONE
	_new_button.tooltip_text = "Create a Markdown note in this vault"
	_new_button.visible = false
	_new_button.pressed.connect(_ask_new_note)
	top.add_child(_new_button)

	_search = LineEdit.new()
	_search.name = "Search"
	_search.placeholder_text = "Search notes"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(func(_text): _search_timer.start())
	_search.text_submitted.connect(func(_text): _run_search())
	top.add_child(_search)

	_graph_button = Button.new()
	_graph_button.name = "GraphView"
	_graph_button.text = "Graph"
	_graph_button.focus_mode = Control.FOCUS_NONE
	_graph_button.tooltip_text = "Map this vault's links (re-reads the index)"
	_graph_button.pressed.connect(_show_graph)
	top.add_child(_graph_button)

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

	_rename_button = Button.new()
	_rename_button.name = "RenameNote"
	_rename_button.text = "Rename"
	_rename_button.focus_mode = Control.FOCUS_NONE
	_rename_button.tooltip_text = "Move this note to another vault-relative path"
	_rename_button.pressed.connect(_ask_rename)
	toolbar.add_child(_rename_button)

	_delete_button = Button.new()
	_delete_button.name = "DeleteNote"
	_delete_button.text = "Delete"
	_delete_button.focus_mode = Control.FOCUS_NONE
	_delete_button.tooltip_text = "Delete this note from the vault"
	_delete_button.pressed.connect(_ask_delete)
	toolbar.add_child(_delete_button)

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
	# `[[mentions]]` render as internal links and are followed in place; the
	# view announces a click and the pane resolves it against the vault.
	_reader.wikilinks_enabled = true
	_reader.note_link_clicked.connect(_on_mention_clicked)
	split.add_child(_reader)

	# ── The link panel: this note's mentions and its backlinks ──
	_links_box = VBoxContainer.new()
	_links_box.name = "LinksPanel"
	_links_box.visible = false
	_note_box.add_child(_links_box)

	var links_scroll := ScrollContainer.new()
	links_scroll.name = "LinksScroll"
	links_scroll.custom_minimum_size.y = LINK_PANEL_HEIGHT
	links_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	links_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_links_box.add_child(links_scroll)

	var links_rows := VBoxContainer.new()
	links_rows.name = "LinksRows"
	links_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	links_scroll.add_child(links_rows)

	_links_outgoing_heading = _add_link_heading(links_rows, "Links to")
	_outgoing_rows = VBoxContainer.new()
	_outgoing_rows.name = "OutgoingLinks"
	_outgoing_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	links_rows.add_child(_outgoing_rows)

	_links_backlinks_heading = _add_link_heading(links_rows, "Linked from")
	_backlinks_rows = VBoxContainer.new()
	_backlinks_rows.name = "Backlinks"
	_backlinks_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	links_rows.add_child(_backlinks_rows)

	_links_footer = Label.new()
	_links_footer.name = "LinksFooter"
	_links_footer.visible = false
	_links_footer.add_theme_font_size_override("font_size", 11)
	links_rows.add_child(_links_footer)

	# ── The link graph: the vault's structure, generated on demand ──
	_graph_view = VaultGraphView.new()
	_graph_view.name = "LinkGraph"
	_graph_view.visible = false
	_graph_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph_view.node_activated.connect(_on_graph_node_activated)
	_graph_view.ghost_activated.connect(_on_graph_ghost_activated)
	_graph_view.weight_set_requested.connect(_ask_declared_weight)
	_graph_view.weight_cleared.connect(_clear_declared_weight)
	content.add_child(_graph_view)

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

	_scratch_timer = Timer.new()
	_scratch_timer.one_shot = true
	_scratch_timer.wait_time = SCRATCH_DEBOUNCE
	_scratch_timer.timeout.connect(_write_scratch)
	add_child(_scratch_timer)

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
	_graph_view.visible = false
	_footer.visible = false
	_list.clear()
	var problem := _vault_problem()
	if problem != "":
		_show_placeholder(problem, false)
		return
	_search.visible = true
	_new_button.visible = true
	_graph_button.visible = true
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
	if _list == null or _note_box.visible or _graph_view.visible or _vault_problem() != "":
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
	_graph_view.visible = false
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
	_graph_view.visible = false
	_back.visible = false
	_search.visible = searchable
	# A working vault with no note open can always gain one, even when the
	# placeholder is a zero-hit search or an empty vault.
	_new_button.visible = searchable
	# The graph is readable whatever the search text says (it is vault-wide),
	# but a vault that cannot be opened has nothing to draw.
	_graph_button.visible = searchable

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
	# No note is open, so the preview has nothing to declare about a cut.
	_sync_source_notice()
	# A different note (or the list) has different links; a stale row must
	# never offer to open a note the panel no longer describes.
	_clear_links()
	# No note is open, so no recovery copy is pending. The copy on disk is
	# another matter: a deliberate end drops it, and nothing here does.
	_scratch_timer.stop()

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
##
## `fragment` is a heading the link named (`[[note#heading]]`) and `line` a
## 1-based source line a backlink row names; one of them is where the view
## lands instead of the top. Both are navigation only — the note that opened
## is the resolved path, never anything the fragment says.
func _open_note(rel: String, fragment := "", line := 0) -> void:
	var answer = JSON.parse_string(str(GptyTerminal.vault_note_read(vault_path, rel)))
	if not (answer is Dictionary) or answer.has("error"):
		# The path came from a just-completed walk or search; a failure here
		# means the note moved or was replaced between the two.
		var why := str(answer["error"]) if answer is Dictionary and answer.has("error") else "unreadable"
		ToastManager.warn("Could not open note: " + why, 4.0, "Wiki")
		return
	_current_rel = rel
	# The editor works in LF; `_payload` puts the CRLFs back on save. The text
	# "dirty" is measured against has to be in that same space, or every CRLF
	# note would open already dirty — with Save lit for an edit nobody made, and
	# a recovery copy offered back for the file the pane just read.
	_saved_text = str(answer.get("text", ""))
	if bool(answer.get("crlf", false)):
		_saved_text = _saved_text.replace("\r\n", "\n")
	_loaded_mtime = int(answer.get("mtime", 0))
	_loaded_size = int(answer.get("size", 0))
	_crlf = bool(answer.get("crlf", false))
	# A truncated read is a prefix; editing it and saving would drop the rest
	# of the file, so that note stays read-only.
	_editable_note = not bool(answer.get("truncated", false))
	# Before the first render below: a read-only note is at the read cap, so
	# the preview has to be told what it is not showing.
	_sync_source_notice()
	# A pending copy from the previous note must not fire into this one.
	_scratch_timer.stop()
	# (Setting `text` reaches `_on_editor_changed` a frame later, like every
	# TextEdit change — harmless, because that handler recomputes the state
	# instead of trusting the signal.)
	_editor.text = _saved_text
	_editor.editable = _editable_note
	_editor.scroll_vertical = 0
	_note_title.text = rel
	_note_title.tooltip_text = rel
	_list.visible = false
	_footer.visible = false
	_placeholder.visible = false
	_graph_view.visible = false
	_search.visible = false
	_new_button.visible = false
	_graph_button.visible = true
	_note_box.visible = true
	_back.visible = true
	_apply_view_mode()
	_update_dirty()
	_reader.scroll_to_line(0)
	# After the top reset, so a fragment or line lands where the link pointed.
	_scroll_open_note(fragment, line)
	# The index's view of this note (outgoing mentions and backlinks); it is
	# rebuilt, not polled, and a save re-indexes so it refreshes again there.
	_refresh_links()
	# Last, so the note is on screen when the question appears.
	_offer_scratch(rel)

# ── The link graph: the vault's structure, generated on demand ──────────

## Show the vault's link structure. The answer is read from the index on every
## visit — the pane's own mutations (a save, a create, a rename, a delete, a
## reference rewrite) all re-index before returning, so there is no cached
## graph to go stale; the view keeps only its session geometry.
##
## Opening the graph does not disturb the open note: the buffer stays alive
## (and dirty) behind the canvas, so Back and a node click route through the
## same leave guard every other navigation uses, and a dirty buffer can never
## be replaced without its answer.
func _show_graph() -> void:
	var problem := _vault_problem()
	if problem != "":
		_show_placeholder(problem, false)
		return
	# A search still waiting on its debounce must not pull the pane back to
	# the list after the graph has been opened.
	_search_timer.stop()
	var answer = JSON.parse_string(str(GptyTerminal.vault_graph(vault_path)))
	var graph := VaultGraphModel.parse(answer, LinkWeightsStore.vault_weights(vault_path))
	if not bool(graph["ok"]):
		_show_placeholder("Vault graph failed: " + _shown_path(str(graph["error"])))
		return
	# Lazy cleanup of declarations whose endpoints left the vault. A truncated
	# answer must not prune: the edges it does not name are still real, and
	# deleting their authored weights would be unrecoverable.
	if not bool(graph["truncated"]):
		var known := {}
		for node in graph["nodes"]:
			if node is Dictionary and not bool(node.get("ghost", false)):
				known[str(node.get("id", ""))] = true
		LinkWeightsStore.prune(vault_path, known)
	_list.visible = false
	_footer.visible = false
	_note_box.visible = false
	_placeholder.visible = false
	_search.visible = false
	_new_button.visible = false
	_graph_button.visible = true
	_back.visible = true
	_graph_view.visible = true
	_graph_view.show_graph(graph, _current_rel)

## A node opens its note, behind the same ask a Back makes: the click can
## replace a buffer that is still unsaved, so the graph cannot open over it.
func _on_graph_node_activated(id: String) -> void:
	_request_leave(func(proceed: bool):
		if proceed:
			_open_note(id)
	)

## An unresolved target is exactly what the preview's mention is: run the same
## resolution (missing → offer to create, ambiguous → report), never a guess.
func _on_graph_ghost_activated(target: String) -> void:
	_follow_target(target)

## The canvas's set control asked for a number. The pane owns the prompt (and
## the pane-wide "one ask at a time" rule), then writes the user-owned store —
## the canvas itself never writes anything.
func _ask_declared_weight(a: String, b: String, current: int) -> void:
	if _has_open_ask():
		return
	var dialog := ConfirmationDialog.new()
	dialog.name = "WeightConfirm"
	dialog.title = "Declared weight"
	dialog.ok_button_text = "Set"
	var box := VBoxContainer.new()
	# A fixed content width: AcceptDialog fits a child to the dialog's content
	# rect, and an auto-wrapping Label there reports a tiny minimum.
	box.custom_minimum_size = Vector2(380, 0)
	var label := Label.new()
	label.text = "How strongly are %s and %s related?\n\nThis is display only: it overrides the measured mention count for edge thickness and link-panel order. Relayout applies it to the arrangement." % [
		_shown_link(a), _shown_link(b),
	]
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = 380
	box.add_child(label)
	var spin := SpinBox.new()
	spin.name = "WeightValue"
	spin.min_value = LinkWeights.MIN_WEIGHT
	spin.max_value = LinkWeights.MAX_WEIGHT
	spin.step = 1
	spin.value = current if current > 0 else LinkWeights.DEFAULT_WEIGHT
	spin.custom_minimum_size.x = 120
	box.add_child(spin)
	dialog.add_child(box)
	add_child(dialog)
	dialog.confirmed.connect(func():
		# Hide before writing: the write re-applies the canvas, and a visible
		# dialog would keep `_has_open_ask` true behind it.
		dialog.hide()
		dialog.queue_free()
		_set_declared_weight(a, b, int(spin.value))
	)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()

## Write one declared weight for the drawn pair and re-apply it to the canvas.
func _set_declared_weight(a: String, b: String, weight: int) -> void:
	var problem := LinkWeightsStore.set_pair(vault_path, a, b, weight)
	if problem != "":
		ToastManager.warn("Could not declare a weight: %s" % problem, 5.0, "Wiki")
		return
	_refresh_declared_weights()
	ToastManager.info(
		"Declared weight %d for %s ↔ %s" % [weight, _shown_link(a), _shown_link(b)],
		3.0,
		"Wiki"
	)

## Clear both directions of a pair's declaration (a no-op is still a success).
func _clear_declared_weight(a: String, b: String) -> void:
	var problem := LinkWeightsStore.clear_pair(vault_path, a, b)
	if problem != "":
		ToastManager.warn("Could not clear the weight: %s" % problem, 5.0, "Wiki")
		return
	_refresh_declared_weights()
	ToastManager.info("Cleared the declared weight for %s ↔ %s" % [
		_shown_link(a), _shown_link(b),
	], 3.0, "Wiki")

## Re-apply the authored layer without re-querying the index: setting a weight
## changes what is drawn, never which pairs exist.
func _refresh_declared_weights() -> void:
	if _graph_view != null and _graph_view.visible:
		_graph_view.set_weights(LinkWeightsStore.vault_weights(vault_path))

# ── The link panel: the open note's mentions and backlinks ──────────────

## Rebuild the panel from the index's view of the open note.
##
## `GptyTerminal.vault_links` answers outgoing occurrences, backlinks and the
## unresolved targets with their candidates — a read of the index the parser
## already wrote, never a scan of the vault. The panel is display plus
## navigation: a resolved outgoing row opens its note in place (and its heading
## fragment when it names one), a backlink row opens the linking note at the
## line it names, all behind the same ask a Back makes; a missing target offers
## create-from-link, and an ambiguous one names its candidates and is not
## clickable because either choice would be a guess.
func _refresh_links() -> void:
	_clear_links()
	if _current_rel == "" or _links_box == null:
		return
	var answer = JSON.parse_string(str(GptyTerminal.vault_links(vault_path, _current_rel)))
	if not (answer is Dictionary) or answer.has("error"):
		return
	var outgoing: Array = answer.get("outgoing", []) if answer.get("outgoing") is Array else []
	var backlinks: Array = answer.get("backlinks", []) if answer.get("backlinks") is Array else []
	var unresolved: Array = answer.get("unresolved", []) if answer.get("unresolved") is Array else []
	# The candidate list is per unresolved *occurrence* (target + line), the
	# identity the outgoing rows use.
	var candidates := {}
	for entry in unresolved:
		if entry is Dictionary:
			candidates[_link_key(str(entry.get("target", "")), int(entry.get("line", 0)))] = \
				entry.get("candidates", [])
	# The authored layer orders the panel: a declared weight is the user's own
	# judgement that a mention matters, so it sorts above measured ones. The
	# section cap applies after the ordering, so a curated mention can surface
	# from past it; the footer still counts every row the cap excludes.
	var weights := LinkWeightsStore.vault_weights(vault_path)
	outgoing = _ordered_by_declared_weight(outgoing, weights, _current_rel, true)
	backlinks = _ordered_by_declared_weight(backlinks, weights, _current_rel, false)
	var shown_out := 0
	for entry in outgoing:
		if not (entry is Dictionary):
			continue
		if shown_out >= MAX_LINK_ROWS:
			break
		var target := str(entry.get("target", ""))
		if target == "":
			continue
		shown_out += 1
		var line := int(entry.get("line", 0))
		var fragment := str(entry.get("fragment", "")) if entry.get("fragment") is String else ""
		var shown := target if fragment == "" else "%s#%s" % [target, fragment]
		var resolved = entry.get("resolved")
		if resolved is String and str(resolved) != "":
			var tooltip := "Open %s" % str(resolved)
			if fragment != "":
				tooltip += " at #%s" % fragment
			_add_link_row(_outgoing_rows, "%s · line %d" % [_shown_link(shown), line],
				_follow_note.bind(str(resolved), fragment), tooltip)
			continue
		var list: Array = candidates.get(_link_key(target, line), [])
		if list.is_empty():
			# Missing (not ambiguous): the row offers the create-from-link
			# action, because that is the one way this note can gain its
			# target. Ambiguity stays information only — creating either
			# candidate would be a guess.
			_add_link_row(_outgoing_rows, "%s · line %d · not found" % [_shown_link(target), line],
				_create_from_link.bind(target), "Create note \"%s\"" % target)
		else:
			# The ambiguity hint is the store's own candidate list, so the row
			# names exactly the notes the resolver refused to choose between.
			_add_link_row(_outgoing_rows,
				"%s · line %d · ambiguous: %s" % [_shown_link(target), line, _joined_links(list)],
				Callable(), "")
	var shown_back := 0
	for entry in backlinks:
		if not (entry is Dictionary):
			continue
		if shown_back >= MAX_LINK_ROWS:
			break
		var src := str(entry.get("src", ""))
		if src == "":
			continue
		shown_back += 1
		var line := int(entry.get("line", 0))
		# The backlink row names a line in the note it opens, so the click
		# lands there (derived from the nearest heading above it) instead of
		# stopping at the top of a long note.
		_add_link_row(_backlinks_rows, "%s · line %d" % [_shown_link(src), line],
			_follow_note.bind(src, "", line), "Open %s at line %d" % [src, line])
	var omitted := maxi(0, outgoing.size() - shown_out) + maxi(0, backlinks.size() - shown_back)
	_links_footer.text = "… %d more mention(s) not shown" % omitted
	_links_footer.visible = omitted > 0
	_links_outgoing_heading.visible = shown_out > 0
	_outgoing_rows.visible = shown_out > 0
	_links_backlinks_heading.visible = shown_back > 0
	_backlinks_rows.visible = shown_back > 0
	_links_box.visible = shown_out > 0 or shown_back > 0

## Drop the panel's rows (a rebuild, or leaving the note). The containers stay
## so the next rebuild has somewhere to put its rows.
func _clear_links() -> void:
	for container in [_outgoing_rows, _backlinks_rows]:
		if container == null:
			continue
		for row in container.get_children():
			container.remove_child(row)
			row.queue_free()
	if _links_footer != null:
		_links_footer.visible = false
	if _links_box != null:
		_links_box.visible = false

func _add_link_heading(parent: VBoxContainer, text: String) -> Label:
	var label := Label.new()
	label.name = text.validate_node_name()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	parent.add_child(label)
	return label

## One panel row: a flat, left-aligned button when it has somewhere to go
## (disabled otherwise), so an unresolved mention reads as information rather
## than as a broken action.
func _add_link_row(parent: VBoxContainer, text: String, action: Callable, tooltip: String) -> Button:
	var row := Button.new()
	row.flat = true
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.focus_mode = Control.FOCUS_NONE
	row.text = text
	row.tooltip_text = tooltip
	row.add_theme_font_size_override("font_size", 12)
	row.disabled = not action.is_valid()
	parent.add_child(row)
	if action.is_valid():
		row.pressed.connect(action)
	return row

## Follow a link in place: the destination replaces the open note. The same
## Save/Discard/Cancel ask a Back makes runs first — following can be the way
## an unsaved buffer is lost. There is no history stack in v1: the notes list
## is the way back.
##
## A link to the note already open replaces nothing, so it needs no ask: it
## only moves the view to the fragment or line it names (a self-mention is
## how a note's own table of contents works).
func _follow_note(rel: String, fragment := "", line := 0) -> void:
	if rel == "":
		return
	if rel == _current_rel:
		_scroll_open_note(fragment, line)
		return
	_request_leave(func(proceed: bool):
		if proceed:
			_open_note(rel, fragment, line)
	)

## Move the open note's view to where a link pointed, in whichever half of the
## note view is showing: the source editor scrolls by line, the preview by
## rendered line (the two spaces do not agree on line numbers), and split mode
## does both. A heading the note does not contain is reported once — the
## destination note still opened, so a missing `#fragment` is a wrong scroll,
## never a failed navigation.
func _scroll_open_note(fragment: String, line: int) -> void:
	var found := false
	if _editor.visible:
		var heading_line := MarkdownAnchors.find(_editor.text, fragment) if fragment != "" else 0
		if heading_line > 0:
			_editor.scroll_vertical = heading_line - 1
			found = true
		elif line > 0:
			_editor.scroll_vertical = line - 1
			found = true
	if _reader.visible and fragment != "":
		found = _reader.scroll_to_heading(fragment) or found
	elif _reader.visible and line > 0:
		_reader.scroll_to_source_line(_preview_text(), line)
	if fragment != "" and not found:
		ToastManager.warn("Heading not found: #" + _shown_link(fragment), 4.0, "Wiki")

## A rendered `[[mention]]` was clicked. The destination comes from the same
## resolver the index used (`vault_link_resolve`), so an ambiguous stem is
## reported with its candidates rather than silently picked; the fragment it
## carried is the place inside that destination to land.
func _on_mention_clicked(target: String, fragment: String) -> void:
	if _current_rel == "":
		return
	_follow_target(target, fragment)

## Follow one `[[target]]` by the index's own rule. The preview's mention click
## and the graph's ghost click share this: a resolved target opens in place, a
## missing one offers to create it, and an ambiguous stem is reported with its
## candidates and never silently picked. `fragment` is navigation inside a
## resolved note; it takes no part in resolving the note.
func _follow_target(target: String, fragment := "") -> void:
	var answer = JSON.parse_string(str(GptyTerminal.vault_link_resolve(vault_path, target)))
	if not (answer is Dictionary) or answer.has("error"):
		var why := str(answer["error"]) if answer is Dictionary and answer.has("error") else "unreadable"
		ToastManager.warn("Could not resolve [[%s]]: %s" % [_shown_link(target), _shown_link(why)], 5.0, "Wiki")
		return
	var resolved = answer.get("resolved")
	if resolved is String and str(resolved) != "":
		_follow_note(str(resolved), fragment)
		return
	var candidates: Array = answer.get("candidates", []) if answer.get("candidates") is Array else []
	if candidates.is_empty():
		# Missing, not ambiguous: the mention names a note that could exist,
		# so the click offers to create it (the create-from-link action).
		_create_from_link(target)
	else:
		ToastManager.warn("[[%s]] is ambiguous: %s" % [_shown_link(target), _joined_links(candidates)], 6.0, "Wiki")

## Order panel entries by the declared weight of the mention they name,
## highest first, keeping the index's order on ties.
##
## `outgoing` rows name a target the open note mentions (`_current_rel` is
## the source); backlink rows name the note that mentions the open one (the
## entry's `src`). Only resolved entries can carry a declaration — an
## unresolved target is not a note, so it weighs 0 and keeps its place. The
## caller's cap is applied afterwards, and its footer counts what it excludes.
func _ordered_by_declared_weight(
	entries: Array, weights: Dictionary, note: String, outgoing: bool
) -> Array:
	var decorated: Array = []
	for index in entries.size():
		var entry = entries[index]
		if not (entry is Dictionary):
			continue
		var other := ""
		if outgoing:
			var resolved = entry.get("resolved")
			other = str(resolved) if resolved is String else ""
		else:
			other = str(entry.get("src", ""))
		decorated.append({
			"entry": entry,
			"index": index,
			"weight": LinkWeights.lookup(
				weights, note, other) if outgoing else LinkWeights.lookup(weights, other, note),
		})
	decorated.sort_custom(func(left, right):
		if int(left["weight"]) != int(right["weight"]):
			return int(left["weight"]) > int(right["weight"])
		return int(left["index"]) < int(right["index"])
	)
	var ordered: Array = []
	for item in decorated:
		ordered.append(item["entry"])
	return ordered

func _link_key(target: String, line: int) -> String:
	return "%s|%d" % [target, line]

func _shown_link(text: String) -> String:
	return text if text.length() <= MAX_SHOWN_LINK else text.left(MAX_SHOWN_LINK) + "…"

func _joined_links(paths: Array) -> String:
	var parts: Array = []
	for path in paths:
		parts.append(_shown_link(str(path)))
	return ", ".join(parts)

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
## live preview). The read cap's notice is deliberately *not* in it — a notice
## appended to a source at the renderer's cap is the first thing the cut
## drops — and `_reader` shows it above the body instead (`_sync_source_notice`).
func _preview_text() -> String:
	return _editor.text

## Tell the preview which cut the *pane* made: a note read at the cap is a
## prefix of a larger file, so the reader has to say so above the body — the
## source cannot carry it, because that note is at the renderer's cap too.
func _sync_source_notice() -> void:
	_reader.set_source_notice(
		TextRead.truncation_notice(TextRead.DEFAULT_MAX_BYTES, _loaded_size)
		if not _editable_note and _current_rel != ""
		else ""
	)

## A TextEdit change — user typing or a programmatic `text` assignment; the
## signal arrives one frame after the edit, so this recomputes from the
## current buffer rather than trusting the signal's timing.
##
## The preview is told to render on *settle*, not on the streaming throttle: a
## keystroke must never queue a render, because a preview update on a large
## note costs a full render plus the label's shape pass (measured: `GptyMarkdown`
## render ~14 ms for 1 MiB in release, and a shape pass that this renderer's own
## output now keeps linear at ~0.8 s for 1 MiB). The pane switches modes and
## opens notes with `render_now` — those are explicit acts and must show the
## current buffer at once.
func _on_editor_changed() -> void:
	_update_dirty()
	_touch_scratch()
	if _preview_visible():
		_reader.set_markdown_settled(_preview_text())

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
	# The buffer reached the file, so the crash copy has nothing left to say.
	_drop_scratch(vault_path, _current_rel)
	_update_dirty()
	# The save re-indexed the vault: this note's edges (and its backlinks, in
	# other notes) may have changed with the text just written.
	_refresh_links()
	if not bool(reply.get("indexed", true)):
		ToastManager.warn("Saved %s, but the search index could not be updated" % _current_rel, 5.0, "Wiki")
	if answer.is_valid():
		answer.call(true)

# ── Creating, renaming, and deleting notes ─────────────────────────────
#
# The editor used to only touch notes that already existed. These are the
# missing file verbs, held to the same rules as a save: the path follows the
# walk's vocabulary, the operation stays inside the vault, and the core
# refuses an existing destination rather than replacing it (`create_new`).
# Each verb re-indexes, so a new name is searchable and a moved one stops
# resolving links that named the old stem.

func _ask_new_note() -> void:
	_ask_note_name("New note", NEW_NOTE_NAME, "Create",
		"Create a new note in this vault.", _create_note)

## The create-from-link action: a mention whose target does not exist yet
## offers to make it. The name keeps the mention's own spelling (plus `.md`
## when it has no extension) so the link resolves as soon as the note exists.
func _create_from_link(target: String) -> void:
	_ask_note_name("New note from link", _note_name_with_md(target), "Create",
		"Create [[%s]] as a new note?" % target, _create_note)

func _ask_rename() -> void:
	if _current_rel == "":
		return
	_ask_note_name("Rename note", _current_rel, "Rename",
		"New vault-relative path for %s." % _current_rel, _rename_note)

## Ask for a note path, then run `answer` with it. `answer` returns whether
## the action landed: a refusal (a collision, a path outside the vocabulary)
## re-opens the same question with the typed text, so the correction happens
## where the name was entered instead of costing the whole dialog.
func _ask_note_name(title: String, initial: String, ok_text: String, hint: String, answer: Callable) -> void:
	if _has_open_ask():
		return
	var dialog := ConfirmationDialog.new()
	dialog.name = "NoteNameConfirm"
	dialog.title = title
	dialog.ok_button_text = ok_text
	var box := VBoxContainer.new()
	# A fixed content width: AcceptDialog fits a child to the dialog's content
	# rect, and an auto-wrapping Label there reports a tiny minimum (measured:
	# a 420 px request became a 791 px-tall dialog).
	box.custom_minimum_size = Vector2(380, 0)
	var label := Label.new()
	label.text = hint
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = 380
	box.add_child(label)
	var field := LineEdit.new()
	field.name = "NoteName"
	field.text = initial
	field.select_all()
	box.add_child(field)
	dialog.add_child(box)
	dialog.register_text_enter(field)
	add_child(dialog)
	dialog.confirmed.connect(func():
		var value := _normalized_note_name(field.text)
		# Hide before running the action: a real OK press hides the dialog
		# before emitting `confirmed` (measured), but a directly emitted signal
		# does not — and the action may ask its own question (a dirty buffer's
		# leave ask) or re-open this one after a refusal.
		dialog.hide()
		dialog.queue_free()
		if not answer.call(value):
			_ask_note_name(title, field.text, ok_text, hint, answer)
	)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()

## What a typed name means: trimmed, with `.md` appended when the last
## component has no extension at all. Any other extension is left alone — the
## store refuses it with a message rather than silently renaming what the
## user typed.
func _normalized_note_name(text: String) -> String:
	var name := text.strip_edges()
	if name == "" or name.get_file().get_extension() != "":
		return name
	return name + ".md"

func _note_name_with_md(target: String) -> String:
	var name := target.strip_edges()
	return name if name.get_file().get_extension() != "" else name + ".md"

## Create an empty note and open it. Opening goes through the leave guard:
## creating from a link happens while another note — possibly with an unsaved
## buffer — is the one on screen.
func _create_note(rel: String) -> bool:
	if rel == "":
		ToastManager.warn("Enter a note name", 3.0, "Wiki")
		return false
	var reply = JSON.parse_string(str(GptyTerminal.vault_note_create(vault_path, rel, "")))
	if not (reply is Dictionary) or reply.has("error"):
		ToastManager.warn(_note_failure("Could not create", rel, reply), 5.0, "Wiki")
		return false
	if not bool(reply.get("indexed", true)):
		ToastManager.warn("Created %s, but the search index could not be updated" % rel, 5.0, "Wiki")
	_request_leave(func(proceed: bool):
		if proceed:
			_open_note(rel)
	)
	return true

## Move the open note to a new path. The buffer and its stamp stay valid (a
## rename preserves the file's mtime and size); a dirty buffer's recovery copy
## is re-keyed, because a copy left under the old path would never be offered
## again.
func _rename_note(new_rel: String) -> bool:
	if _current_rel == "":
		return false
	if new_rel == "":
		ToastManager.warn("Enter a note name", 3.0, "Wiki")
		return false
	if new_rel == _current_rel:
		return true
	var previous := _current_rel
	var reply = JSON.parse_string(str(GptyTerminal.vault_note_rename(vault_path, previous, new_rel)))
	if not (reply is Dictionary) or reply.has("error"):
		ToastManager.warn(_note_failure("Could not rename", new_rel, reply), 5.0, "Wiki")
		return false
	_current_rel = str(reply.get("path", new_rel))
	_note_title.text = _current_rel
	_note_title.tooltip_text = _current_rel
	if _is_dirty():
		_drop_scratch(vault_path, previous)
		_scratch_timer.stop()
		_write_scratch()
	else:
		_drop_scratch(vault_path, previous)
	if not bool(reply.get("indexed", true)):
		ToastManager.warn("Renamed %s, but the search index could not be updated" % _current_rel, 5.0, "Wiki")
	# The authored layer follows the file: declared weights key on note paths,
	# so both endpoints are re-keyed here — before any graph view could prune
	# the old name as vanished. It is independent of the mention update below:
	# a declaration is not a mention, and declining to respell other notes must
	# not discard the curation. A refused or failed rename never reaches this
	# point, so the store is untouched in that case.
	LinkWeightsStore.rekey_note(vault_path, previous, _current_rel)
	# This note's own edges moved with it. Mentions other notes wrote to the
	# old name do not follow a file: the rename just made them unresolved, and
	# updating them writes *their* notes — so it is a separate, explicit
	# question, never a side effect of the rename. A clean buffer also makes
	# this note's own self-mentions candidates; a dirty one is the editor's and
	# is never written under.
	_refresh_links()
	_offer_link_update(previous, _current_rel, not _is_dirty())
	return true

## Offer to respell the mentions that still name the old path. The preview
## answers how many notes and occurrences resolved to the old name before the
## move; nothing is written until the answer is Update, and a vault with no
## mentions is not asked about at all. `include_renamed` is the open note's
## buffer state: a clean buffer can adopt a rewrite of itself, a dirty one
## must never be written under.
func _offer_link_update(previous: String, new_rel: String, include_renamed: bool) -> void:
	if _has_open_ask():
		return
	var preview = JSON.parse_string(str(
		GptyTerminal.vault_link_rewrite_preview(vault_path, previous, new_rel, include_renamed)))
	if not (preview is Dictionary) or preview.has("error"):
		# The rename itself landed; a pass that cannot be planned is reported
		# rather than silently skipped — the mentions stay as they are.
		ToastManager.warn(_note_failure("Could not check mentions of", previous, preview), 5.0, "Wiki")
		return
	var files := int(preview.get("files", 0))
	if files <= 0:
		return
	var mentions := int(preview.get("mentions", 0))
	var dialog := ConfirmationDialog.new()
	dialog.name = "UpdateReferencesConfirm"
	dialog.title = "Update references?"
	dialog.dialog_text = "%d mention(s) in %d note(s) still name %s.\n\nUpdate them to %s?" % [
		mentions, files, previous, new_rel,
	]
	if bool(preview.get("truncated", false)):
		dialog.dialog_text += "\n\nThis vault has more notes than the walk lists, so some were not checked."
	dialog.ok_button_text = "Update"
	add_child(dialog)
	dialog.confirmed.connect(func():
		dialog.queue_free()
		_apply_link_update(previous, new_rel)
	)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()

## Apply the update the question offered. The core re-plans in this call, so
## the count is what actually landed (an edit made while the question was open
## is read fresh) and a note that changes between its plan and its write is
## skipped rather than replaced; the re-index makes the new backlinks visible
## in this pane's panel at once. The open note is included only when its buffer
## is still clean: the pass rewrote the file under it, so the answer carries
## the text and fresh stamp the editor adopts.
func _apply_link_update(previous: String, new_rel: String) -> void:
	var reply = JSON.parse_string(str(
		GptyTerminal.vault_link_rewrite(vault_path, previous, new_rel, not _is_dirty())))
	if not (reply is Dictionary) or reply.has("error"):
		ToastManager.warn(_note_failure("Could not update mentions of", previous, reply), 5.0, "Wiki")
		return
	var source = reply.get("renamed_note", null)
	if source is Dictionary and _current_rel == new_rel:
		_adopt_rewritten_note(source)
	var files := int(reply.get("files", 0))
	var mentions := int(reply.get("mentions", 0))
	var skipped := int(reply.get("skipped", 0))
	if mentions == 0:
		ToastManager.info("No mentions needed updating", 3.0, "Wiki")
	else:
		var text := "Updated %d mention(s) in %d note(s)" % [mentions, files]
		if skipped > 0:
			text += "; %d note(s) could not be updated" % skipped
		if bool(reply.get("truncated", false)):
			text += " (some notes were not checked)"
		ToastManager.info(text, 4.0, "Wiki")
	if not bool(reply.get("indexed", true)):
		ToastManager.warn("Mentions updated, but the search index could not be updated", 5.0, "Wiki")
	_refresh_links()

## Adopt text the reference pass wrote into the open note. The file under the
## clean buffer changed by exactly those respellings, so the buffer is brought
## in line and the fresh stamp comes from the answer — not from a second read,
## which could race an edit that landed after the pass. This is not an edit:
## `_saved_text` moves with the buffer, so dirty state and Save stay as they
## were, and a save right after does not hit `changed_on_disk`.
func _adopt_rewritten_note(source: Dictionary) -> void:
	var text := str(source.get("text", ""))
	_crlf = bool(source.get("crlf", _crlf))
	var buffer := text.replace("\r\n", "\n") if _crlf else text
	_saved_text = buffer
	_loaded_mtime = int(source.get("mtime", 0))
	_loaded_size = int(source.get("size", 0))
	var caret_line := _editor.get_caret_line()
	var caret_column := _editor.get_caret_column()
	var scroll := _editor.scroll_vertical
	_editor.text = buffer
	# A rewrite respells targets in place, so the line count is unchanged and
	# the caret's line survives; its column clamps to the line's new length.
	var line_index := mini(caret_line, maxi(_editor.get_line_count() - 1, 0))
	_editor.set_caret_line(line_index)
	_editor.set_caret_column(mini(caret_column, _editor.get_line(line_index).length()))
	_editor.scroll_vertical = scroll
	_update_dirty()
	if _preview_visible():
		# A programmatic `text` assignment emits only `text_set` (never
		# `text_changed`), so the preview is re-rendered here or it would keep
		# showing the old spellings.
		_reader.render_now(_preview_text())

## Ask before the one destructive verb: an open note is about to stop
## existing, and a dirty buffer dies with it — no save question, because the
## file is what is being deleted.
func _ask_delete() -> void:
	if _current_rel == "" or _has_open_ask():
		return
	var dialog := ConfirmationDialog.new()
	dialog.name = "DeleteConfirm"
	dialog.title = "Delete note"
	dialog.dialog_text = "Delete %s? This cannot be undone." % _current_rel
	if _is_dirty():
		dialog.dialog_text += "\n\nUnsaved changes to it will be lost."
	dialog.ok_button_text = "Delete"
	add_child(dialog)
	dialog.confirmed.connect(func():
		dialog.queue_free()
		_delete_open_note()
	)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()

func _delete_open_note() -> void:
	if _current_rel == "":
		return
	var rel := _current_rel
	var reply = JSON.parse_string(str(GptyTerminal.vault_note_delete(vault_path, rel)))
	if not (reply is Dictionary) or reply.has("error"):
		ToastManager.warn(_note_failure("Could not delete", rel, reply), 5.0, "Wiki")
		return
	# A deliberate end: the buffer died with the note, so the crash copy must
	# not be offered back for a name the user just removed.
	_drop_scratch(vault_path, rel)
	_show_list()
	if not bool(reply.get("indexed", true)):
		ToastManager.warn("Deleted %s, but the search index could not be updated" % rel, 5.0, "Wiki")

## One toast line for a refused file verb: the pane names what it tried, and
## the store's message says why (`code` is the discriminator a caller would
## switch on, but here the message is already human text).
func _note_failure(prefix: String, rel: String, reply) -> String:
	var text := "%s %s" % [prefix, _shown_link(rel)]
	if reply is Dictionary and reply.has("error"):
		return text + ": " + _shown_link(str(reply["error"]))
	return text + ": no answer from the vault"

# ── The recovery copy: the buffer a crash would take ───────────────────

## Arm the recovery copy after an edit. The timer is not restarted by later
## edits (see `SCRATCH_DEBOUNCE`), and a clean buffer has nothing to keep: the
## copy it might have is the one a deliberate end already dropped.
func _touch_scratch() -> void:
	if _current_rel == "" or not _is_dirty():
		_scratch_timer.stop()
		return
	if _scratch_timer.is_stopped():
		_scratch_timer.start()

## Refresh the open note's recovery copy. Nothing here can reach the vault —
## the copy lives under gpty's own state directory, and `_save` is still the
## only caller of `vault_note_write`. A copy that cannot be written is not a
## user-facing failure (the buffer is on screen, and a disk that refuses this
## write fails the save loudly enough), so the Rust side logs it and the pane
## stays quiet.
func _write_scratch() -> void:
	if _current_rel == "" or not _is_dirty():
		return
	GptyTerminal.vault_scratch_write(
		vault_path, _current_rel, _editor.text, _loaded_mtime, _loaded_size
	)

## The recovery copy for `rel`, or {} when there is none.
func _read_scratch(rel: String) -> Dictionary:
	var answer = JSON.parse_string(str(GptyTerminal.vault_scratch_read(vault_path, rel)))
	if answer is Dictionary and bool(answer.get("found", false)):
		return answer
	return {}

## Forget the recovery copy of one note: its buffer either reached the file or
## was deliberately discarded, and a copy outliving that would offer the work
## back as if the user had never answered.
func _drop_scratch(root: String, rel: String) -> void:
	if rel == _current_rel:
		_scratch_timer.stop()
	if root == "" or rel == "":
		return
	GptyTerminal.vault_scratch_clear(root, rel)

## Offer the recovery copy a crash left behind, right after the note is on
## screen. Never automatic: the file is what the note says, and only an answer
## here changes what the editor holds.
##
##   Restore  the buffer comes back — dirty, and still carrying the stamp of
##            the revision it was typed against, so a file that moved on while
##            gpty was away gets the save's own conflict question first;
##   Discard  the copy goes;
##   Escape   "not now": the file stays, the copy stays, the next open asks
##            again.
func _offer_scratch(rel: String) -> void:
	if not _editable_note:
		# A note past the cap is read-only, so a restored buffer could never be
		# saved and the pane's close guard would not see it as unsaved work:
		# restoring would be a promise the pane cannot keep. The copy stays, for
		# whenever the note is editable again.
		return
	var copy := _read_scratch(rel)
	if copy.is_empty():
		return
	if str(copy.get("text", "")) == _saved_text:
		# A typed change that was undone: leftover, not a question.
		_drop_scratch(vault_path, rel)
		return
	var dialog := ConfirmationDialog.new()
	dialog.name = "RestoreConfirm"
	dialog.title = "Unsaved changes recovered"
	dialog.dialog_text = "%s had unsaved changes when gpty last closed.\n\nRestore them?" % rel
	dialog.ok_button_text = "Restore"
	dialog.add_button("Discard", true, "discard")
	add_child(dialog)
	_restore_copy = copy
	_restore_rel = rel
	dialog.confirmed.connect(_apply_restore.bind(dialog))
	dialog.custom_action.connect(_discard_restore.bind(dialog))
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()

## The Restore answer: put the recovered buffer back in the editor.
func _apply_restore(dialog: Window) -> void:
	dialog.queue_free()
	var rel := _restore_rel
	var copy := _restore_copy
	_restore_copy = {}
	_restore_rel = ""
	if rel == "" or rel != _current_rel:
		# The note was replaced under the question (a vault change from the
		# settings panel): this copy is not the open editor's to take.
		return
	# Setting `text` marks the buffer dirty through `_on_editor_changed` a frame
	# later; the stamp the copy carries is what a save then checks, so a file
	# that changed while gpty was away still gets the conflict question.
	_editor.text = str(copy.get("text", ""))
	_loaded_mtime = int(copy.get("mtime", 0))
	_loaded_size = int(copy.get("size", 0))
	_editor.scroll_vertical = 0
	_update_dirty()
	if _preview_visible():
		_reader.render_now(_preview_text())
	ToastManager.info("Restored unsaved changes to %s" % rel, 4.0, "Wiki")

## The Discard answer (the dialog's custom action): the user decided, so the
## question must not come back.
func _discard_restore(action: String, dialog: Window) -> void:
	if action != "discard":
		return
	dialog.queue_free()
	var rel := _restore_rel
	_restore_copy = {}
	_restore_rel = ""
	if rel != "":
		_drop_scratch(vault_path, rel)

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
			# The user just decided this buffer's fate: the recovery copy must
			# not offer it back at the next open.
			_drop_scratch(vault_path, _current_rel)
			answer.call(true)
	)
	dialog.canceled.connect(func():
		dialog.queue_free()
		answer.call(false)
	)
	dialog.popup_centered()

func _has_open_ask() -> bool:
	# Only a *visible* dialog is still being asked. `AcceptDialog` hides itself
	# before emitting `confirmed`/`canceled` (measured on 4.7.2), so the action
	# an answer starts may show its own question — the create-from-link flow
	# is a name prompt whose success asks the leave question for a dirty
	# buffer — while the answered dialog is still awaiting deletion.
	for dialog_name in [
		"DiscardConfirm", "OverwriteConfirm", "RestoreConfirm",
		"NoteNameConfirm", "DeleteConfirm", "UpdateReferencesConfirm",
		"WeightConfirm",
	]:
		var dialog := find_child(dialog_name, false, false) as Window
		if dialog != null and dialog.visible:
			return true
	return false

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
		# That discard is the user's answer by another route: the copy goes too,
		# and it is keyed by the vault the buffer belonged to.
		_drop_scratch(previous_vault, _current_rel)
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
