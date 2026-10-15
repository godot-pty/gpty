extends GutTest
# Wiki pane: the read-only vault browser — vault validation, the indexed note
# list (`GptyTerminal.vault_index`), the index-backed search
# (`GptyTerminal.vault_search`), the note render, and the layout-state round
# trip. The walk's own rules (hidden skip, depth/entry caps, staleness) are
# pinned by `gpty_core::vault`'s unit tests; this file asserts the pane's view
# of that index.

var _tmp: String


func before_each():
	MockAutoloads.setup()
	_tmp = ProjectSettings.globalize_path("user://wiki_probe_vault")
	DirAccess.make_dir_recursive_absolute(_tmp)


func after_each():
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
	var f = FileAccess.open(_tmp.path_join("note.md"), FileAccess.READ)
	assert_eq(f.get_as_text(), "# Two\n\nedited\n", "the save must reach the file")


func test_the_preview_follows_the_buffer_live():
	_write(_tmp.path_join("note.md"), "# First\n")
	var pane := _make_pane(_tmp)
	pane._list.item_activated.emit(0)
	assert_eq(pane.view_mode, "split", "split is the default view")
	assert_true(pane._editor.visible and pane._reader.visible)

	await _type_into(pane, "# Renamed\n\nlive body\n")
	await wait_seconds(0.2)  # MarkdownView coalesces renders at 75 ms
	assert_string_contains(pane._reader.get_parsed_text(), "Renamed",
		"the preview must render the buffer, not the file")
	assert_string_contains(pane._reader.get_parsed_text(), "live body")


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
	dialogs[0].confirmed.emit()
	assert_false(pane._note_box.visible, "confirming discards and returns to the list")
	assert_true(pane._list.visible)


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
	var f = FileAccess.open(_tmp.path_join("note.md"), FileAccess.READ)
	assert_string_contains(f.get_as_text(), "Theirs", "nothing is written before the answer")

	dialogs[0].confirmed.emit()
	f = FileAccess.open(_tmp.path_join("note.md"), FileAccess.READ)
	assert_string_contains(f.get_as_text(), "Mine, overwritten",
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


func test_crlf_endings_survive_an_edit():
	_write(_tmp.path_join("note.md"), "# One\r\nline\r\n")
	var pane := _make_pane(_tmp)
	pane._list.item_activated.emit(0)
	assert_true(pane._crlf, "the file's endings must be remembered")
	assert_eq(pane._editor.text, "# One\nline\n", "the editor works in LF")

	await _type_into(pane, "# Two\nline\n")
	pane._save()
	var f = FileAccess.open(_tmp.path_join("note.md"), FileAccess.READ)
	assert_eq(f.get_as_text(), "# Two\r\nline\r\n", "the save must put the CRLFs back")


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
