extends GutTest
# Wiki pane: the read-only vault browser — vault validation, the indexed note
# list (`GptyTerminal.vault_index`), the index-backed search
# (`GptyTerminal.vault_search`), the note render, and the layout-state round
# trip. The walk's own rules (hidden skip, depth/entry caps, staleness) are
# pinned by `gpty_core::vault`'s unit tests; this file asserts the pane's view
# of that index.

var _tmp: String
## The recovery-copy tests' own vault. A copy is keyed by the vault path, so
## the run's ticks make that key unreachable from any later run: a copy leaked
## by an interrupted suite can never be offered to somebody else's pane.
var _scratch_tmp: String


func before_each():
	MockAutoloads.setup()
	_tmp = TestPaths.fresh_dir("wiki_probe_vault")
	_scratch_tmp = TestPaths.user_path(
		"wiki_probe_scratch_%d" % Time.get_ticks_usec()
	)
	DirAccess.make_dir_recursive_absolute(_scratch_tmp)


func after_each():
	# Recovery copies live in gpty's state directory, not under the probe vault,
	# so removing the tree does not remove them — clear them first, while the
	# vault they are keyed to still exists.
	for rel in ["note.md", "big.md", "moved.md"]:
		GptyTerminal.vault_scratch_clear(_scratch_tmp, rel)
	TestPaths.remove_tree(_scratch_tmp)
	TestPaths.remove_tree(TestPaths.user_path("wiki_probe_outside"))
	TestPaths.remove_tree(_tmp)
	MockAutoloads.teardown()


func _write(path: String, text: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	return path


## Read a file's text and release the handle before returning. A test must not
## hold a `FileAccess` across a save: GDScript keeps the object alive until its
## variable is reassigned, and on Windows an open handle (opened without delete
## sharing) makes the save's rename over that file fail with "Access is denied"
## — which is what `windows-smoke` measured on the overwrite-confirm tests.
func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	assert_not_null(f, "%s must be readable" % path)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


func _make_pane(vault: String, saved_view := true) -> WikiPane:
	var pane := WikiPane.new()
	# A saved notes view keeps this suite's list/note subject. Pass false for a
	# pane whose spawn settings name no view: that pane opens the graph by
	# default, the behaviour the default-view test owns.
	if saved_view:
		pane.apply_settings({"vault_path": vault, "graph": false})
	else:
		pane.vault_path = vault
	# vault_path is set before add_child so _ready performs the index pass.
	add_child_autofree(pane)
	return pane


## Wait for the graph build to land: the query, the model and the layout run on
## a worker thread, so a test that wants the canvas has to let the pane's own
## poll run.
func _settle_graph(pane: WikiPane) -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while pane._graph_task != -1 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	assert_eq(pane._graph_task, -1, "the graph build must land")


## Ask for the graph and wait for it.
func _open_graph(pane: WikiPane) -> void:
	assert_eq(pane.request_graph(), "", "this vault must accept a graph build")
	await _settle_graph(pane)


func _list_texts(pane: WikiPane) -> Array:
	var out := []
	for i in pane._list.item_count:
		out.append(pane._list.get_item_text(i))
	return out


func _list_meta(pane: WikiPane) -> Array:
	var out := []
	for i in pane._list.item_count:
		out.append(pane._list.get_item_metadata(i))
	return out


func test_pane_type_is_wiki():
	var pane := _make_pane("")
	assert_eq(pane._pane_type(), "wiki")


func test_unset_vault_shows_placeholder():
	var pane := _make_pane("")
	assert_true(pane._placeholder.visible)
	assert_false(pane._list.visible)
	assert_eq(pane._list.item_count, 0)
	# A search box is meaningless without a vault.
	assert_false(pane._search.visible)


func test_a_non_directory_vault_is_refused():
	_write(_tmp.path_join("note.md"), "# hi")
	# A regular file is not a vault, and neither is a relative path; the typed
	# value stays (file_tree's rule) so the settings field keeps the typo.
	var file_pane := _make_pane(_tmp.path_join("note.md"))
	assert_true(file_pane._placeholder.visible)
	assert_eq(file_pane._list.item_count, 0)
	assert_eq(file_pane.vault_path, _tmp.path_join("note.md"))

	var relative_pane := _make_pane("not/absolute")
	assert_true(relative_pane._placeholder.visible)
	assert_eq(relative_pane._list.item_count, 0)
	assert_eq(relative_pane.vault_path, "not/absolute")


## `user://` and `res://` are absolute to Godot but virtual: `DirAccess` would
## open them and the vault API would answer its own refusal ("not an absolute
## path") one call later. Reproduced on the v0.7.1 download, where the shipped
## knowledge base resolved to `user://knowledge/<hash>` and the pane's guard
## passed it through.
func test_a_godot_virtual_vault_path_is_refused():
	for path in ["user://wiki_probe_virtual", "res://wiki_probe_virtual"]:
		var pane := _make_pane(path)
		assert_true(pane._placeholder.visible, "%s must not be a vault" % path)
		assert_eq(pane._list.item_count, 0, path)
		assert_string_contains(pane._placeholder.text, "Not a vault directory")
		assert_eq(pane.vault_path, path, "the typed value stays so it can be fixed")


func test_lists_markdown_notes_recursively_and_skips_hidden():
	_write(_tmp.path_join("note.md"), "# Heading")
	DirAccess.make_dir_recursive_absolute(_tmp.path_join("sub"))
	_write(_tmp.path_join("sub").path_join("nested.md"), "# Nested")
	DirAccess.make_dir_recursive_absolute(_tmp.path_join(".hidden"))
	_write(_tmp.path_join(".hidden").path_join("secret.md"), "# Secret")
	_write(_tmp.path_join("top.txt"), "not a note")

	var pane := _make_pane(_tmp)
	assert_false(pane._placeholder.visible)
	assert_eq(
		_list_texts(pane),
		["note.md", "sub".path_join("nested.md")],
		"only .md notes, hidden dirs skipped, sorted",
	)
	var meta := _list_meta(pane)
	assert_eq(meta.size(), 2, "both notes are listed")
	if meta.is_empty():
		return
	assert_eq(meta[0], "note.md", "a row carries the vault-relative path")


## A symlink that resolves outside the vault is not a note of the vault: the
## walk refuses it (the same rule the reader and a save enforce), and the
## footer says a link was skipped so the note is not silently missing.
func test_the_list_skips_a_link_out_of_the_vault_and_says_so():
	if OS.get_name() == "Windows":
		pending("creating a symlink needs a privilege the test runner does not hold")
		return
	var outside := TestPaths.user_path("wiki_probe_outside")
	DirAccess.make_dir_recursive_absolute(outside)
	_write(outside.path_join("secret.md"), "# Secret")
	_write(_tmp.path_join("note.md"), "# Note")
	var dir := DirAccess.open(_tmp)
	assert_not_null(dir, "the probe vault must be openable")
	assert_eq(
		dir.create_link(outside.path_join("secret.md"), _tmp.path_join("link.md")),
		OK,
		"the probe must be able to plant a symlink",
	)

	var pane := _make_pane(_tmp)
	assert_eq(_list_texts(pane), ["note.md"], "a link out of the vault is not listed")
	assert_true(pane._footer.visible, "the skip must be reported, not silent")
	assert_string_contains(pane._footer.text, "pointing outside this vault")


func test_activating_a_note_renders_it_and_back_returns():
	_write(_tmp.path_join("note.md"), "# Heading\n\nbody")
	var pane := _make_pane(_tmp)

	pane._list.item_activated.emit(0)
	assert_true(pane._reader.visible)
	assert_true(pane._notes_button.visible)
	assert_false(pane._list.visible)
	assert_eq(pane._editor.text, "# Heading\n\nbody", "the editor holds the note")
	assert_false(pane._search.visible, "the note view owns the pane's top row")
	assert_string_contains(pane._reader.get_parsed_text(), "Heading")

	pane._notes_button.pressed.emit()
	assert_true(pane._list.visible)
	assert_false(pane._reader.visible)
	assert_false(pane._notes_button.visible)
	assert_true(pane._search.visible, "the search box comes back with the list")


func test_search_filters_the_list_to_matching_notes():
	_write(_tmp.path_join("alpha.md"), "# Alpha\napples are red")
	_write(_tmp.path_join("beta.md"), "# Beta\nbananas are yellow")
	var pane := _make_pane(_tmp)
	assert_eq(pane._list.item_count, 2)

	pane._search.text = "bananas"
	pane._run_search()
	assert_eq(pane._list.item_count, 1, "only the matching note is listed")
	var meta := _list_meta(pane)
	var hits := _list_texts(pane)
	assert_eq(meta.size(), 1, "the one hit is the row under test")
	assert_eq(hits.size(), 1, "the one hit is the row under test")
	if meta.is_empty() or hits.is_empty():
		return
	assert_eq(meta[0], "beta.md")
	assert_string_contains(hits[0], "Beta", "the hit shows its title")
	assert_string_contains(hits[0], "banana", "the hit shows its snippet")

	# Clearing the query restores the full list.
	pane._search.text = ""
	pane._run_search()
	assert_eq(pane._list.item_count, 2)


func test_a_search_with_no_match_says_so():
	_write(_tmp.path_join("alpha.md"), "# Alpha\napples")
	var pane := _make_pane(_tmp)

	pane._search.text = "zebra"
	pane._run_search()
	assert_eq(pane._list.item_count, 0)
	assert_true(pane._placeholder.visible)
	# A zero-hit search must not be a dead end: the box stays so the query can
	# be amended, and clearing it brings the vault back.
	assert_true(pane._search.visible, "the query must stay editable")
	assert_true(pane._search.clear_button_enabled, "and clearable")
	pane._search.text = ""
	pane._run_search()
	assert_false(pane._placeholder.visible)
	assert_eq(_list_texts(pane), ["alpha.md"], "clearing the query restores the list")


func test_layout_state_carries_the_vault_path():
	_write(_tmp.path_join("note.md"), "# N")
	var pane := _make_pane(_tmp)
	var state: Dictionary = pane._get_layout_state()
	assert_eq(state.get("type"), "wiki")
	assert_eq(state.get("vault_path"), _tmp)


func test_apply_settings_rescans_and_keeps_an_invalid_path():
	_write(_tmp.path_join("note.md"), "# N")
	var pane := _make_pane("")
	assert_true(pane._placeholder.visible)

	pane.apply_settings({"vault_path": _tmp})
	assert_false(pane._placeholder.visible)
	assert_eq(_list_texts(pane), ["note.md"])

	pane.apply_settings({"vault_path": "relative/path"})
	assert_true(pane._placeholder.visible)
	assert_eq(pane.vault_path, "relative/path")

# ── Editing: the buffer, the save, and the guards ──────────────────────

func _dialogs_of(node: Node) -> Array:
	var out := []
	for child in node.get_children():
		if child is ConfirmationDialog:
			out.append(child)
	return out


## Replace the editor's buffer the way a user does. `text = …` is Godot's
## programmatic path — `_set_text(p_text, false)`, which emits `text_set` and
## never `text_changed` — so a test driving it would not exercise the live
## preview at all; a user's edit goes through `insert_text_at_caret`, whose
## `text_changed` is emitted one frame later.
func _type_into(pane: WikiPane, text: String) -> void:
	pane._editor.select_all()
	pane._editor.insert_text_at_caret(text)
	await wait_process_frames(1)


## Dispatch Escape the way a keyboard does: through the GUI, from the control
## that holds focus. The pane handles it in `_gui_input`, reached only by that
## bubbling, so this proves the path a real key takes rather than calling the
## handler directly.
func _escape() -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.physical_keycode = KEY_ESCAPE
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
	await wait_process_frames(1)
	var up: InputEventKey = ev.duplicate()
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()
	await wait_process_frames(1)


func _all_controls(node: Node, out: Array = []) -> Array:
	if node is Control:
		out.append(node)
	for child in node.get_children():
		_all_controls(child, out)
	return out


func test_opening_a_note_gives_the_keyboard_to_the_buffer():
	_write(_tmp.path_join("note.md"), "# Note\n")
	var pane := _make_pane(_tmp)
	pane._list.item_activated.emit(0)
	assert_eq(pane.get_viewport().gui_get_focus_owner(), pane._editor,
		"the buffer takes the keyboard when a note opens")


func test_escape_returns_from_a_note_to_the_list_without_writing():
	var path := _write(_tmp.path_join("note.md"), "# Note\n")
	var pane := _make_pane(_tmp)
	pane._list.item_activated.emit(0)
	assert_true(pane._note_box.visible)

	await _escape()

	assert_false(pane._note_box.visible, "Escape leaves the note")
	assert_true(pane._list.visible, "the list is back")
	assert_eq(_read(path), "# Note\n", "leaving must not write the note")
	assert_eq(pane.get_viewport().gui_get_focus_owner(), pane._list,
		"the list takes the keyboard back")


func test_escape_from_a_dirty_note_asks_first_and_cancel_keeps_it():
	var path := _write(_tmp.path_join("note.md"), "# Note\n")
	var pane := _make_pane(_tmp)
	pane._list.item_activated.emit(0)
	await _type_into(pane, "# Edited\n")

	await _escape()

	assert_true(pane._note_box.visible, "the note stays until the user answers")
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "Escape on a dirty note must ask first")
	if dialogs.is_empty():
		return
	dialogs[0].canceled.emit()
	await wait_process_frames(1)
	assert_true(pane._note_box.visible, "canceling keeps the note")
	assert_eq(_read(path), "# Note\n", "a canceled Escape writes nothing")
	assert_eq(_dialogs_of(pane).size(), 0, "the question closes with the answer")


func test_no_visible_wiki_action_is_mouse_only():
	# A note with a link so the link rows exist too: they are actions (open the
	# target) and must not be pointer-only.
	_write(_tmp.path_join("other.md"), "# Other\n")
	_write(_tmp.path_join("note.md"), "# Note\n\n[[other]]\n")
	var pane := _make_pane(_tmp)
	pane._list.item_activated.emit(0)
	await wait_process_frames(1)

	var mouse_only: Array[String] = []
	for c in _all_controls(pane):
		# A declared mouse-only control is answered elsewhere (the scroll
		# chevrons are the wheel and PageUp/PageDown); this test is about
		# actions that are pointer-only by accident.
		if c is BaseButton and c.is_visible_in_tree() \
				and c.focus_mode == Control.FOCUS_NONE \
				and KeyboardFocus.mouse_only_reason(c) == "" \
				and not (c as BaseButton).disabled:
			mouse_only.append(str(c.name))
	assert_eq(mouse_only, [],
		"every visible wiki action needs a keyboard path: %s" % [mouse_only])


func test_opening_a_note_fills_the_editor_and_saving_writes_it_back():
	_write(_tmp.path_join("note.md"), "# One\n\nbody\n")
	var pane := _make_pane(_tmp)

	pane._list.item_activated.emit(0)
	assert_eq(pane._current_rel, "note.md")
	assert_eq(pane._editor.text, "# One\n\nbody\n")
	assert_true(pane._editor.editable, "a note under the cap is editable")
	assert_false(pane._is_dirty())

	await _type_into(pane, "# Two\n\nedited\n")
	assert_true(pane._is_dirty(), "typing marks the note dirty")
	assert_true(pane._dirty_label.visible)
	assert_false(pane._save_button.disabled)

	pane._save()
	assert_false(pane._is_dirty(), "a save clears the dirty state")
	assert_false(pane._dirty_label.visible)
	assert_true(pane._save_button.disabled, "there is nothing to save when clean")
	assert_eq(_read(_tmp.path_join("note.md")), "# Two\n\nedited\n",
		"the save must reach the file")


func test_the_preview_follows_the_buffer_live():
	_write(_tmp.path_join("note.md"), "# First\n")
	var pane := _make_pane(_tmp)
	pane._reader.settle_delay = 0.05
	pane._list.item_activated.emit(0)
	assert_eq(pane.view_mode, "split", "split is the default view")
	assert_true(pane._editor.visible and pane._reader.visible)

	await _type_into(pane, "# Renamed\n\nlive body\n")
	await wait_seconds(0.2)  # the preview settles once the edit stops
	assert_string_contains(pane._reader.get_parsed_text(), "Renamed",
		"the preview must render the buffer, not the file")
	assert_string_contains(pane._reader.get_parsed_text(), "live body")


func test_a_settled_preview_waits_for_the_typing_to_stop():
	# The preview renders on settle, not on the streaming throttle: every edit
	# restarts its window, so a typing run over a large note never queues the
	# render (and the label's shape pass that follows it) under the user's
	# fingers — a throttle would have rendered 75 ms after the first edit.
	_write(_tmp.path_join("note.md"), "# First\n")
	var pane := _make_pane(_tmp)
	# The window is wall-clock, so the margins are sized for a loaded CI runner
	# rather than for the assertion: each check below sits 0.4 s inside the
	# window it is about (`windows-smoke` measured a 0.1 s margin losing to
	# frame hitches — the preview rendered "Second" inside what the test
	# believed was still the quiet window).
	pane._reader.settle_delay = 1.0
	pane._list.item_activated.emit(0)
	assert_string_contains(pane._reader.get_parsed_text(), "First",
		"opening the note shows the buffer at once")

	await _type_into(pane, "# Second\n")
	await wait_seconds(0.6)
	assert_string_contains(pane._reader.get_parsed_text(), "First",
		"a render inside the quiet window is what the settle exists to prevent")

	# 1.2 s after the first edit — past its window — but only 0.6 s after this
	# one: a preview that rendered here did not restart the window on the edit.
	await _type_into(pane, "# Third\n")
	await wait_seconds(0.6)
	assert_string_contains(pane._reader.get_parsed_text(), "First",
		"each edit restarts the window")

	# Wait on the render itself rather than on a second guess at the clock.
	watch_signals(pane._reader)
	await wait_for_signal(pane._reader.rendered, 3.0)
	assert_signal_emitted(pane._reader, "rendered")
	assert_string_contains(pane._reader.get_parsed_text(), "Third",
		"once the buffer is quiet the preview catches up")


func test_view_modes_show_the_editor_and_preview_independently():
	_write(_tmp.path_join("note.md"), "# N\n")
	var pane := _make_pane(_tmp)
	pane._list.item_activated.emit(0)

	pane._set_view_mode("edit")
	assert_true(pane._editor.visible)
	assert_false(pane._reader.visible)

	pane._set_view_mode("preview")
	assert_false(pane._editor.visible)
	assert_true(pane._reader.visible)
	assert_true(pane._mode_buttons["preview"].button_pressed)
	assert_false(pane._mode_buttons["split"].button_pressed)

	pane._set_view_mode("split")
	assert_true(pane._editor.visible and pane._reader.visible)


func test_back_with_unsaved_changes_asks_before_discarding():
	_write(_tmp.path_join("note.md"), "# Note\n")
	var pane := _make_pane(_tmp)
	pane._list.item_activated.emit(0)
	await _type_into(pane, "# Edited\n")

	pane._notes_button.pressed.emit()
	assert_true(pane._note_box.visible, "the note stays open until the user answers")
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "leaving a dirty note must ask first")
	if dialogs.is_empty():
		return
	assert_string_contains(dialogs[0].dialog_text, "note.md")

	dialogs[0].canceled.emit()
	await get_tree().process_frame
	assert_true(pane._note_box.visible, "canceling keeps the note")
	assert_eq(_dialogs_of(pane).size(), 0, "the question closes with the answer")

	pane._notes_button.pressed.emit()
	dialogs = _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	dialogs[0].custom_action.emit("discard")
	assert_false(pane._note_box.visible, "discarding returns to the list")
	assert_true(pane._list.visible)
	assert_eq(_read(_tmp.path_join("note.md")), "# Note\n",
		"discarding must not write the note")


func test_back_can_save_the_note_and_leave():
	_write(_tmp.path_join("note.md"), "# Note\n")
	var pane := _make_pane(_tmp)
	pane._list.item_activated.emit(0)
	await _type_into(pane, "# Edited\n")

	pane._notes_button.pressed.emit()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	assert_eq(dialogs[0].ok_button_text, "Save", "the first answer is Save")
	dialogs[0].confirmed.emit()
	await wait_process_frames(2)  # the save runs after the dialog is freed
	assert_false(pane._note_box.visible, "saving lets the pane move on")
	assert_eq(_read(_tmp.path_join("note.md")), "# Edited\n",
		"and the note reached the file")


# ── The close contract ─────────────────────────────────────────────────

func test_request_close_asks_a_dirty_pane_and_a_cancel_keeps_it():
	_write(_tmp.path_join("note.md"), "# Note\n")
	var pane := _make_pane(_tmp)
	pane._list.item_activated.emit(0)
	await _type_into(pane, "# Edited\n")

	var answers := []
	pane.request_close(func(proceed: bool): answers.append(proceed))
	assert_eq(answers, [], "the answer must not land before the user gives it")
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "a close over unsaved work must ask")
	if dialogs.is_empty():
		return

	dialogs[0].canceled.emit()
	assert_eq(answers, [false], "canceling reports that the pane may not go")


func test_request_close_lets_a_clean_pane_go_immediately():
	_write(_tmp.path_join("note.md"), "# Note\n")
	var pane := _make_pane(_tmp)
	pane._list.item_activated.emit(0)

	var answers := []
	pane.request_close(func(proceed: bool): answers.append(proceed))
	assert_eq(answers, [true], "a clean pane never asks")
	assert_eq(_dialogs_of(pane).size(), 0)


func test_request_close_saves_before_it_lets_the_pane_go():
	_write(_tmp.path_join("note.md"), "# Note\n")
	var pane := _make_pane(_tmp)
	pane._list.item_activated.emit(0)
	await _type_into(pane, "# Edited\n")

	var answers := []
	pane.request_close(func(proceed: bool): answers.append(proceed))
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	dialogs[0].confirmed.emit()
	await wait_process_frames(2)  # the save runs after the dialog is freed
	assert_eq(answers, [true], "a successful save lets the pane go")
	assert_eq(_read(_tmp.path_join("note.md")), "# Edited\n",
		"and the buffer was written first")


func test_request_close_asks_again_when_the_save_hits_a_conflict():
	_write(_tmp.path_join("note.md"), "# Mine\n")
	var pane := _make_pane(_tmp)
	pane._list.item_activated.emit(0)
	await _type_into(pane, "# Mine, overwritten\n")
	# Another writer touches the note between the load and the close.
	_write(_tmp.path_join("note.md"), "# Theirs, and longer\n")

	var answers := []
	pane.request_close(func(proceed: bool): answers.append(proceed))
	var first := _dialogs_of(pane)
	assert_eq(first.size(), 1, "the save question comes before the conflict")
	if first.is_empty():
		return
	first[0].confirmed.emit()  # Save
	await wait_process_frames(2)  # the save runs after the dialog is freed
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the conflict must be asked about before closing")
	if dialogs.is_empty():
		return
	assert_eq(dialogs[0].name, "OverwriteConfirm")
	assert_eq(answers, [], "the pane may not go until the conflict is answered")

	dialogs[0].canceled.emit()
	assert_eq(answers, [false], "canceling the overwrite cancels the close")


func test_has_unsaved_state_follows_the_buffer():
	_write(_tmp.path_join("note.md"), "# Note\n")
	var pane := _make_pane(_tmp)
	assert_false(pane.has_unsaved_state(), "an unopened note holds nothing")

	pane._list.item_activated.emit(0)
	assert_false(pane.has_unsaved_state(), "a freshly opened note is clean")
	await _type_into(pane, "# Edited\n")
	assert_true(pane.has_unsaved_state(), "a typed buffer is unsaved work")

	pane._save()
	assert_false(pane.has_unsaved_state(), "saving clears it")


func test_a_save_that_would_overwrite_an_outside_edit_asks_first():
	_write(_tmp.path_join("note.md"), "# Mine\n")
	var pane := _make_pane(_tmp)
	pane._list.item_activated.emit(0)

	# Another writer touches the note. A different size guarantees the stamp
	# differs even on a filesystem with coarse mtime granularity.
	_write(_tmp.path_join("note.md"), "# Theirs, and longer\n")
	await _type_into(pane, "# Mine, overwritten\n")

	pane._save()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "an outside edit must be confirmed before overwriting")
	if dialogs.is_empty():
		return
	assert_string_contains(dialogs[0].dialog_text, "changed on disk")
	assert_string_contains(_read(_tmp.path_join("note.md")), "Theirs",
		"nothing is written before the answer")

	dialogs[0].confirmed.emit()
	await wait_process_frames(2)  # the save runs after the dialog is freed
	assert_string_contains(_read(_tmp.path_join("note.md")), "Mine, overwritten",
		"confirming writes the pane's version")
	assert_false(pane._is_dirty())


func test_saving_reindexes_so_the_new_text_is_searchable():
	_write(_tmp.path_join("note.md"), "# Note\n\nnothing here\n")
	var pane := _make_pane(_tmp)
	pane._list.item_activated.emit(0)

	await _type_into(pane, "# Note\n\nzebra crossing\n")
	pane._save()

	pane._notes_button.pressed.emit()
	pane._search.text = "zebra"
	pane._run_search()
	assert_eq(pane._list.item_count, 1, "a saved note must be searchable without a restart")
	var meta := _list_meta(pane)
	assert_eq(meta.size(), 1, "the saved note is the one row")
	if meta.is_empty():
		return
	assert_eq(meta[0], "note.md")


func test_a_note_past_the_cap_is_read_only():
	var big = FileAccess.open(_tmp.path_join("big.md"), FileAccess.WRITE)
	big.store_string("x".repeat(TextRead.DEFAULT_MAX_BYTES + 1))
	big.close()
	var pane := _make_pane(_tmp)

	pane._list.item_activated.emit(0)
	assert_false(pane._editable_note, "a truncated read must not be editable")
	assert_false(pane._editor.editable)
	assert_true(pane._save_button.disabled)
	assert_true(pane._dirty_label.visible, "the pane must say why it is read-only")
	assert_string_contains(pane._dirty_label.text, "larger than",
		"the read-only reason belongs next to the editor")
	assert_eq(pane.view_mode, "split")
	# The preview is told which cut the pane made, and says it above the body:
	# a note at the read cap is at the renderer's cap too, so a notice appended
	# to the source is the first thing that cut would drop.
	assert_true(pane._reader.get_parsed_text().begins_with("… truncated"),
		"the preview must announce the cut before the body")
	assert_string_contains(pane._reader.get_parsed_text(),
		String.humanize_size(TextRead.DEFAULT_MAX_BYTES),
		"and name how much of the file it is showing")


func test_crlf_endings_survive_an_edit():
	_write(_tmp.path_join("note.md"), "# One\r\nline\r\n")
	var pane := _make_pane(_tmp)
	pane._list.item_activated.emit(0)
	assert_true(pane._crlf, "the file's endings must be remembered")
	assert_eq(pane._editor.text, "# One\nline\n", "the editor works in LF")

	await _type_into(pane, "# Two\nline\n")
	pane._save()
	assert_eq(_read(_tmp.path_join("note.md")), "# Two\r\nline\r\n",
		"the save must put the CRLFs back")


func test_a_vault_change_drops_the_open_note():
	_write(_tmp.path_join("note.md"), "# N\n")
	var pane := _make_pane(_tmp)
	pane._list.item_activated.emit(0)
	await _type_into(pane, "# Edited\n")

	var other := TestPaths.user_path("wiki_probe_vault_other")
	DirAccess.make_dir_recursive_absolute(other)
	pane.apply_settings({"vault_path": other})
	assert_eq(pane._current_rel, "", "a different vault must not keep the old note")
	assert_false(pane._editor.editable)
	assert_true(pane._placeholder.visible, "the new vault is empty")
	TestPaths.remove_tree(other)


func test_layout_state_carries_the_note_view_mode():
	_write(_tmp.path_join("note.md"), "# N\n")
	var pane := _make_pane(_tmp)
	pane._set_view_mode("preview")
	var state: Dictionary = pane._get_layout_state()
	assert_eq(state.get("view_mode"), "preview")
	assert_eq(state.get("vault_path"), _tmp)

	# An unknown mode from an untrusted file keeps the pane's own default.
	var restored := _make_pane(_tmp)
	restored.apply_settings({"vault_path": _tmp, "view_mode": "hologram"})
	assert_eq(restored.view_mode, "split")
	restored.apply_settings({"view_mode": "edit"})
	assert_eq(restored.view_mode, "edit")

func test_layout_state_carries_the_open_note_and_graph():
	_write(_tmp.path_join("note.md"), "# N\n")
	var pane := _make_pane(_tmp)
	var state: Dictionary = pane._get_layout_state()
	assert_eq(state.get("open_note"), "", "the list view names no note")
	assert_false(bool(state.get("graph")))

	pane._open_note("note.md")
	state = pane._get_layout_state()
	assert_eq(state.get("open_note"), "note.md")
	assert_false(bool(state.get("graph")))

	# The pending build is the user's answer too: a save in the frame after
	# the request must not record the canvas as closed.
	pane.request_graph()
	state = pane._get_layout_state()
	assert_true(bool(state.get("graph")))
	await _settle_graph(pane)


func test_a_layout_reopens_the_note_and_the_graph():
	_write(_tmp.path_join("note.md"), "# N\nbody\n")
	_write(_tmp.path_join("other.md"), "# O\n[[note]]\n")
	var pane := WikiPane.new()
	pane.apply_settings({"vault_path": _tmp, "open_note": "note.md"})
	add_child_autofree(pane)
	assert_true(pane._note_box.visible, "the saved note is open")
	assert_eq(pane._current_rel, "note.md")
	assert_false(pane._graph_view.visible)

	var graphed := WikiPane.new()
	graphed.apply_settings({"vault_path": _tmp, "graph": true})
	add_child_autofree(graphed)
	# The graph is built off the frame, so the restore request is what is true
	# at once; the canvas follows when the build lands.
	assert_true(graphed._graph_wanted, "the saved graph view must be requested")
	await _settle_graph(graphed)
	assert_true(graphed._graph_view.visible, "the saved graph view is showing")


func test_restore_is_spawn_time_only_and_tolerates_a_missing_note():
	_write(_tmp.path_join("note.md"), "# N\n")
	var pane := _make_pane(_tmp)
	# The settings panel re-applies its whole dict: that must not open anything.
	pane.apply_settings({"vault_path": _tmp, "open_note": "note.md", "graph": true})
	assert_false(pane._note_box.visible)
	assert_false(pane._graph_view.visible)

	# A note that has since been deleted leaves the list, not a broken view.
	var gone := WikiPane.new()
	gone.apply_settings({"vault_path": _tmp, "open_note": "deleted.md"})
	add_child_autofree(gone)
	assert_false(gone._note_box.visible)
	assert_true(gone._list.visible)

	# An oversized or mistyped value is ignored, not trusted.
	var junk := WikiPane.new()
	junk.apply_settings({"vault_path": _tmp, "open_note": "x".repeat(600), "graph": "yes"})
	add_child_autofree(junk)
	assert_false(junk._note_box.visible)
	assert_false(junk._graph_view.visible)


func test_layout_state_carries_the_graph_mode_and_positions():
	_seed_linked_vault()
	var pane := _make_pane(_tmp)
	pane.graph_mode = "3d"
	pane._apply_graph_mode()
	await _open_graph(pane)
	assert_true(pane._graph_view is VaultGraph3D, "the explicit mode is the orbital map")
	var view := pane._graph_view as VaultGraph3D
	var start: Vector2 = view.positions["a.md"]
	view._begin_drag("a.md")
	view._drag_to("a.md", start + Vector2(120.0, 80.0))
	view._finish_drag(false)

	var state: Dictionary = pane._get_layout_state()
	assert_eq(str(state.get("graph_mode", "")), "3d")
	var saved: Dictionary = state.get("graph_positions", {})
	assert_true(saved.has("a.md"), "the dragged note's place rides the state")
	assert_almost_eq(float(saved["a.md"][0]), start.x + 120.0, 0.2)
	var tile := PaneTypes.sanitize_tile({
		"settings": state, "col": 0, "row": 0,
		"cspan": PaneTypes.GRID, "rspan": PaneTypes.GRID,
	})
	assert_eq(tile.get("dropped", PackedStringArray()).size(), 0,
		"the saved block survives the closed table")
	assert_eq(str(tile["settings"].get("graph_mode", "")), "3d")


func test_a_layout_restores_graph_positions_and_ignores_missing_notes():
	_write(_tmp.path_join("a.md"), "# A\n\n[[b]]\n")
	_write(_tmp.path_join("b.md"), "# B\n\n[[a]]\n")
	var pane := WikiPane.new()
	pane.apply_settings({
		"vault_path": _tmp, "graph": true, "graph_mode": "3d",
		"graph_positions": {"a.md": [300.0, 400.0], "gone.md": [10.0, 10.0]},
	})
	add_child_autofree(pane)
	await _settle_graph(pane)
	assert_true(pane._graph_view.visible, "the saved graph view is showing")
	assert_true(pane._graph_view is VaultGraph3D)
	var positions: Dictionary = pane._graph_view.positions
	assert_true(positions.has("a.md"))
	assert_false(positions.has("gone.md"), "a note the vault no longer has is ignored")
	var point: Vector2 = positions["a.md"]
	assert_almost_eq(point.x, 300.0, 0.11)
	assert_almost_eq(point.y, 400.0, 0.11)


func test_switching_the_graph_mode_keeps_the_arrangement():
	_seed_linked_vault()
	var pane := _make_pane(_tmp)
	pane.graph_mode = "3d"
	pane._apply_graph_mode()
	await _open_graph(pane)
	var view := pane._graph_view as VaultGraph3D
	var start: Vector2 = view.positions["a.md"]
	view._begin_drag("a.md")
	view._drag_to("a.md", start + Vector2(90.0, 40.0))
	view._finish_drag(false)
	var dropped: Vector2 = view.positions["a.md"]

	pane.graph_mode = "2d"
	pane._apply_graph_mode()
	assert_true(pane._graph_view is VaultGraphView, "the planar canvas takes over")
	assert_true(pane._graph_view.visible, "and stays on screen")
	assert_lt((pane._graph_view.positions["a.md"] - dropped).length(), 0.2,
		"the arrangement crosses the presentation switch")

	pane.graph_mode = "3d"
	pane._apply_graph_mode()
	assert_true(pane._graph_view is VaultGraph3D, "and back")
	assert_lt((pane._graph_view.positions["a.md"] - dropped).length(), 0.2)
	await get_tree().process_frame

# ── The link panel: mentions and backlinks of the open note ────────────
#
# The data half (the index pass, the resolver, `vault_links`) is pinned by
# `gpty_core::vault` / `gpty_core::links`; these tests drive the pane's view of
# it against the real store — the panel's rows, following in place, and the
# guard an unsaved buffer gets.

func _row_texts(container: VBoxContainer) -> Array:
	var out := []
	for row in container.get_children():
		out.append((row as Button).text)
	return out


func test_a_note_without_links_shows_no_panel():
	_write(_tmp.path_join("note.md"), "# N\n\nno mentions here\n")
	var pane := _make_pane(_tmp)
	pane._open_note("note.md")
	assert_false(pane._links_box.visible, "an empty panel would only take space")


func test_the_panel_lists_outgoing_mentions_with_their_lines():
	_write(_tmp.path_join("a.md"), "# A\n\nSee [[b]] and [[ghost]].\n")
	_write(_tmp.path_join("b.md"), "# B\n")
	var pane := _make_pane(_tmp)
	pane._open_note("a.md")

	assert_true(pane._links_box.visible)
	var rows := _row_texts(pane._outgoing_rows)
	assert_eq(rows.size(), 2, "one row per occurrence")
	assert_string_contains(rows[0], "b")
	assert_string_contains(rows[0], "line 3", "the row names the line it was written on")
	assert_string_contains(rows[1], "ghost")
	assert_string_contains(rows[1], "not found")
	assert_false((pane._outgoing_rows.get_child(1) as Button).disabled,
		"a missing target offers the create-from-link action")
	assert_true(pane._links_backlinks_heading.visible == false,
		"no note links here, so the backlink section stays out of the way")


func test_backlinks_name_the_note_and_the_line():
	_write(_tmp.path_join("a.md"), "# A\n\nSee [[b]].\n")
	_write(_tmp.path_join("b.md"), "# B\n\ntarget\n")
	var pane := _make_pane(_tmp)
	pane._open_note("b.md")

	var rows := _row_texts(pane._backlinks_rows)
	assert_eq(rows.size(), 1, "one row per mention, in the linking note")
	assert_string_contains(rows[0], "a.md")
	assert_string_contains(rows[0], "line 3")


func test_an_ambiguous_target_is_shown_with_its_candidates():
	DirAccess.make_dir_recursive_absolute(_tmp.path_join("one"))
	DirAccess.make_dir_recursive_absolute(_tmp.path_join("two"))
	_write(_tmp.path_join("one").path_join("dup.md"), "# One\n")
	_write(_tmp.path_join("two").path_join("dup.md"), "# Two\n")
	_write(_tmp.path_join("x.md"), "# X\n\nsee [[dup]]\n")
	var pane := _make_pane(_tmp)
	pane._open_note("x.md")

	var rows := _row_texts(pane._outgoing_rows)
	assert_eq(rows.size(), 1)
	assert_string_contains(rows[0], "ambiguous")
	assert_string_contains(rows[0], "one/dup.md", "the hint names every candidate")
	assert_string_contains(rows[0], "two/dup.md")
	assert_true((pane._outgoing_rows.get_child(0) as Button).disabled,
		"an ambiguous stem is never silently picked")


func test_clicking_a_link_follows_it_in_place():
	_write(_tmp.path_join("a.md"), "# A\n\nSee [[b]].\n")
	_write(_tmp.path_join("b.md"), "# B\n\nbody\n")
	var pane := _make_pane(_tmp)
	pane._open_note("a.md")

	(pane._outgoing_rows.get_child(0) as Button).pressed.emit()
	assert_eq(pane._current_rel, "b.md", "the target replaces the open note")
	assert_eq(pane._editor.text, "# B\n\nbody\n")
	var backlinks := _row_texts(pane._backlinks_rows)
	assert_eq(backlinks.size(), 1, "one backlink row")
	if backlinks.is_empty():
		return
	assert_string_contains(backlinks[0], "a.md",
		"the newly opened note's panel follows the move")


func test_clicking_a_backlink_opens_the_linking_note():
	_write(_tmp.path_join("a.md"), "# A\n\nSee [[b]].\n")
	_write(_tmp.path_join("b.md"), "# B\n")
	var pane := _make_pane(_tmp)
	pane._open_note("b.md")

	(pane._backlinks_rows.get_child(0) as Button).pressed.emit()
	assert_eq(pane._current_rel, "a.md")


func test_a_rendered_mention_click_resolves_through_the_vault():
	_write(_tmp.path_join("a.md"), "# A\n\nSee [[B]].\n")
	_write(_tmp.path_join("b.md"), "# B\n")
	var pane := _make_pane(_tmp)
	pane._open_note("a.md")
	assert_true(pane._reader.wikilinks_enabled, "the wiki preview opts into mentions")

	# The renderer emits `note_link_clicked` with the target and fragment decoded;
	# the pane asks the same resolver the index used.
	pane._reader.note_link_clicked.emit("B", "")
	assert_eq(pane._current_rel, "b.md", "a case-insensitive unique match follows")


## A note whose only content is filler, with `heading` on a known line.
func _write_long_note(rel: String, heading: String, heading_line: int) -> void:
	var lines: Array = []
	while lines.size() < heading_line - 1:
		lines.append("filler line %d" % lines.size())
	lines.append(heading)
	lines.append("")
	lines.append("after the heading")
	_write(_tmp.path_join(rel), "\n".join(lines) + "\n")


func test_a_fragment_mention_lands_on_the_heading_in_the_editor():
	_write(_tmp.path_join("a.md"), "# A\n\nSee [[b#Part]].\n")
	_write_long_note("b.md", "## Part", 34)
	var pane := _make_pane(_tmp)
	pane.view_mode = "edit"
	pane._open_note("a.md")

	pane._reader.note_link_clicked.emit("b", "Part")
	assert_eq(pane._current_rel, "b.md")
	assert_eq(int(pane._editor.scroll_vertical), 33,
		"the source editor scrolls to the heading's line")


func test_a_fragment_mention_scrolls_the_preview_to_the_heading():
	# The preview's lines are rendered lines (wrapping included), so the
	# scroll is queued for the label's layout pass and lands a frame later.
	_write(_tmp.path_join("a.md"), "# A\n\nSee [[b#Part]].\n")
	_write_long_note("b.md", "## Part", 80)
	var pane := _make_pane(_tmp)
	pane._open_note("a.md")

	pane._reader.note_link_clicked.emit("b", "Part")
	assert_eq(pane._current_rel, "b.md")
	await wait_process_frames(3)
	assert_true(pane._reader.get_v_scroll_bar().value > 0,
		"the preview followed the heading instead of staying at the top")


func test_the_panel_row_names_the_fragment_and_follows_it():
	_write(_tmp.path_join("a.md"), "# A\n\nSee [[b#Part]].\n")
	_write_long_note("b.md", "## Part", 34)
	var pane := _make_pane(_tmp)
	pane.view_mode = "edit"
	pane._open_note("a.md")

	var rows := _row_texts(pane._outgoing_rows)
	assert_string_contains(rows[0], "b#Part", "the row says where the link lands")
	(pane._outgoing_rows.get_child(0) as Button).pressed.emit()
	assert_eq(pane._current_rel, "b.md")
	assert_eq(int(pane._editor.scroll_vertical), 33)


func test_a_backlink_row_jumps_to_the_mention_line():
	# The backlink names a line in the note it opens; the click lands there
	# instead of stopping at the top.
	_write_long_note("a.md", "## Mentions", 34)
	var source := _read(_tmp.path_join("a.md")) + "See [[b]].\n"
	_write(_tmp.path_join("a.md"), source)
	_write(_tmp.path_join("b.md"), "# B\n")
	var pane := _make_pane(_tmp)
	pane.view_mode = "edit"
	pane._open_note("b.md")

	var rows := _row_texts(pane._backlinks_rows)
	assert_string_contains(rows[0], "line 37", "the mention follows the heading block")
	(pane._backlinks_rows.get_child(0) as Button).pressed.emit()
	assert_eq(pane._current_rel, "a.md")
	assert_eq(int(pane._editor.scroll_vertical), 36,
		"the linking note opens at the mention, not at its top")


func test_a_missing_fragment_still_opens_the_note_and_says_so():
	_write(_tmp.path_join("a.md"), "# A\n\nSee [[b#Nope]].\n")
	_write(_tmp.path_join("b.md"), "# B\n\nbody\n")
	var pane := _make_pane(_tmp)
	pane._open_note("a.md")
	watch_signals(ToastManager)

	pane._reader.note_link_clicked.emit("b", "Nope")
	assert_eq(pane._current_rel, "b.md", "the destination is the note, not the heading")
	assert_signal_emitted(ToastManager, "toast_requested",
		"a fragment the note does not contain is reported")
	assert_eq(_dialogs_of(pane).size(), 0, "a wrong scroll is not a question")


func test_a_mention_inside_a_markdown_link_yields_to_it():
	# Nested `[url]` tags in one label leave the click target undefined, so the
	# preview renders the outer link the author wrote and the mention as text.
	_write(_tmp.path_join("a.md"), "# A\n\n[see [[b]]](https://example.com/x)\n")
	_write(_tmp.path_join("b.md"), "# B\n")
	var pane := _make_pane(_tmp)
	pane._open_note("a.md")

	var bbcode: String = pane._reader.text
	assert_string_contains(bbcode, "[url=https://example.com/x]see b[/url]")
	assert_false(bbcode.contains("gpty-note:"), "no nested internal link: %s" % bbcode)


func test_following_a_link_asks_before_discarding_an_unsaved_buffer():
	_write(_tmp.path_join("a.md"), "# A\n\nSee [[b]].\n")
	_write(_tmp.path_join("b.md"), "# B\n")
	var pane := _make_pane(_tmp)
	pane._open_note("a.md")
	await _type_into(pane, "# A edited\n")

	(pane._outgoing_rows.get_child(0) as Button).pressed.emit()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "following can lose a buffer, so it asks first")
	if dialogs.is_empty():
		return
	assert_eq(pane._current_rel, "a.md", "the note stays until the answer")
	dialogs[0].custom_action.emit("discard")
	assert_eq(pane._current_rel, "b.md", "discarding lets the follow proceed")
	assert_eq(_read(_tmp.path_join("a.md")), "# A\n\nSee [[b]].\n",
		"and the discarded edit was not written")


func test_a_missing_mention_offers_to_create_it():
	_write(_tmp.path_join("a.md"), "# A\n\nSee [[ghost]].\n")
	var pane := _make_pane(_tmp)
	pane._open_note("a.md")

	pane._reader.note_link_clicked.emit("ghost", "")
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "a missing target offers the create action")
	if dialogs.is_empty():
		return
	var field: LineEdit = dialogs[0].find_child("NoteName", true, false)
	assert_not_null(field, "the question carries a name field")
	assert_eq(field.text, "ghost.md", "the mention's own spelling is the default")

	dialogs[0].canceled.emit()
	await get_tree().process_frame
	assert_eq(pane._current_rel, "a.md", "canceling creates nothing and follows nothing")
	assert_false(FileAccess.file_exists(_tmp.path_join("ghost.md")))


func test_creating_from_a_missing_mention_opens_the_new_note():
	_write(_tmp.path_join("a.md"), "# A\n\nSee [[ghost]].\n")
	var pane := _make_pane(_tmp)
	pane._open_note("a.md")

	pane._reader.note_link_clicked.emit("ghost", "")
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	dialogs[0].confirmed.emit()
	await wait_process_frames(2)
	assert_true(FileAccess.file_exists(_tmp.path_join("ghost.md")),
		"confirming creates the note the mention named")
	assert_eq(pane._current_rel, "ghost.md", "and opens it in place")
	assert_eq(pane._editor.text, "")


func test_an_ambiguous_mention_is_reported_and_never_created():
	DirAccess.make_dir_recursive_absolute(_tmp.path_join("one"))
	DirAccess.make_dir_recursive_absolute(_tmp.path_join("two"))
	_write(_tmp.path_join("one").path_join("dup.md"), "# One\n")
	_write(_tmp.path_join("two").path_join("dup.md"), "# Two\n")
	_write(_tmp.path_join("x.md"), "# X\n\nsee [[dup]]\n")
	var pane := _make_pane(_tmp)
	pane._open_note("x.md")
	watch_signals(ToastManager)

	pane._reader.note_link_clicked.emit("dup", "")
	assert_eq(pane._current_rel, "x.md", "an ambiguous stem is never picked")
	assert_eq(_dialogs_of(pane).size(), 0, "and never guessed by creating one")
	assert_signal_emitted(ToastManager, "toast_requested")


func test_following_a_link_saves_when_the_user_chooses_save():
	_write(_tmp.path_join("a.md"), "# A\n\nSee [[b]].\n")
	_write(_tmp.path_join("b.md"), "# B\n")
	var pane := _make_pane(_tmp)
	pane._open_note("a.md")
	await _type_into(pane, "# A edited\n\nSee [[b]].\n")

	(pane._outgoing_rows.get_child(0) as Button).pressed.emit()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	dialogs[0].confirmed.emit()
	await wait_process_frames(2)  # the save runs after the dialog is freed
	assert_eq(pane._current_rel, "b.md", "the save lets the follow proceed")
	assert_eq(_read(_tmp.path_join("a.md")), "# A edited\n\nSee [[b]].\n")


# ── Creating, renaming, and deleting notes ─────────────────────────────
#
# The verbs themselves are the core's (`gpty_core::vault`), pinned there; these
# drive the pane's entry points and its dialogs against a real vault: the name
# question, the collision retry, the delete confirmation, and the recovery
# copy's key moving with a rename.

func _name_field(dialog: ConfirmationDialog) -> LineEdit:
	return dialog.find_child("NoteName", true, false) as LineEdit


func test_new_note_creates_and_opens_it():
	var pane := _make_pane(_tmp)
	assert_true(pane._new_button.visible, "the list offers a new note")

	pane._new_button.pressed.emit()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the name is asked before anything is written")
	if dialogs.is_empty():
		return
	var field := _name_field(dialogs[0])
	assert_eq(field.text, WikiPane.NEW_NOTE_NAME)
	field.text = "fresh"
	dialogs[0].confirmed.emit()
	await wait_process_frames(1)

	assert_true(FileAccess.file_exists(_tmp.path_join("fresh.md")),
		"a bare name gains the walk's .md extension")
	assert_eq(pane._current_rel, "fresh.md", "the new note opens")
	assert_eq(pane._editor.text, "")
	assert_false(pane._new_button.visible, "the note view owns the pane now")


func test_a_new_note_never_replaces_one_and_the_question_reopens():
	_write(_tmp.path_join("taken.md"), "# Taken\n")
	var pane := _make_pane(_tmp)
	pane._new_button.pressed.emit()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	var dialog: ConfirmationDialog = dialogs[0]
	_name_field(dialog).text = "taken.md"
	watch_signals(ToastManager)

	dialog.confirmed.emit()
	await wait_process_frames(2)
	assert_eq(_read(_tmp.path_join("taken.md")), "# Taken\n",
		"an existing note is never overwritten")
	assert_signal_emitted(ToastManager, "toast_requested", "the refusal is reported")
	dialogs = _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the name question is asked again")
	if dialogs.is_empty():
		return
	assert_eq(_name_field(dialogs[0]).text, "taken.md",
		"with the typed name, so the correction is one edit")
	assert_eq(pane._current_rel, "", "nothing opened")


func test_rename_moves_the_open_note():
	_write(_tmp.path_join("note.md"), "# Note\n")
	var pane := _make_pane(_tmp)
	pane._open_note("note.md")

	pane._rename_button.pressed.emit()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	var dialog: ConfirmationDialog = dialogs[0]
	assert_eq(_name_field(dialog).text, "note.md", "the current path is the default")
	_name_field(dialog).text = "moved.md"
	dialog.confirmed.emit()
	await wait_process_frames(2)

	assert_eq(pane._current_rel, "moved.md")
	assert_eq(pane._note_title.text, "moved.md")
	assert_false(FileAccess.file_exists(_tmp.path_join("note.md")))
	assert_eq(_read(_tmp.path_join("moved.md")), "# Note\n")
	assert_eq(pane._editor.text, "# Note\n", "the open buffer is untouched by the move")
	assert_eq(_dialogs_of(pane).size(), 0,
		"nothing mentions the old name, so there is no question to ask")


## Declared weights are authored data keyed on note paths: a rename re-keys
## both endpoints immediately, before any complete graph could prune the old
## name as a note that vanished.
func test_rename_rekeys_declared_link_weights():
	_write(_tmp.path_join("note.md"), "# Note\n")
	_write(_tmp.path_join("other.md"), "# Other\n")
	LinkWeightsStore.set_weight(_tmp, "note.md", "other.md", 25)
	LinkWeightsStore.set_weight(_tmp, "other.md", "note.md", 40)
	var pane := _make_pane(_tmp)
	pane._open_note("note.md")

	pane._rename_button.pressed.emit()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	_name_field(dialogs[0]).text = "moved.md"
	dialogs[0].confirmed.emit()
	await wait_process_frames(2)

	assert_eq(LinkWeightsStore.weight_of(_tmp, "moved.md", "other.md"), 25,
		"an outgoing declaration follows the note")
	assert_eq(LinkWeightsStore.weight_of(_tmp, "other.md", "moved.md"), 40,
		"an incoming declaration follows the note")
	assert_eq(LinkWeightsStore.weight_of(_tmp, "note.md", "other.md"), 0)
	assert_eq(LinkWeightsStore.weight_of(_tmp, "other.md", "note.md"), 0)


func test_a_cancelled_rename_leaves_declared_weights_alone():
	_write(_tmp.path_join("note.md"), "# Note\n")
	LinkWeightsStore.set_weight(_tmp, "note.md", "other.md", 25)
	var pane := _make_pane(_tmp)
	pane._open_note("note.md")

	pane._rename_button.pressed.emit()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	dialogs[0].canceled.emit()
	await wait_process_frames(1)

	assert_eq(pane._current_rel, "note.md")
	assert_eq(LinkWeightsStore.weight_of(_tmp, "note.md", "other.md"), 25)
	assert_eq(LinkWeightsStore.weight_of(_tmp, "moved.md", "other.md"), 0)


func test_a_refused_rename_leaves_declared_weights_alone():
	_write(_tmp.path_join("note.md"), "# Note\n")
	_write(_tmp.path_join("taken.md"), "# Taken\n")
	LinkWeightsStore.set_weight(_tmp, "note.md", "other.md", 25)
	var pane := _make_pane(_tmp)
	pane._open_note("note.md")

	pane._rename_button.pressed.emit()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	_name_field(dialogs[0]).text = "taken.md"
	dialogs[0].confirmed.emit()
	await wait_process_frames(2)

	assert_eq(pane._current_rel, "note.md", "the open note did not move")
	assert_eq(LinkWeightsStore.weight_of(_tmp, "note.md", "other.md"), 25,
		"a refused rename changes nothing")
	assert_eq(LinkWeightsStore.weight_of(_tmp, "taken.md", "other.md"), 0)


func test_renaming_a_linked_note_offers_to_update_the_mentions():
	DirAccess.make_dir_recursive_absolute(_tmp.path_join("sub"))
	DirAccess.make_dir_recursive_absolute(_tmp.path_join("moved"))
	_write(_tmp.path_join("sub").path_join("old.md"), "# Old\n")
	var src := "# Src\n\nSee [[old]], [[OLD]], [[sub/old]], [[sub/old.md|label]], [[sub/old#Part]].\n"
	_write(_tmp.path_join("src.md"), src)
	var code := "`[[old]]`\n\n```\n[[old]]\n```\n"
	_write(_tmp.path_join("code.md"), code)
	var pane := _make_pane(_tmp)
	pane._open_note("sub/old.md")

	pane._rename_button.pressed.emit()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	_name_field(dialogs[0]).text = "moved/new.md"
	dialogs[0].confirmed.emit()
	await wait_process_frames(2)

	dialogs = _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the update is offered, not done silently")
	var dialog: ConfirmationDialog = dialogs[0]
	assert_string_contains(dialog.dialog_text, "5 mention(s) in 1 note(s)")
	assert_string_contains(dialog.dialog_text, "moved/new.md")
	assert_eq(_read(_tmp.path_join("src.md")), src,
		"nothing is written before the answer")

	dialog.confirmed.emit()
	await wait_process_frames(2)
	assert_eq(_read(_tmp.path_join("src.md")),
		"# Src\n\nSee [[new]], [[new]], [[moved/new]], [[moved/new.md|label]], [[moved/new#Part]].\n")
	assert_eq(_read(_tmp.path_join("code.md")), code, "code stays literal")
	assert_eq(pane._current_rel, "moved/new.md", "the open note is where the rename put it")


## A note may mention itself (a hub or an index). When its buffer is clean the
## reference pass can rewrite that mention too, and the pane adopts the text
## and stamp the pass answers — the file changed under a buffer that did not.
func test_renaming_a_clean_self_linked_note_updates_its_own_text():
	_write(_tmp.path_join("note.md"), "# Note\n\nSee [[note]] and [[note|me]].\n")
	var pane := _make_pane(_tmp)
	pane._open_note("note.md")

	pane._rename_button.pressed.emit()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	_name_field(dialogs[0]).text = "moved.md"
	dialogs[0].confirmed.emit()
	await wait_process_frames(2)

	dialogs = _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	var dialog: ConfirmationDialog = dialogs[0]
	assert_string_contains(dialog.dialog_text, "2 mention(s) in 1 note(s)",
		"the open note's own mentions are offered too")
	dialog.confirmed.emit()
	await wait_process_frames(2)

	var expected := "# Note\n\nSee [[moved]] and [[moved|me]].\n"
	assert_eq(_read(_tmp.path_join("moved.md")), expected)
	assert_eq(pane._editor.text, expected, "the open buffer adopts the pass's text")
	assert_eq(pane._saved_text, expected, "adoption is not an edit")
	assert_false(pane._is_dirty())
	# The adopted stamp is the file's, so a save right after is not a conflict.
	var reply = JSON.parse_string(str(GptyTerminal.vault_note_write(
		_tmp, "moved.md", pane._editor.text,
		pane._loaded_mtime, pane._loaded_size, false)))
	if reply is Dictionary:
		assert_false(reply.has("error"), "the stamp came from the write that landed")


## A dirty buffer is the editor's: the pass may update other notes, but never
## the file under an unsaved edit — the self-mention stays as typed.
func test_a_dirty_self_linked_note_is_never_rewritten_under_the_buffer():
	_write(_scratch_tmp.path_join("note.md"), "# Note\n\nSelf [[note]].\n")
	_write(_scratch_tmp.path_join("src.md"), "See [[note]].\n")
	var pane := _make_pane(_scratch_tmp)
	pane._scratch_timer.wait_time = 0.05
	pane._open_note("note.md")
	await _type_into(pane, "# Edited\n\nSelf [[note]].\n")
	assert_true(pane._is_dirty())

	pane._rename_button.pressed.emit()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	_name_field(dialogs[0]).text = "moved.md"
	dialogs[0].confirmed.emit()
	await wait_process_frames(2)

	dialogs = _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	var dialog: ConfirmationDialog = dialogs[0]
	assert_string_contains(dialog.dialog_text, "1 mention(s) in 1 note(s)",
		"only the note whose buffer is not open is offered")
	dialog.confirmed.emit()
	await wait_process_frames(2)

	assert_eq(_read(_scratch_tmp.path_join("moved.md")),
		"# Note\n\nSelf [[note]].\n",
		"the file under the dirty buffer was not rewritten")
	assert_eq(_read(_scratch_tmp.path_join("src.md")), "See [[moved]].\n")
	assert_eq(pane._editor.text, "# Edited\n\nSelf [[note]].\n",
		"the unsaved buffer is untouched")
	assert_true(pane._is_dirty())


func test_declining_the_mention_update_leaves_the_other_notes_alone():
	_write(_tmp.path_join("note.md"), "# Note\n")
	_write(_tmp.path_join("src.md"), "[[note]]\n")
	var pane := _make_pane(_tmp)
	pane._open_note("note.md")

	pane._rename_button.pressed.emit()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	_name_field(dialogs[0]).text = "moved.md"
	dialogs[0].confirmed.emit()
	await wait_process_frames(2)

	dialogs = _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	var dialog: ConfirmationDialog = dialogs[0]
	assert_string_contains(dialog.dialog_text, "1 mention(s) in 1 note(s)")
	dialog.canceled.emit()
	await wait_process_frames(2)

	assert_eq(_read(_tmp.path_join("src.md")), "[[note]]\n",
		"the question is a choice, not a side effect")
	assert_eq(_dialogs_of(pane).size(), 0)


func test_rename_while_dirty_moves_the_recovery_copy():
	_write(_scratch_tmp.path_join("note.md"), "# One\n")
	var pane := _make_pane(_scratch_tmp)
	pane._scratch_timer.wait_time = 0.05
	pane._open_note("note.md")
	await _type_into(pane, "# Two\n")
	await wait_seconds(0.1)
	assert_true(_has_copy(_scratch_tmp, "note.md"))

	pane._rename_button.pressed.emit()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	_name_field(dialogs[0]).text = "moved.md"
	dialogs[0].confirmed.emit()
	await wait_process_frames(1)

	assert_true(_has_copy(_scratch_tmp, "moved.md"),
		"the copy is re-keyed, or a crash would orphan the buffer")
	assert_false(_has_copy(_scratch_tmp, "note.md"))
	assert_true(pane._is_dirty(), "the buffer is still unsaved work")


func test_delete_asks_and_removes_the_note():
	_write(_tmp.path_join("note.md"), "# Note\n")
	_write(_tmp.path_join("other.md"), "# Other\n")
	var pane := _make_pane(_tmp)
	pane._open_note("note.md")

	pane._delete_button.pressed.emit()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	var dialog: ConfirmationDialog = dialogs[0]
	assert_string_contains(dialog.dialog_text, "note.md")
	dialog.canceled.emit()
	await get_tree().process_frame
	assert_true(FileAccess.file_exists(_tmp.path_join("note.md")),
		"canceling keeps the note")
	assert_eq(pane._current_rel, "note.md")

	pane._delete_button.pressed.emit()
	dialogs = _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the confirmation is asked again")
	if dialogs.is_empty():
		return
	dialogs[0].confirmed.emit()
	await wait_process_frames(1)
	assert_false(FileAccess.file_exists(_tmp.path_join("note.md")))
	assert_eq(pane._current_rel, "", "the pane returns to the list")
	assert_true(pane._note_box.visible == false)
	assert_eq(_list_texts(pane), ["other.md"], "the index caught up")


func test_delete_warns_about_an_unsaved_buffer():
	_write(_tmp.path_join("note.md"), "# Note\n")
	var pane := _make_pane(_tmp)
	pane._open_note("note.md")
	await _type_into(pane, "# Edited\n")

	pane._delete_button.pressed.emit()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	assert_string_contains(dialogs[0].dialog_text, "Unsaved changes")


# ── The recovery copy: what a crash cannot take ────────────────────────
#
# The close guards cover every deliberate end; a crash (or an outside kill) has
# no guard to run, so a dirty buffer is also snapshotted outside the vault and
# offered back when the note is reopened. These tests drive the pane's own
# timer and its own dialogs against the real store: the copy is written under
# gpty's state directory, and the vault is where it is read from.

## The recovery copy a later session would find for one note, asked through the
## same call the pane uses to offer it.
func _stored_copy(vault: String, rel: String) -> Dictionary:
	var answer = JSON.parse_string(str(GptyTerminal.vault_scratch_read(vault, rel)))
	return answer if answer is Dictionary else {}


func _has_copy(vault: String, rel: String) -> bool:
	return bool(_stored_copy(vault, rel).get("found", false))


func test_a_dirty_buffer_gets_a_recovery_copy_and_a_clean_one_does_not():
	_write(_scratch_tmp.path_join("note.md"), "# One\n")
	var pane := _make_pane(_scratch_tmp)
	# The debounce is 1.5 s in the real pane; this is the pane's own timer, so
	# only the wait is shortened.
	pane._scratch_timer.wait_time = 0.05
	pane._list.item_activated.emit(0)
	await wait_seconds(0.1)
	assert_false(_has_copy(_scratch_tmp, "note.md"), "a clean note writes no copy")

	await _type_into(pane, "# Two\n\nedited\n")
	await wait_seconds(0.1)
	var copy := _stored_copy(_scratch_tmp, "note.md")
	assert_true(bool(copy.get("found", false)), "a typed buffer must reach the copy")
	assert_eq(str(copy.get("text", "")), "# Two\n\nedited\n")
	assert_eq(int(copy.get("mtime", 0)), pane._loaded_mtime,
		"the copy carries the stamp the buffer was typed against")
	assert_eq(int(copy.get("size", 0)), pane._loaded_size)


func test_the_recovery_copy_is_throttled_rather_than_restarted_per_keystroke():
	_write(_scratch_tmp.path_join("note.md"), "# One\n")
	var pane := _make_pane(_scratch_tmp)
	pane._scratch_timer.wait_time = 1.0
	pane._list.item_activated.emit(0)

	await _type_into(pane, "a\n")
	var armed := pane._scratch_timer.time_left
	await wait_seconds(0.1)
	await _type_into(pane, "b\n")
	assert_true(pane._scratch_timer.time_left < armed,
		"a later keystroke must not push the copy out again, or a long typing run would never be covered")


func test_a_save_drops_the_recovery_copy():
	_write(_scratch_tmp.path_join("note.md"), "# One\n")
	var pane := _make_pane(_scratch_tmp)
	pane._scratch_timer.wait_time = 0.05
	pane._list.item_activated.emit(0)
	await _type_into(pane, "# Two\n")
	await wait_seconds(0.1)
	assert_true(_has_copy(_scratch_tmp, "note.md"))

	pane._save()
	assert_false(_has_copy(_scratch_tmp, "note.md"),
		"a save ends the copy's reason to exist")


func test_a_discard_drops_the_recovery_copy():
	_write(_scratch_tmp.path_join("note.md"), "# One\n")
	var pane := _make_pane(_scratch_tmp)
	pane._scratch_timer.wait_time = 0.05
	pane._list.item_activated.emit(0)
	await _type_into(pane, "# Two\n")
	await wait_seconds(0.1)

	pane._notes_button.pressed.emit()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	dialogs[0].custom_action.emit("discard")
	assert_false(_has_copy(_scratch_tmp, "note.md"),
		"a deliberately discarded buffer must not come back as a question")


func test_a_vault_change_drops_the_recovery_copy():
	_write(_scratch_tmp.path_join("note.md"), "# One\n")
	var pane := _make_pane(_scratch_tmp)
	pane._scratch_timer.wait_time = 0.05
	pane._list.item_activated.emit(0)
	await _type_into(pane, "# Two\n")
	await wait_seconds(0.1)
	assert_true(_has_copy(_scratch_tmp, "note.md"))

	# The settings panel's debounce makes a dialog unusable here, so the change
	# itself is the discard (the pane says so) — and the copy must follow it.
	var other := TestPaths.user_path("wiki_probe_vault_other")
	DirAccess.make_dir_recursive_absolute(other)
	pane.apply_settings({"vault_path": other})
	assert_false(_has_copy(_scratch_tmp, "note.md"),
		"the copy is keyed to the vault the buffer belonged to, and the discard drops it")
	TestPaths.remove_tree(other)


func test_reopening_a_note_offers_the_buffer_a_crash_left_behind():
	_write(_scratch_tmp.path_join("note.md"), "# One\n")
	var crashed := _make_pane(_scratch_tmp)
	crashed._scratch_timer.wait_time = 0.05
	crashed._list.item_activated.emit(0)
	await _type_into(crashed, "# Two\n\nrecovered\n")
	await wait_seconds(0.1)
	# Nothing decided that buffer's fate — no save, no discard — and the pane
	# goes away the way a crash leaves it.
	crashed.queue_free()
	await wait_process_frames(1)

	var pane := _make_pane(_scratch_tmp)
	pane._list.item_activated.emit(0)
	assert_eq(pane._editor.text, "# One\n",
		"the file is what the note says until the user answers")
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the copy must be offered, never applied on its own")
	if dialogs.is_empty():
		return
	assert_eq(dialogs[0].name, "RestoreConfirm")
	assert_string_contains(dialogs[0].dialog_text, "note.md")

	dialogs[0].confirmed.emit()
	assert_eq(pane._editor.text, "# Two\n\nrecovered\n", "Restore brings the buffer back")
	assert_true(pane._is_dirty(), "and it is unsaved work")
	assert_false(pane._save_button.disabled)

	pane._save()
	assert_eq(_read(_scratch_tmp.path_join("note.md")), "# Two\n\nrecovered\n",
		"the save writes what was recovered")
	assert_false(_has_copy(_scratch_tmp, "note.md"))
	# A reopened note asks nothing more after the save. (`queue_free` frees at
	# the end of the frame, so the dialog above is still a child until one
	# passes.)
	await wait_process_frames(1)
	pane._notes_button.pressed.emit()
	pane._list.item_activated.emit(0)
	assert_eq(_dialogs_of(pane).size(), 0)


func test_a_recovered_buffer_can_be_discarded():
	_write(_scratch_tmp.path_join("note.md"), "# One\n")
	GptyTerminal.vault_scratch_write(_scratch_tmp, "note.md", "# Two\n", 1, 1)
	var pane := _make_pane(_scratch_tmp)
	pane._list.item_activated.emit(0)

	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	dialogs[0].custom_action.emit("discard")
	assert_eq(pane._editor.text, "# One\n", "the file stays what the note says")
	assert_false(pane._is_dirty())
	assert_false(_has_copy(_scratch_tmp, "note.md"), "and the copy is gone")

	# The dialog is a child until the frame that frees it ends.
	await wait_process_frames(1)
	pane._notes_button.pressed.emit()
	pane._list.item_activated.emit(0)
	assert_eq(_dialogs_of(pane).size(), 0, "a decided copy must not come back")


func test_a_restore_after_the_file_moved_on_still_asks_before_overwriting():
	_write(_scratch_tmp.path_join("note.md"), "# Mine\n")
	# A copy from a session that saw an older revision (another editor wrote
	# the file since): the stamp it carries is that revision's, not this one's.
	GptyTerminal.vault_scratch_write(_scratch_tmp, "note.md", "# Recovered\n", 1, 1)
	var pane := _make_pane(_scratch_tmp)
	pane._list.item_activated.emit(0)
	var restore_dialogs := _dialogs_of(pane)
	assert_eq(restore_dialogs.size(), 1, "the pane must offer the recovery copy")
	if restore_dialogs.is_empty():
		return
	restore_dialogs[0].confirmed.emit()
	assert_true(pane._is_dirty())
	# The restore question is a child until the frame that frees it ends, and
	# Godot refuses a second exclusive dialog while one is registered.
	await wait_process_frames(1)

	pane._save()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the save must ask before overwriting what it did not see")
	if dialogs.is_empty():
		return
	assert_eq(dialogs[0].name, "OverwriteConfirm")
	assert_string_contains(_read(_scratch_tmp.path_join("note.md")), "Mine",
		"nothing is written before the answer")

	dialogs[0].confirmed.emit()
	await wait_process_frames(2)
	assert_eq(_read(_scratch_tmp.path_join("note.md")), "# Recovered\n",
		"confirming writes the recovered buffer")


func test_a_read_only_note_is_never_offered_a_restore():
	var big = FileAccess.open(_scratch_tmp.path_join("big.md"), FileAccess.WRITE)
	big.store_string("x".repeat(TextRead.DEFAULT_MAX_BYTES + 1))
	big.close()
	GptyTerminal.vault_scratch_write(_scratch_tmp, "big.md", "typed", 1, 1)
	var pane := _make_pane(_scratch_tmp)

	pane._list.item_activated.emit(0)
	assert_false(pane._editable_note)
	assert_eq(_dialogs_of(pane).size(), 0,
		"a restored buffer could not be saved, so it must not be offered")
	assert_true(_has_copy(_scratch_tmp, "big.md"),
		"and the copy is kept rather than dropped")


func test_a_crlf_note_opens_clean():
	_write(_scratch_tmp.path_join("note.md"), "# One\r\nline\r\n")
	var pane := _make_pane(_scratch_tmp)
	pane._scratch_timer.wait_time = 0.05
	pane._list.item_activated.emit(0)
	assert_true(pane._crlf, "the file's endings must be remembered")
	assert_false(pane._is_dirty(), "CRLF endings are the file's shape, not an edit")
	assert_true(pane._save_button.disabled, "so there is nothing to save yet")

	await _type_into(pane, "# Two\nline\n")
	await wait_seconds(0.1)
	assert_eq(str(_stored_copy(_scratch_tmp, "note.md").get("text", "")), "# Two\nline\n",
		"the copy is written in the editor's LF space, which is what dirty is measured in")

# ── The link graph ─────────────────────────────────────────────────────

func _graph_ids(pane: WikiPane) -> Array:
	var out := []
	for node in pane._graph_view.nodes:
		out.append(str(node["id"]))
	return out

func _seed_linked_vault() -> void:
	_write(_tmp.path_join("a.md"), "# A\n\n[[b]] and [[b|again]] and [[Missing]]\n")
	_write(_tmp.path_join("b.md"), "# B\n\n[[a]]\n")


func test_graph_shows_notes_links_and_unresolved_targets():
	_seed_linked_vault()
	var pane := _make_pane(_tmp)

	await _open_graph(pane)
	assert_true(pane._graph_view.visible)
	assert_false(pane._list.visible)
	assert_false(pane._note_box.visible)
	var ids := _graph_ids(pane)
	assert_has(ids, "a.md")
	assert_has(ids, "b.md")
	assert_has(ids, "ghost:Missing")
	assert_eq(pane._graph_view.edges.size(), 2,
		"a↔b is one aggregated pair and a→Missing is the other")
	for edge in pane._graph_view.edges:
		if str(edge["a"]) == "a.md" and str(edge["b"]) == "b.md":
			assert_eq(int(edge["count"]), 3, "mentions aggregate per pair")
			assert_true(bool(edge["mutual"]), "both directions exist")
		elif str(edge["b"]) == "ghost:Missing":
			assert_eq(int(edge["count"]), 1)
			assert_true(bool(edge["ghost"]))


func test_graph_click_opens_the_note():
	_seed_linked_vault()
	var pane := _make_pane(_tmp)

	await _open_graph(pane)
	pane._graph_view.node_activated.emit("b.md")
	assert_eq(pane._current_rel, "b.md")
	assert_true(pane._note_box.visible)
	assert_false(pane._graph_view.visible)


func test_graph_click_asks_before_replacing_a_dirty_note():
	_seed_linked_vault()
	var pane := _make_pane(_tmp)
	pane._list.item_activated.emit(0)
	await _type_into(pane, "# Unsaved\n")

	await _open_graph(pane)
	pane._graph_view.node_activated.emit("b.md")
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "a click must not discard the buffer")
	if dialogs.is_empty():
		return
	assert_eq(pane._current_rel, "a.md", "the note stays open while asked")

	dialogs[0].canceled.emit()
	assert_eq(pane._current_rel, "a.md", "canceling keeps the note")
	assert_true(pane._is_dirty(), "and the buffer is still unsaved work")


func test_the_graph_is_requeried_after_a_save():
	_write(_tmp.path_join("a.md"), "# A\n")
	var pane := _make_pane(_tmp)
	pane._list.item_activated.emit(0)
	await _type_into(pane, "# A\n\n[[later]]\n")
	pane._save()

	await _open_graph(pane)
	assert_has(_graph_ids(pane), "ghost:later",
		"the save re-indexed, so the graph reads the new edge")


func test_graph_notes_returns_to_the_list():
	_seed_linked_vault()
	var pane := _make_pane(_tmp)

	await _open_graph(pane)
	assert_true(pane._notes_button.visible)
	assert_false(pane._graph_button.visible, "the graph shows only Notes")
	pane._notes_button.pressed.emit()
	assert_true(pane._list.visible)
	assert_false(pane._graph_view.visible)
	assert_false(pane._notes_button.visible)
	assert_true(pane._graph_button.visible)


func test_a_fresh_pane_opens_the_graph():
	var pane := _make_pane(_tmp, false)
	await _settle_graph(pane)
	assert_true(pane._graph_view.visible, "a pane with no saved view opens the graph")
	assert_false(pane._list.visible)
	assert_true(pane._notes_button.visible)
	assert_false(pane._graph_button.visible, "the graph surface shows only Notes")


## The default build lands over the list the pane shows while it runs. Hiding
## the list drops the focus owner, so without the carry the next keystroke goes
## nowhere.
func test_a_default_graph_build_carries_the_keyboard_off_the_list():
	_write(_tmp.path_join("note.md"), "# Note\n")
	var pane := _make_pane(_tmp, false)
	assert_true(pane._list.visible, "precondition: the list shows while the graph builds")
	pane._list.grab_focus()
	assert_eq(pane.get_viewport().gui_get_focus_owner(), pane._list,
		"precondition: the list holds the keyboard")
	await _settle_graph(pane)
	assert_true(pane._graph_view.visible, "a pane with no saved view opens the graph")
	assert_eq(pane.get_viewport().gui_get_focus_owner(), pane._graph_view,
		"the canvas takes the keyboard from the list it replaced")


## The same build must not pull the keyboard away from a surface it does not
## replace: another pane, or another control, keeps what the user gave it.
func test_a_default_graph_build_does_not_steal_another_surfaces_keyboard():
	_write(_tmp.path_join("note.md"), "# Note\n")
	var other := Button.new()
	add_child_autofree(other)
	var pane := _make_pane(_tmp, false)
	other.grab_focus()
	await _settle_graph(pane)
	assert_true(pane._graph_view.visible)
	assert_eq(pane.get_viewport().gui_get_focus_owner(), other,
		"a build landing in a pane the user is not on leaves the keyboard alone")


func test_a_saved_notes_view_is_not_overridden():
	_write(_tmp.path_join("note.md"), "# N\n")
	var pane := _make_pane(_tmp)
	await get_tree().process_frame
	assert_true(pane._list.visible, "a saved notes view stays on the list")
	assert_false(pane._graph_wanted, "no default graph build was requested")
	assert_false(pane._graph_view.visible)


func test_the_view_buttons_follow_the_surface():
	_write(_tmp.path_join("note.md"), "# N\n")
	var pane := _make_pane(_tmp)
	assert_false(pane._notes_button.visible)
	assert_true(pane._graph_button.visible)
	assert_eq(pane._graph_button.text, "Graph")
	assert_eq(pane._new_button.text, "New")

	pane._list.item_activated.emit(0)
	assert_true(pane._note_box.visible)
	assert_true(pane._notes_button.visible, "the note editor shows Notes")
	assert_true(pane._graph_button.visible, "the note editor shows Graph")
	assert_false(pane._new_button.visible)
	var top := pane.find_child("TopRow", true, false) as HBoxContainer
	assert_eq(top.get_child(0), pane._notes_button, "Notes is the first view button")
	assert_eq(top.get_child(1), pane._graph_button, "Graph is the second")

	pane._graph_button.pressed.emit()
	await _settle_graph(pane)
	assert_true(pane._graph_view.visible)
	assert_true(pane._notes_button.visible)
	assert_false(pane._graph_button.visible, "the graph surface hides Graph")

	pane._notes_button.pressed.emit()
	assert_true(pane._list.visible)
	assert_false(pane._notes_button.visible)
	assert_true(pane._graph_button.visible)


func test_the_mode_button_names_the_other_presentation():
	_seed_linked_vault()
	var pane := _make_pane(_tmp)
	pane.graph_mode = "3d"
	pane._apply_graph_mode()
	await _open_graph(pane)
	assert_true(pane._graph_view is VaultGraph3D)
	var view := pane._graph_view as VaultGraph3D
	if view == null:
		return
	assert_eq(view._mode_button.text, "Planar")

	view._mode_button.pressed.emit()
	assert_true(pane._graph_view is VaultGraphView)
	var planar := pane._graph_view as VaultGraphView
	if planar == null:
		return
	assert_eq(planar._mode_button.text, "Orbital")
	planar._mode_button.pressed.emit()
	assert_true(pane._graph_view is VaultGraph3D)
	var orbital := pane._graph_view as VaultGraph3D
	if orbital == null:
		return
	assert_eq(orbital._mode_button.text, "Planar")

	assert_eq(PaneTypes.WIKI_GRAPH_MODE_LABELS["3d"], "Orbital")
	assert_eq(PaneTypes.WIKI_GRAPH_MODE_LABELS["2d"], "Planar")
	for node in pane.find_children("*", "Button", true, false):
		assert_ne((node as Button).text, "Physical", "no button says Physical")


func test_relayout_is_the_only_layout_action():
	_seed_linked_vault()
	var pane := _make_pane(_tmp)
	pane.graph_mode = "3d"
	pane._apply_graph_mode()
	await _open_graph(pane)
	var view := pane._graph_view as VaultGraph3D
	if view == null:
		return
	assert_not_null(view._relayout_button)
	assert_eq(view._relayout_button.text, "Relayout")
	assert_null(view.get("_fit_button"), "the Fit button is gone")

	pane.graph_mode = "2d"
	pane._apply_graph_mode()
	assert_true(pane._graph_view is VaultGraphView)
	var planar := pane._graph_view as VaultGraphView
	if planar == null:
		return
	assert_not_null(planar._relayout_button)
	assert_null(planar.get("_fit_button"))


func test_the_new_button_says_new():
	var pane := _make_pane(_tmp)
	assert_eq(pane._new_button.text, "New")


func test_graph_ghost_click_offers_to_create_the_missing_note():
	_seed_linked_vault()
	var pane := _make_pane(_tmp)

	await _open_graph(pane)
	pane._graph_view.ghost_activated.emit("Missing")
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "a missing target offers the create-from-link verb")
	if dialogs.is_empty():
		return
	assert_eq(dialogs[0].name, "NoteNameConfirm")


func test_a_vault_that_cannot_be_opened_hides_the_graph_entry():
	var pane := _make_pane(_tmp.path_join("not-a-vault"))
	assert_false(pane._graph_button.visible)
	assert_false(pane._graph_view.visible)


# ── The build is off the frame ─────────────────────────────────────────
#
# The index query, the model and the layout scale with the vault (2,000 notes,
# 10,000 edges per class), so they run on a WorkerThreadPool task: the request
# returns at once and the canvas arrives on the frame the build lands. A
# synchronous build would fail every assertion below that the canvas is still
# down when the request returns.

func test_opening_the_graph_returns_before_the_canvas_is_built():
	_seed_linked_vault()
	var pane := _make_pane(_tmp)
	var outcomes := []
	pane.graph_built.connect(func(ok: bool, reason: String):
		outcomes.append([ok, reason])
	)

	assert_eq(pane.request_graph(), "", "this vault accepts the request")
	assert_false(pane._graph_view.visible,
		"the frame that asks for the graph must not build it")
	assert_true(pane._graph_wanted, "the build is on its way")
	assert_eq(outcomes.size(), 0, "nothing lands before the poll runs")

	await _settle_graph(pane)
	assert_true(pane._graph_view.visible, "the canvas comes up when the build lands")
	assert_has(_graph_ids(pane), "a.md")
	assert_has(_graph_ids(pane), "b.md")
	assert_eq(outcomes.size(), 1, "one build, one outcome")
	assert_true(bool(outcomes[0][0]), "the outcome is a landed canvas")
	assert_eq(str(outcomes[0][1]), "", "with no reason attached")


func test_leaving_the_graph_before_it_lands_keeps_the_canvas_down():
	_write(_tmp.path_join("note.md"), "# Note\n")
	var pane := _make_pane(_tmp)
	var outcomes := []
	pane.graph_built.connect(func(ok: bool, reason: String):
		outcomes.append([ok, reason])
	)

	assert_eq(pane.request_graph(), "")
	# A person pressing Back in the frame the build started: the result must
	# not resurrect the canvas over the list they asked for.
	pane._show_list()
	await _settle_graph(pane)

	assert_false(pane._graph_view.visible, "the build must not override the list")
	assert_true(pane._list.visible)
	assert_eq(outcomes.size(), 1, "the request is answered once")
	assert_false(bool(outcomes[0][0]))
	assert_string_contains(str(outcomes[0][1]), "left the link graph")


func test_a_build_that_lands_after_a_vault_change_is_rebuilt_for_the_new_vault():
	_write(_tmp.path_join("a.md"), "# A\n")
	var other := TestPaths.user_path("wiki_graph_other_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(other)
	_write(other.path_join("other.md"), "# Other\n")
	var pane := _make_pane(_tmp)

	assert_eq(pane.request_graph(), "")
	pane.apply_settings({"vault_path": other})
	assert_eq(pane.request_graph(), "")
	await _settle_graph(pane)

	assert_true(pane._graph_view.visible, "the second request still brings a canvas up")
	var ids := _graph_ids(pane)
	assert_has(ids, "other.md", "the canvas is the new vault's graph")
	assert_false(ids.has("a.md"), "the old vault's build must be dropped")
	TestPaths.remove_tree(other)


func test_a_dragged_node_keeps_its_place_across_a_build():
	_seed_linked_vault()
	var pane := _make_pane(_tmp)
	await _open_graph(pane)

	if pane._graph_view is VaultGraph3D:
		(pane._graph_view as VaultGraph3D)._place_body("a.md", Vector2(11, 22))
	else:
		pane._graph_view.positions["a.md"] = Vector2(11, 22)
	await _open_graph(pane)

	var got: Vector2 = pane._graph_view.positions.get("a.md", Vector2.ZERO)
	assert_lt((got - Vector2(11, 22)).length(), 1.0,
		"the pane hands the view's geometry to the build, so a drag survives")


# ── Declared edge weights (the authored layer) ─────────────────────────

func _edge_in_graph(pane: WikiPane, a: String, b: String) -> Dictionary:
	for edge in pane._graph_view.edges:
		if edge is Dictionary and str(edge["a"]) == a and str(edge["b"]) == b:
			return edge
	return {}


func test_a_declared_weight_reaches_the_graph_and_survives_a_requery():
	_seed_linked_vault()
	var pane := _make_pane(_tmp)
	LinkWeightsStore.set_pair(_tmp, "a.md", "b.md", 33)

	await _open_graph(pane)
	var edge := _edge_in_graph(pane, "a.md", "b.md")
	assert_eq(int(edge["declared"]), 33)
	assert_eq(int(edge["weight"]), 33)
	assert_eq(int(edge["count"]), 3, "the measured mentions are still there")

	await _open_graph(pane)
	assert_eq(int(_edge_in_graph(pane, "a.md", "b.md")["declared"]), 33,
		"a re-query re-applies the authored layer")


func test_the_graph_set_control_writes_both_directions_and_clears_them():
	_seed_linked_vault()
	var pane := _make_pane(_tmp)
	await _open_graph(pane)

	pane._set_declared_weight("a.md", "b.md", 21)
	assert_eq(LinkWeightsStore.weight_of(_tmp, "a.md", "b.md"), 21)
	assert_eq(LinkWeightsStore.weight_of(_tmp, "b.md", "a.md"), 21)
	assert_eq(int(_edge_in_graph(pane, "a.md", "b.md")["declared"]), 21)

	pane._clear_declared_weight("a.md", "b.md")
	assert_eq(LinkWeightsStore.weight_of(_tmp, "a.md", "b.md"), 0)
	assert_eq(LinkWeightsStore.weight_of(_tmp, "b.md", "a.md"), 0)
	assert_eq(int(_edge_in_graph(pane, "a.md", "b.md")["declared"]), 0)
	assert_eq(int(_edge_in_graph(pane, "a.md", "b.md")["weight"]), 3,
		"clearing falls back to the measured count")


func test_an_invalid_pair_is_refused_without_writing():
	_seed_linked_vault()
	var pane := _make_pane(_tmp)
	pane._set_declared_weight("a.md", "../escape.md", 10)
	assert_eq(LinkWeightsStore.vault_weights(_tmp), {},
		"the store's vocabulary is the last word")


func test_showing_a_complete_graph_prunes_vanished_endpoints():
	_seed_linked_vault()
	var pane := _make_pane(_tmp)
	LinkWeightsStore.set_weight(_tmp, "a.md", "b.md", 5)
	LinkWeightsStore.set_weight(_tmp, "a.md", "gone.md", 5)

	await _open_graph(pane)
	assert_eq(LinkWeightsStore.weight_of(_tmp, "a.md", "b.md"), 5,
		"a live endpoint keeps its declaration")
	assert_eq(LinkWeightsStore.weight_of(_tmp, "a.md", "gone.md"), 0,
		"a note the graph no longer lists is pruned lazily")


func test_the_link_panel_puts_a_declared_mention_first():
	_write(_tmp.path_join("a.md"), "# A\n\n[[b]]\n\n[[c]]\n")
	_write(_tmp.path_join("b.md"), "# B\n")
	_write(_tmp.path_join("c.md"), "# C\n")
	var pane := _make_pane(_tmp)
	pane._open_note("a.md")

	assert_eq(pane._outgoing_rows.get_child_count(), 2)
	var first := pane._outgoing_rows.get_child(0) as Button
	var second := pane._outgoing_rows.get_child(1) as Button
	assert_string_contains(first.text, "b", "the index's order with no declarations")

	LinkWeightsStore.set_weight(_tmp, "a.md", "c.md", 50)
	pane._refresh_links()
	first = pane._outgoing_rows.get_child(0) as Button
	second = pane._outgoing_rows.get_child(1) as Button
	assert_string_contains(first.text, "c",
		"a declared mention sorts above the uncurated one")
	assert_string_contains(second.text, "b")


func test_a_declared_backlink_sorts_first_too():
	_write(_tmp.path_join("target.md"), "# Target\n")
	_write(_tmp.path_join("a.md"), "# A\n\n[[target]]\n")
	_write(_tmp.path_join("b.md"), "# B\n\n[[target]]\n")
	var pane := _make_pane(_tmp)
	pane._open_note("target.md")

	assert_eq(pane._backlinks_rows.get_child_count(), 2)
	LinkWeightsStore.set_weight(_tmp, "b.md", "target.md", 50)
	pane._refresh_links()
	var first := pane._backlinks_rows.get_child(0) as Button
	var second := pane._backlinks_rows.get_child(1) as Button
	assert_string_contains(first.text, "b",
		"the declaration is read in the backlink's own direction")
	assert_string_contains(second.text, "a")


func test_the_weight_question_is_one_ask_at_a_time():
	_seed_linked_vault()
	var pane := _make_pane(_tmp)
	await _open_graph(pane)

	pane._ask_declared_weight("a.md", "b.md", 0)
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the pane must raise the dialog this test drives")
	if dialogs.is_empty():
		return
	assert_eq(dialogs[0].name, "WeightConfirm")
	pane._ask_declared_weight("a.md", "b.md", 0)
	assert_eq(_dialogs_of(pane).size(), 1, "the second question does not stack")


# ── The graph's keyboard entry ─────────────────────────────────────────
#
# The link map is the pane's only surface while it is up, so it is where the
# keyboard goes — the same rule the note view follows for its buffer
# (`WikiPane.keyboard_entry`).

func test_opening_the_graph_hands_the_keyboard_to_the_canvas():
	_write(_tmp.path_join("note.md"), "# Note\n\n[[b]]\n")
	_write(_tmp.path_join("b.md"), "# B\n")
	var pane := _make_pane(_tmp)

	# A real click focuses the button before it emits; `pressed.emit()` alone
	# would test a gesture the engine never produces.
	pane._graph_button.grab_focus()
	assert_eq(pane.get_viewport().gui_get_focus_owner(), pane._graph_button,
		"precondition: the press leaves the keyboard on the button")
	pane._graph_button.pressed.emit()
	await _settle_graph(pane)

	assert_true(pane._graph_view.visible, "the map is up")
	assert_eq(pane.get_viewport().gui_get_focus_owner(), pane._graph_view,
		"the map takes the keyboard; the button that opened it does not keep it")
	assert_eq(pane.keyboard_entry(), pane._graph_view,
		"entering the pane aims at the map while it is showing")


func test_escape_from_the_graph_canvas_returns_to_the_list():
	_write(_tmp.path_join("note.md"), "# Note\n")
	var pane := _make_pane(_tmp)
	await _open_graph(pane)
	pane._graph_view.grab_focus()

	await _escape()

	assert_false(pane._graph_view.visible, "Escape leaves the map")
	assert_true(pane._list.visible, "the list is back")
	assert_eq(pane.get_viewport().gui_get_focus_owner(), pane._list,
		"the list takes the keyboard back")
