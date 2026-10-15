extends GutTest
# GDExtension FFI smoke tests — exercise real GptyTerminal #[func] methods
# headless without starting a shell (no PTY spawn; that stays a manual
# checklist item). Pattern proven by test_keyboard.gd's ClassDB usage.

var _t

func before_each():
	_t = ClassDB.instantiate("GptyTerminal")
	assert_not_null(_t, "GptyTerminal must be registered (gdext loaded)")

func after_each():
	if _t:
		_t.free()
		_t = null

func test_concepts_roundtrip_through_ffi():
	GptyTerminal.set_global_concepts(JSON.stringify([
		{"name": "c1", "trigger": "^testcmd", "enabled": true,
		 "capture_mode": "until_stop", "stop_timeout_ms": 450, "stop_on_input": false,
		 "actions": [{"target": "inspector"}]},
	]))
	var back = GptyTerminal.get_global_concepts()
	assert_eq(back.size(), 1, "one concept should roundtrip")
	assert_eq(back[0]["name"], "c1")
	assert_eq(back[0]["trigger"], "^testcmd")
	assert_eq(back[0]["stop_timeout_ms"], 450, "stop timeout must roundtrip")
	assert_eq(back[0]["stop_on_input"], false, "stop-on-input must roundtrip")
	var actions: Array = back[0]["actions"]
	assert_eq(actions.size(), 1, "the routing target must roundtrip")
	assert_eq(actions[0]["target"], "inspector")
	assert_false(actions[0].has("cmd"),
		"a concept action must never carry a command template")

func test_key_to_bytes_arrow():
	var b = _t.key_to_bytes(KEY_LEFT, false, false, false, false)
	assert_eq(b.get_string_from_ascii(), "\u001b[D", "Left arrow maps to ESC[D")

func test_get_app_version_returns_semver():
	# Static method — call on the class, not an instance.
	var ver: String = GptyTerminal.get_app_version()
	assert_true(ver.length() > 0, "version must not be empty")
	# Must be a valid semver triple (e.g. "0.4.0"), never the stale literal.
	var parts := ver.split(".")
	assert_eq(parts.size(), 3, "version must have exactly three dot-separated parts")
	assert_ne(ver, "0.3.0", "version must not be the stale 0.3.0 literal")

func test_unstarted_grid_functions_are_safe():
	assert_eq(_t.get_rows(), 0, "unstarted grid has 0 rows")
	assert_eq(_t.get_cols(), 0, "unstarted grid has 0 cols")
	_t.scroll_reset()
	_t.resize_grid(30, 100)
	pass # no crash is the assertion

func test_markdown_renderer_formats_and_sanitizes():
	var renderer = ClassDB.instantiate("GptyMarkdown")
	assert_not_null(renderer, "GptyMarkdown must be registered")
	var answer = JSON.parse_string(str(renderer.render("# Title\n\n**bold** [raw]\n\n[x](javascript:bad)")))
	assert_true(answer is Dictionary, "render must answer JSON")
	var rendered := str(answer.get("text", ""))
	assert_string_contains(rendered, "[font_size=26][b]Title")
	assert_string_contains(rendered, "[b]bold[/b]")
	assert_string_contains(rendered, "[lb]raw]")
	assert_false("[url=javascript:" in rendered)
	# The cut travels with the text (a view that cannot say what it did not
	# render is the bug this answers), and the cap is the read cap every pane
	# already applies — `TextRead.DEFAULT_MAX_BYTES`.
	assert_false(answer.get("truncated", true), "a short document is not cut")
	assert_eq(int(answer.get("shown", 0)), int(answer.get("size", -1)))
	var cap: int = TextRead.DEFAULT_MAX_BYTES
	var over = "a".repeat(cap + 1)
	var cut = JSON.parse_string(str(renderer.render(over)))
	assert_true(cut.get("truncated", false), "past the cap the render must say so")
	assert_eq(int(cut.get("shown", 0)), cap, "the answer names how much it rendered")
	assert_eq(int(cut.get("size", 0)), cap + 1, "and how much it was given")

func test_vault_index_and_search_answer_shaped_json():
	# The vault facet's wire contract (consumed by wiki_pane.gd): an index
	# answer carries the note list and the pass' counts, a search answer
	# carries hits with snippets, and a bad root is an `error` envelope rather
	# than an empty result — the distinction the pane's placeholder relies on.
	var vault := ProjectSettings.globalize_path("user://gdext_ffi_vault")
	DirAccess.make_dir_recursive_absolute(vault)
	var note := FileAccess.open(vault.path_join("note.md"), FileAccess.WRITE)
	note.store_string("# Heading\nzebra")
	note.close()

	var indexed = JSON.parse_string(str(GptyTerminal.vault_index(vault)))
	assert_true(indexed is Dictionary, "vault_index must answer JSON")
	assert_true(indexed.has("notes"), "the note list is part of the contract")
	assert_true("note.md" in indexed["notes"], "the indexed note must be listed")
	assert_true(indexed.has("added") and indexed.has("truncated"))

	var found = JSON.parse_string(str(GptyTerminal.vault_search(vault, "zebra", 10)))
	assert_true(found is Dictionary, "vault_search must answer JSON")
	assert_eq(found.get("total", -1), 1, "the indexed body must be searchable")
	var hit: Dictionary = found["results"][0]
	assert_eq(hit.get("path"), "note.md")
	assert_string_contains(str(hit.get("snippet")), "zebra")

	var bad = JSON.parse_string(str(GptyTerminal.vault_index("/nonexistent/vault/root")))
	assert_true(bad is Dictionary and bad.has("error"), "a bad root must answer an error")

	DirAccess.remove_absolute(vault.path_join("note.md"))
	DirAccess.remove_absolute(vault)


func test_vault_note_read_and_write_answer_shaped_json():
	# The editor's wire contract (consumed by wiki_pane.gd): a read answers the
	# text with the stamp and the file's shape, a write answers the fresh stamp
	# plus whether the index caught up, and a refusal answers an `error` with
	# the stable `code` the pane switches on.
	var vault := ProjectSettings.globalize_path("user://gdext_ffi_notes")
	DirAccess.make_dir_recursive_absolute(vault)
	var note := FileAccess.open(vault.path_join("note.md"), FileAccess.WRITE)
	note.store_string("# One\n")
	note.close()

	var read = JSON.parse_string(str(GptyTerminal.vault_note_read(vault, "note.md")))
	assert_true(read is Dictionary, "vault_note_read must answer JSON")
	assert_eq(read.get("text"), "# One\n")
	assert_false(read.get("truncated", true))
	assert_false(read.get("crlf", true), "a LF note is not a CRLF note")
	var mtime := int(read.get("mtime", 0))
	var size := int(read.get("size", 0))
	assert_gt(mtime, 0, "the stamp is how a save knows what it loaded")
	assert_eq(size, 6)

	var written = JSON.parse_string(str(GptyTerminal.vault_note_write(
		vault, "note.md", "# Two\nzebra\n", mtime, size, false)))
	assert_false(written.has("error"), "a fresh stamp must be accepted")
	assert_true(written.has("mtime") and written.has("size"), "the write answers the new stamp")
	assert_eq(written.get("indexed"), true, "the write must re-index the vault")

	var reread = JSON.parse_string(str(GptyTerminal.vault_note_read(vault, "note.md")))
	assert_eq(reread.get("text"), "# Two\nzebra\n")
	var found = JSON.parse_string(str(GptyTerminal.vault_search(vault, "zebra", 10)))
	assert_eq(found.get("total", -1), 1, "the saved body must be searchable at once")

	var stale = JSON.parse_string(str(GptyTerminal.vault_note_write(
		vault, "note.md", "# Three\n", mtime, size, false)))
	assert_eq(stale.get("code"), "changed_on_disk", "a stale stamp must be refused by code")
	var after = JSON.parse_string(str(GptyTerminal.vault_note_read(vault, "note.md")))
	assert_eq(after.get("text"), "# Two\nzebra\n", "a refused write must not touch the file")

	var escape = JSON.parse_string(str(GptyTerminal.vault_note_write(
		vault, "../escape.md", "x", -1, 0, false)))
	assert_eq(escape.get("code"), "bad_path", "a path outside the vault is refused by shape")

	DirAccess.remove_absolute(vault.path_join("note.md"))
	DirAccess.remove_absolute(vault)


func test_vault_scratch_functions_answer_shaped_json():
	# The recovery copy's wire contract (consumed by wiki_pane.gd): a read
	# distinguishes "no copy" from a failure, a write answers `ok`, and the
	# stamp the caller supplied comes back with the text. The copy lives in
	# gpty's state directory, not under the vault, so this test uses a vault
	# path of its own (an unreachable key for any later run) and drops the copy
	# before it finishes.
	var vault := ProjectSettings.globalize_path("user://gdext_ffi_scratch_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(vault)

	var absent = JSON.parse_string(str(GptyTerminal.vault_scratch_read(vault, "note.md")))
	assert_true(absent is Dictionary, "vault_scratch_read must answer JSON")
	assert_false(absent.get("found", true), "no copy is `found: false`, not an error")
	assert_false(absent.has("error"), "an absent copy is the normal state")

	var wrote = JSON.parse_string(str(GptyTerminal.vault_scratch_write(
		vault, "note.md", "typed\n", 1700000000000000, 6)))
	assert_true(wrote is Dictionary, "vault_scratch_write must answer JSON")
	assert_true(wrote.get("ok", false), "a writable state directory answers ok")

	var copy = JSON.parse_string(str(GptyTerminal.vault_scratch_read(vault, "note.md")))
	assert_true(copy.get("found", false))
	assert_eq(copy.get("text"), "typed\n")
	assert_eq(int(copy.get("mtime", 0)), 1700000000000000,
		"the copy carries the stamp the caller was holding, not the file's")
	assert_eq(int(copy.get("size", 0)), 6)

	var cleared = JSON.parse_string(str(GptyTerminal.vault_scratch_clear(vault, "note.md")))
	assert_true(cleared.get("ok", false))
	var gone = JSON.parse_string(str(GptyTerminal.vault_scratch_read(vault, "note.md")))
	assert_false(gone.get("found", true))
	var again = JSON.parse_string(str(GptyTerminal.vault_scratch_clear(vault, "note.md")))
	assert_true(again.get("ok", false), "clearing an absent copy is not an error")

	var bad_root = JSON.parse_string(str(GptyTerminal.vault_scratch_read("/nonexistent/vault", "note.md")))
	assert_true(bad_root is Dictionary and bad_root.has("error"), "a bad root answers an error")
	var bad_path = JSON.parse_string(str(GptyTerminal.vault_scratch_write(
		vault, "../escape.md", "x", 1, 1)))
	assert_eq(bad_path.get("code"), "bad_path", "a path outside the walk is refused by shape")

	GptyTerminal.vault_scratch_clear(vault, "note.md")
	DirAccess.remove_absolute(vault)
