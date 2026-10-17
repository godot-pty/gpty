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
	_tmp = ProjectSettings.globalize_path("user://wiki_probe_vault")
	DirAccess.make_dir_recursive_absolute(_tmp)
	_scratch_tmp = ProjectSettings.globalize_path(
		"user://wiki_probe_scratch_%d" % Time.get_ticks_usec()
	)
	DirAccess.make_dir_recursive_absolute(_scratch_tmp)


func after_each():
	# Recovery copies live in gpty's state directory, not under the probe vault,
	# so removing the tree does not remove them — clear them first, while the
	# vault they are keyed to still exists.
	for rel in ["note.md", "big.md", "moved.md"]:
		GptyTerminal.vault_scratch_clear(_scratch_tmp, rel)
	_remove_tree(_scratch_tmp)
	_remove_tree(_tmp)
	MockAutoloads.teardown()


func _remove_tree(path: String):
	var dir := DirAccess.open(path)
	if dir:
		for f in dir.get_files():
			DirAccess.remove_absolute(path.path_join(f))
		for d in dir.get_directories():
			_remove_tree(path.path_join(d))
	DirAccess.remove_absolute(path)


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


func _make_pane(vault: String) -> WikiPane:
	var pane := WikiPane.new()
	pane.vault_path = vault
	# vault_path is set before add_child so _ready performs the index pass.
	add_child_autofree(pane)
	return pane


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
	assert_eq(_list_meta(pane)[0], "note.md", "a row carries the vault-relative path")


func test_activating_a_note_renders_it_and_back_returns():
	_write(_tmp.path_join("note.md"), "# Heading\n\nbody")
	var pane := _make_pane(_tmp)

	pane._list.item_activated.emit(0)
	assert_true(pane._reader.visible)
	assert_true(pane._back.visible)
	assert_false(pane._list.visible)
	assert_eq(pane._editor.text, "# Heading\n\nbody", "the editor holds the note")
	assert_false(pane._search.visible, "the note view owns the pane's top row")
	assert_string_contains(pane._reader.get_parsed_text(), "Heading")

	pane._back.pressed.emit()
	assert_true(pane._list.visible)
	assert_false(pane._reader.visible)
	assert_false(pane._back.visible)
	assert_true(pane._search.visible, "the search box comes back with the list")


func test_search_filters_the_list_to_matching_notes():
	_write(_tmp.path_join("alpha.md"), "# Alpha\napples are red")
	_write(_tmp.path_join("beta.md"), "# Beta\nbananas are yellow")
	var pane := _make_pane(_tmp)
	assert_eq(pane._list.item_count, 2)

	pane._search.text = "bananas"
	pane._run_search()
	assert_eq(pane._list.item_count, 1, "only the matching note is listed")
	assert_eq(_list_meta(pane)[0], "beta.md")
	assert_string_contains(_list_texts(pane)[0], "Beta", "the hit shows its title")
	assert_string_contains(_list_texts(pane)[0], "banana", "the hit shows its snippet")

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

	pane._back.pressed.emit()
	assert_true(pane._note_box.visible, "the note stays open until the user answers")
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "leaving a dirty note must ask first")
	assert_string_contains(dialogs[0].dialog_text, "note.md")

	dialogs[0].canceled.emit()
	await get_tree().process_frame
	assert_true(pane._note_box.visible, "canceling keeps the note")
	assert_eq(_dialogs_of(pane).size(), 0, "the question closes with the answer")

	pane._back.pressed.emit()
	dialogs = _dialogs_of(pane)
	assert_eq(dialogs.size(), 1)
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

	pane._back.pressed.emit()
	var dialogs := _dialogs_of(pane)
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
	_dialogs_of(pane)[0].confirmed.emit()  # Save
	await wait_process_frames(2)  # the save runs after the dialog is freed
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the conflict must be asked about before closing")
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

	pane._back.pressed.emit()
	pane._search.text = "zebra"
	pane._run_search()
	assert_eq(pane._list.item_count, 1, "a saved note must be searchable without a restart")
	assert_eq(_list_meta(pane)[0], "note.md")


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

	var other := ProjectSettings.globalize_path("user://wiki_probe_vault_other")
	DirAccess.make_dir_recursive_absolute(other)
	pane.apply_settings({"vault_path": other})
	assert_eq(pane._current_rel, "", "a different vault must not keep the old note")
	assert_false(pane._editor.editable)
	assert_true(pane._placeholder.visible, "the new vault is empty")
	_remove_tree(other)


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
	assert_string_contains(_row_texts(pane._backlinks_rows)[0], "a.md",
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

	# The renderer emits `note_link_clicked` with the target decoded; the pane
	# asks the same resolver the index used.
	pane._reader.note_link_clicked.emit("B")
	assert_eq(pane._current_rel, "b.md", "a case-insensitive unique match follows")


func test_following_a_link_asks_before_discarding_an_unsaved_buffer():
	_write(_tmp.path_join("a.md"), "# A\n\nSee [[b]].\n")
	_write(_tmp.path_join("b.md"), "# B\n")
	var pane := _make_pane(_tmp)
	pane._open_note("a.md")
	await _type_into(pane, "# A edited\n")

	(pane._outgoing_rows.get_child(0) as Button).pressed.emit()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "following can lose a buffer, so it asks first")
	assert_eq(pane._current_rel, "a.md", "the note stays until the answer")
	dialogs[0].custom_action.emit("discard")
	assert_eq(pane._current_rel, "b.md", "discarding lets the follow proceed")
	assert_eq(_read(_tmp.path_join("a.md")), "# A\n\nSee [[b]].\n",
		"and the discarded edit was not written")


func test_a_missing_mention_offers_to_create_it():
	_write(_tmp.path_join("a.md"), "# A\n\nSee [[ghost]].\n")
	var pane := _make_pane(_tmp)
	pane._open_note("a.md")

	pane._reader.note_link_clicked.emit("ghost")
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "a missing target offers the create action")
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

	pane._reader.note_link_clicked.emit("ghost")
	_dialogs_of(pane)[0].confirmed.emit()
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

	pane._reader.note_link_clicked.emit("dup")
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
	_dialogs_of(pane)[0].confirmed.emit()
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
	var dialog: ConfirmationDialog = _dialogs_of(pane)[0]
	_name_field(dialog).text = "taken.md"
	watch_signals(ToastManager)

	dialog.confirmed.emit()
	await wait_process_frames(2)
	assert_eq(_read(_tmp.path_join("taken.md")), "# Taken\n",
		"an existing note is never overwritten")
	assert_signal_emitted(ToastManager, "toast_requested", "the refusal is reported")
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the name question is asked again")
	assert_eq(_name_field(dialogs[0]).text, "taken.md",
		"with the typed name, so the correction is one edit")
	assert_eq(pane._current_rel, "", "nothing opened")


func test_rename_moves_the_open_note():
	_write(_tmp.path_join("note.md"), "# Note\n")
	var pane := _make_pane(_tmp)
	pane._open_note("note.md")

	pane._rename_button.pressed.emit()
	var dialog: ConfirmationDialog = _dialogs_of(pane)[0]
	assert_eq(_name_field(dialog).text, "note.md", "the current path is the default")
	_name_field(dialog).text = "moved.md"
	dialog.confirmed.emit()
	await wait_process_frames(1)

	assert_eq(pane._current_rel, "moved.md")
	assert_eq(pane._note_title.text, "moved.md")
	assert_false(FileAccess.file_exists(_tmp.path_join("note.md")))
	assert_eq(_read(_tmp.path_join("moved.md")), "# Note\n")
	assert_eq(pane._editor.text, "# Note\n", "the open buffer is untouched by the move")


func test_rename_while_dirty_moves_the_recovery_copy():
	_write(_scratch_tmp.path_join("note.md"), "# One\n")
	var pane := _make_pane(_scratch_tmp)
	pane._scratch_timer.wait_time = 0.05
	pane._open_note("note.md")
	await _type_into(pane, "# Two\n")
	await wait_seconds(0.1)
	assert_true(_has_copy(_scratch_tmp, "note.md"))

	pane._rename_button.pressed.emit()
	_name_field(_dialogs_of(pane)[0]).text = "moved.md"
	_dialogs_of(pane)[0].confirmed.emit()
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
	var dialog: ConfirmationDialog = _dialogs_of(pane)[0]
	assert_string_contains(dialog.dialog_text, "note.md")
	dialog.canceled.emit()
	await get_tree().process_frame
	assert_true(FileAccess.file_exists(_tmp.path_join("note.md")),
		"canceling keeps the note")
	assert_eq(pane._current_rel, "note.md")

	pane._delete_button.pressed.emit()
	_dialogs_of(pane)[0].confirmed.emit()
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
	assert_string_contains(_dialogs_of(pane)[0].dialog_text, "Unsaved changes")


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

	pane._back.pressed.emit()
	_dialogs_of(pane)[0].custom_action.emit("discard")
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
	var other := ProjectSettings.globalize_path("user://wiki_probe_vault_other")
	DirAccess.make_dir_recursive_absolute(other)
	pane.apply_settings({"vault_path": other})
	assert_false(_has_copy(_scratch_tmp, "note.md"),
		"the copy is keyed to the vault the buffer belonged to, and the discard drops it")
	_remove_tree(other)


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
	pane._back.pressed.emit()
	pane._list.item_activated.emit(0)
	assert_eq(_dialogs_of(pane).size(), 0)


func test_a_recovered_buffer_can_be_discarded():
	_write(_scratch_tmp.path_join("note.md"), "# One\n")
	GptyTerminal.vault_scratch_write(_scratch_tmp, "note.md", "# Two\n", 1, 1)
	var pane := _make_pane(_scratch_tmp)
	pane._list.item_activated.emit(0)

	_dialogs_of(pane)[0].custom_action.emit("discard")
	assert_eq(pane._editor.text, "# One\n", "the file stays what the note says")
	assert_false(pane._is_dirty())
	assert_false(_has_copy(_scratch_tmp, "note.md"), "and the copy is gone")

	# The dialog is a child until the frame that frees it ends.
	await wait_process_frames(1)
	pane._back.pressed.emit()
	pane._list.item_activated.emit(0)
	assert_eq(_dialogs_of(pane).size(), 0, "a decided copy must not come back")


func test_a_restore_after_the_file_moved_on_still_asks_before_overwriting():
	_write(_scratch_tmp.path_join("note.md"), "# Mine\n")
	# A copy from a session that saw an older revision (another editor wrote
	# the file since): the stamp it carries is that revision's, not this one's.
	GptyTerminal.vault_scratch_write(_scratch_tmp, "note.md", "# Recovered\n", 1, 1)
	var pane := _make_pane(_scratch_tmp)
	pane._list.item_activated.emit(0)
	_dialogs_of(pane)[0].confirmed.emit()
	assert_true(pane._is_dirty())
	# The restore question is a child until the frame that frees it ends, and
	# Godot refuses a second exclusive dialog while one is registered.
	await wait_process_frames(1)

	pane._save()
	var dialogs := _dialogs_of(pane)
	assert_eq(dialogs.size(), 1, "the save must ask before overwriting what it did not see")
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
