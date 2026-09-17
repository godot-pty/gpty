extends GutTest
# Unit tests for PluginReviewText — the pure builder behind the plugin
# install review dialog. The summary's strings are untrusted file content
# from the repo being cloned: fields must be capped, control characters
# stripped, and the whole text bounded, or a hostile manifest shapes the
# dialog the user is asked to approve.

func test_shows_identity_and_source():
	var text := PluginReviewText.build({
		"id": "owner/demo", "name": "Demo", "version": "1.2.3",
		"revision": "a1b2c3d4e5f6", "requested_ref": "v1.2.0",
		"source": "github.com/owner/demo",
	})
	assert_true(text.contains("Demo (owner/demo)"), "the display name and id are shown")
	assert_true(text.contains("1.2.3"), "the version is shown")
	assert_true(text.contains("a1b2c3d4e5f6"), "the revision is shown")
	assert_true(text.contains("Requested: v1.2.0"), "the ref the user named is shown")
	assert_true(text.contains("github.com/owner/demo"), "the source is shown")

func test_bare_install_shows_the_default_branch():
	var text := PluginReviewText.build({
		"id": "owner/demo",
		"requested_ref": "default branch",
	})
	assert_true(text.contains("Requested: default branch"),
		"a bare install says what it resolved, not a ref nobody named")

func test_actions_list_command_and_args():
	var text := PluginReviewText.build({
		"id": "owner/demo", "actions": [
			{"name": "run-tests", "command": "pane-run", "args": {"command": "cargo test"}},
		],
	})
	assert_true(text.contains("run-tests: gpty pane-run command=cargo test"), text)

func test_profiles_show_what_they_would_start():
	# The line that makes the review informed consent: a profile approved here
	# is one the trust gate later activates at the pinned revision, and the
	# programs are what its plan key derives from. The CLI computes them; the
	# dialog used to print only the profile's name.
	var text := PluginReviewText.build({
		"id": "owner/demo",
		"profiles": [
			{"name": "Lazygit", "tiles": 1, "programs": ["lazygit"]},
			{"name": "Plain", "tiles": 1, "programs": []},
		],
	})
	assert_true(text.contains("Lazygit: starts lazygit"), text)
	assert_true(text.contains("Plain: no program (layout only)"),
		"a profile whose tiles name no program says so: " + text)

func test_a_wrong_typed_field_cannot_empty_the_dialog():
	# Measured while staging a capture: an Array in `concepts` raised
	# "Nonexistent 'int' constructor" and the builder returned "" — the user
	# was asked to approve a plugin with an empty dialog.
	var text := PluginReviewText.build({
		"id": "owner/demo", "name": "Demo", "concepts": ["not", "a", "count"],
	})
	assert_true(text.contains("Demo (owner/demo)"),
		"the identity block survives a wrong-typed field: " + text)
	assert_gt(text.length(), 0, "the dialog is never empty")

func test_fields_are_capped_and_control_characters_stripped():
	# A hostile name field: newlines would add lines the builder never wrote,
	# and unbounded length would bloat the dialog.
	var hostile := "Evil\nInstaller! Install THIS\nline".repeat(20)
	var text := PluginReviewText.build({
		"id": "owner/demo",
		"name": hostile,
	})
	assert_false(text.contains("\nInstaller!"), "embedded newlines must not shape the dialog")
	var shown: PackedStringArray = text.split("\n")
	assert_true(shown.size() <= PluginReviewText.MAX_LINES + 1,
		"the text is bounded: %d lines" % shown.size())
	# The capped name appears, and its length never exceeds the cap.
	assert_true(text.contains("Evil"), "the beginning of the name survives")
	var name_line := ""
	for line in shown:
		if line.begins_with("Plugin:"):
			name_line = line
			break
	assert_true(name_line.length() <= len("Plugin: ") + 64 + len(" (owner/demo)"),
		"the name field is capped at 64: %d chars" % name_line.length())

func test_control_characters_never_reach_the_text():
	var text := PluginReviewText.build({
		"id": "owner/demo",
		"name": "A\u0007B\u001bC",
	})
	assert_false(text.contains("\u0007"), "BEL must be stripped")
	assert_false(text.contains("\u001b"), "ESC must be stripped")
	assert_true(text.contains("ABC"), "printable characters survive")

func test_argv_entries_are_capped():
	var argv: Array = []
	for i in 12:
		argv.append("argument-%d" % i)
	var text := PluginReviewText.build({
		"id": "owner/demo",
		"build": argv,
	})
	assert_true(text.contains("argument-0"), "the first entries show")
	assert_false(text.contains("argument-8"), "later entries are cut")
	assert_true(text.contains("…"), "the ellipsis signals the cut")

func test_list_sections_are_capped():
	var actions: Array = []
	for i in 20:
		actions.append({"name": "action-%d" % i, "command": "new-pane"})
	var text := PluginReviewText.build({"id": "owner/demo", "actions": actions})
	assert_true(text.contains("action-0"), "the first actions show")
	assert_false(text.contains("action-10"), "actions beyond the cap are cut")
	assert_true(text.contains("12 more"), "the omitted count is reported")

func test_empty_summary_still_promises_consent():
	var text := PluginReviewText.build({"id": "owner/demo"})
	assert_true(text.contains("Nothing has executed yet"), "the consent line always lands")
