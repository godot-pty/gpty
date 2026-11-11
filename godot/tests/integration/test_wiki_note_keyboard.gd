extends GutTest
# The note toolbar from the keyboard — the v0.8.0 finding "The note toolbar is
# unreachable while the buffer has focus".
#
# The note view's controls became tab stops in "The keyboard cannot drive pane
# chrome or the Wiki pane", but that fix left a gap of its own: a focused
# `CodeEdit` keeps Tab for indentation, Escape leaves the note, and the toolbar
# sits *before* the editor in tree order, so while typing there was no path to
# Rename/Delete/Save or the three mode buttons at all. The fix copies the rule
# pane chrome got: the toolbar is one explicit ring, `Ctrl+Shift+K` is the way
# in from the buffer, Escape returns to the buffer (only a second Escape leaves
# the note), and entering the pane from its chrome aims at the buffer rather
# than at the pane's first control.

const WorkspaceScript = preload("res://scenes/terminal/workspace.gd")

## The toolbar's keyboard stops, in visual order. Labels (`NoteTitle`,
## `DirtyState`) are not stops, so the ring skips them.
const TOOLBAR_RING := [
	"Mode_edit", "Mode_split", "Mode_preview", "RenameNote", "DeleteNote", "Save",
]

var _ws: Control
var _vault: String


func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	# A vault path no other test (and no earlier run) has used: the recovery
	# copy a note's buffer leaves behind is keyed by vault path, and a leaked
	# one would raise a restore question that owns the keyboard.
	_vault = TestPaths.user_path("wiki_note_keyboard_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_vault)
	var note := FileAccess.open(_vault.path_join("note.md"), FileAccess.WRITE)
	note.store_string("# Note\n\nbody\n")
	note.close()


func after_each():
	for rel in ["note.md"]:
		GptyTerminal.vault_scratch_clear(_vault, rel)
	var dir := DirAccess.open(_vault)
	if dir:
		for f in dir.get_files():
			DirAccess.remove_absolute(_vault.path_join(f))
	DirAccess.remove_absolute(_vault)
	_vault = ""
	if _ws:
		if _ws.get_parent():
			_ws.get_parent().remove_child(_ws)
		_ws.free()
		_ws = null
	MockAutoloads.teardown()


func _make_workspace() -> Control:
	var ws: Control = WorkspaceScript.new()
	_ws = ws
	add_child(ws)
	ws.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	return ws


## A wiki pane on `_vault` with `note.md` open in the buffer — the state the
## finding is about: the user is typing.
func _open_wiki_note(ws: Control) -> WikiPane:
	# `activate := false` is the restore route: the pane is built without a user
	# gesture, exactly like a saved layout, so the startup terminal stays the
	# active pane while the note's editor takes the keyboard.
	var wiki = ws._spawn_pane_into(ws._active_workspace(), "wiki", {"vault_path": _vault}, false)
	assert_true(wiki is WikiPane, "the workspace holds a wiki pane")
	wiki._open_note("note.md")
	assert_true(wiki._note_box.visible, "precondition: the note view is shown")
	assert_eq(ws.get_viewport().gui_get_focus_owner(), wiki._editor,
		"precondition: the buffer holds the keyboard")
	# The active pane still names the startup terminal, so the chord has to
	# resolve the wiki pane from the focus owner - the state a real user reaches
	# by opening a note from the list. A `last_body`-only rule did nothing here
	# (measured).
	assert_ne(ws._tm.last_body, wiki, "precondition: the active pane is not the wiki")
	return wiki


func _press_key(keycode: Key, ctrl := false, shift := false) -> void:
	var down := InputEventKey.new()
	down.keycode = keycode
	down.physical_keycode = keycode
	down.ctrl_pressed = ctrl
	down.shift_pressed = shift
	down.pressed = true
	Input.parse_input_event(down)
	Input.flush_buffered_events()
	await get_tree().process_frame
	var up: InputEventKey = down.duplicate()
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()
	await get_tree().process_frame


func test_the_chord_enters_the_toolbar_and_escape_returns_to_the_buffer():
	var ws = await _make_workspace()
	var wiki := _open_wiki_note(ws)

	await _press_key(KEY_K, true, true)

	var owner := ws.get_viewport().gui_get_focus_owner()
	assert_not_null(owner, "Ctrl+Shift+K must focus a note-toolbar button")
	if owner == null:
		return
	assert_eq(String(owner.get_parent().name), "NoteToolbar", "focus lands in the note's toolbar")
	assert_eq(String(owner.name), "Mode_edit", "the toolbar is entered at its first action")

	await _press_key(KEY_ESCAPE)

	assert_eq(ws.get_viewport().gui_get_focus_owner(), wiki._editor,
		"Escape gives the keyboard back to the buffer")
	assert_true(wiki._note_box.visible,
		"returning to the buffer must not leave the note")

	# And the buffer's own Escape still means Back, so the ladder ends: the
	# note closes and the list takes the keyboard.
	await _press_key(KEY_ESCAPE)
	assert_false(wiki._note_box.visible, "the second Escape leaves the note")
	assert_true(wiki._list.visible, "the list is back")
	assert_eq(ws.get_viewport().gui_get_focus_owner(), wiki._list,
		"the list takes the keyboard back")


func test_the_note_toolbar_is_one_explicit_ring_in_both_directions():
	var ws = await _make_workspace()
	var wiki := _open_wiki_note(ws)
	var row: HBoxContainer = wiki._toolbar

	var stops := []
	for child in row.get_children():
		if child is Control and (child as Control).focus_mode != Control.FOCUS_NONE:
			stops.append(child)
	var names := []
	for c in stops:
		names.append(String(c.name))
	assert_eq(names, TOOLBAR_RING, "the ring is the modes, Rename, Delete and Save")

	for i in stops.size():
		var b: Control = stops[i]
		var next: Control = stops[(i + 1) % stops.size()]
		var prev: Control = stops[(i - 1 + stops.size()) % stops.size()]
		assert_eq(b.get_node(b.focus_next), next,
			"%s must tab to %s" % [b.name, next.name])
		assert_eq(b.get_node(b.focus_previous), prev,
			"%s must shift-tab to %s" % [b.name, prev.name])


func test_the_chord_is_inert_without_a_buffer_on_screen():
	var ws = await _make_workspace()
	var wiki: WikiPane = ws._spawn_pane("wiki", {"vault_path": _vault})
	ws.activate_pane(wiki)

	# The list view: no note open, so there is no buffer to come back from.
	wiki._list.grab_focus()
	await _press_key(KEY_K, true, true)
	assert_eq(ws.get_viewport().gui_get_focus_owner(), wiki._list,
		"with no note open the chord must not move the keyboard")

	# Preview mode hides the buffer: its Tab trap does not exist, so the chord
	# must not claim a keyboard state the view cannot return from.
	wiki._open_note("note.md")
	wiki._set_view_mode("preview")
	assert_false(wiki._editor.visible, "precondition: the buffer is hidden")
	wiki._back.grab_focus()
	await _press_key(KEY_K, true, true)
	assert_eq(ws.get_viewport().gui_get_focus_owner(), wiki._back,
		"in preview mode the chord must not move the keyboard")


func test_entering_the_pane_from_its_chrome_aims_at_the_buffer():
	# `PaneBody.keyboard_entry`: a wiki pane in a note hands the keyboard to
	# its buffer, not to the first control in tree order (Back, a top-row
	# action) — the note view's entry point is the text being read.
	var ws = await _make_workspace()
	var wiki := _open_wiki_note(ws)
	assert_true(ws._tm.focus_title_bar(wiki), "the pane's bar takes the keyboard")

	await _press_key(KEY_ESCAPE)

	assert_eq(ws.get_viewport().gui_get_focus_owner(), wiki._editor,
		"Escape from chrome lands in the note's buffer")
