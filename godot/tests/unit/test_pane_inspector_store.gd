extends GutTest
# PaneInspectorStore — the user-owned Inspector aim (prompt and the two
# switches). A file must not supply them (`PaneTypes.INSPECTOR_SETTINGS` marks
# all three `file: false`), and this store is the only thing that can; its
# loader is the same hand-edited-file boundary as every other store.

func before_each():
	MockAutoloads.setup()

func after_each():
	MockAutoloads.teardown()

func test_set_and_remove_roundtrip():
	PaneInspectorStore.set_state("pane-abc", "Be terse.", true, false)
	assert_eq(PaneInspectorStore.state_for("pane-abc"), {
		"system_prompt": "Be terse.",
		"auto_run": true,
		"accept_concept_captures": false,
	})
	assert_true(MockAutoloads.get_store(PaneInspectorStore.STATE_FILE).has("pane-abc"))

	# Back to the defaults removes the entry: the store carries decisions only.
	PaneInspectorStore.set_state("pane-abc", "", false, false)
	assert_eq(PaneInspectorStore.state_for("pane-abc"), {})
	assert_false(MockAutoloads.get_store(PaneInspectorStore.STATE_FILE).has("pane-abc"))

func test_state_for_returns_a_copy():
	PaneInspectorStore.set_state("pane-copy", "Keep", false, false)
	var state := PaneInspectorStore.state_for("pane-copy")
	state["system_prompt"] = "changed"
	assert_eq(PaneInspectorStore.state_for("pane-copy").get("system_prompt"), "Keep",
		"a caller cannot edit the store through the returned dictionary")

func test_a_switch_alone_is_a_decision():
	# Auto-send with no prompt is still the user's choice, not the default.
	PaneInspectorStore.set_state("pane-auto", "", true, false)
	assert_eq(PaneInspectorStore.state_for("pane-auto"), {
		"system_prompt": "", "auto_run": true, "accept_concept_captures": false,
	})

func test_unknown_and_invalid_ids_are_empty():
	assert_eq(PaneInspectorStore.state_for("nope"), {})
	PaneInspectorStore.set_state("NOT A VALID id!", "x", true, true)
	assert_eq(PaneInspectorStore.state_for("NOT A VALID id!"), {},
		"an id outside the pane pattern can never match a pane")
	assert_false(MockAutoloads.get_store(PaneInspectorStore.STATE_FILE).has("NOT A VALID id!"))

func test_set_caps_the_prompt():
	var long := "x".repeat(PaneInspectorStore.MAX_PROMPT_CHARS + 50)
	PaneInspectorStore.set_state("pane-x", long, false, false)
	assert_eq(
		str(PaneInspectorStore.state_for("pane-x").get("system_prompt")).length(),
		PaneInspectorStore.MAX_PROMPT_CHARS)

func test_load_caps_prompt_length():
	MockAutoloads.set_store(PaneInspectorStore.STATE_FILE, {
		"pane-x": {"system_prompt": "x".repeat(PaneInspectorStore.MAX_PROMPT_CHARS + 100)},
	})
	PaneInspectorStore.reload()
	assert_eq(str(PaneInspectorStore.state_for("pane-x").get("system_prompt")).length(),
		PaneInspectorStore.MAX_PROMPT_CHARS)

func test_load_drops_bad_entries_not_the_file():
	MockAutoloads.set_store(PaneInspectorStore.STATE_FILE, {
		"ok": {"system_prompt": "hi", "auto_run": true},
		"BAD UPPER!": {"system_prompt": "key outside the pattern"},
		"not-dict": "a string, not a record",
		"wrong-prompt": {"system_prompt": 42},
		"wrong-bool": {"auto_run": "yes"},
		"defaults": {"system_prompt": "", "auto_run": false, "accept_concept_captures": false},
	})
	PaneInspectorStore.reload()
	assert_eq(PaneInspectorStore.state_for("ok"), {
		"system_prompt": "hi", "auto_run": true, "accept_concept_captures": false,
	})
	assert_eq(PaneInspectorStore.state_for("BAD UPPER!"), {}, "a key outside the id pattern is dropped")
	assert_eq(PaneInspectorStore.state_for("not-dict"), {}, "a wrong-shaped entry costs itself")
	assert_eq(PaneInspectorStore.state_for("wrong-prompt"), {}, "a wrong-typed prompt costs its entry")
	assert_eq(PaneInspectorStore.state_for("wrong-bool"), {}, "a wrong-typed switch costs its entry")
	assert_eq(PaneInspectorStore.state_for("defaults"), {}, "an all-default record is absence")

func test_load_caps_entry_count():
	var big := {}
	for i in PaneInspectorStore.MAX_ENTRIES + 20:
		big["pane-%03d" % i] = {"system_prompt": "p"}
	MockAutoloads.set_store(PaneInspectorStore.STATE_FILE, big)
	PaneInspectorStore.reload()
	var count := 0
	for _id in PaneInspectorStore._states:
		count += 1
	assert_eq(count, PaneInspectorStore.MAX_ENTRIES, "a bloated file cannot grow the map")

func test_copy_keeps_the_old_entry_and_never_overwrites():
	PaneInspectorStore.set_state("shared", "Shared prompt", true, false)
	PaneInspectorStore.copy_state("shared", "copy")
	assert_eq(PaneInspectorStore.state_for("copy").get("system_prompt"), "Shared prompt")
	assert_eq(PaneInspectorStore.state_for("shared").get("system_prompt"), "Shared prompt",
		"the first instance keeps its own entry")

	PaneInspectorStore.set_state("taken", "Someone else's", false, true)
	PaneInspectorStore.copy_state("shared", "taken")
	assert_eq(PaneInspectorStore.state_for("taken").get("system_prompt"), "Someone else's",
		"an existing entry at the new id wins")

func test_move_follows_the_id():
	PaneInspectorStore.set_state("old", "Mine", true, true)
	PaneInspectorStore.move_state("old", "new")
	assert_eq(PaneInspectorStore.state_for("old"), {}, "the old id keeps nothing")
	assert_eq(PaneInspectorStore.state_for("new"), {
		"system_prompt": "Mine", "auto_run": true, "accept_concept_captures": true,
	})

	# Moving onto an id that already has a record replaces it: the user renamed
	# this pane, so its values are the ones the panel just applied.
	PaneInspectorStore.set_state("a", "A", false, false)
	PaneInspectorStore.set_state("b", "B", false, false)
	PaneInspectorStore.move_state("a", "b")
	assert_eq(PaneInspectorStore.state_for("a"), {})
	assert_eq(PaneInspectorStore.state_for("b").get("system_prompt"), "A")
