extends GutTest
# PaletteModel — what the command palette offers, as pure data.
#
# What can break here is drift: a pane type the registry has and the palette
# does not, a label that repeats its command id, a duplicate command (Enter's
# target would be ambiguous), or a filter that ranks a weak hit above a strong
# one. None of it needs a scene tree.

func _commands_of(entries: Array) -> Array:
	var out := []
	for entry in entries:
		out.append(str(entry["command"]))
	return out

func _entry(command: String) -> Dictionary:
	for entry in PaletteModel.entries():
		if str(entry["command"]) == command:
			return entry
	return {}

func test_entries_are_one_per_pane_type_then_the_actions():
	var all := PaletteModel.entries()
	assert_eq(all.size(), PaneTypes.ALL.size() + PaletteModel.ACTIONS.size(),
		"every registry entry, then every action")
	for i in PaneTypes.ALL.size():
		assert_true(str(all[i]["command"]).begins_with("new "),
			"entry %d is a pane type, in registry order" % i)
	var actions := []
	for entry in PaletteModel.ACTIONS:
		actions.append([entry["command"], entry["label"]])
	for i in PaletteModel.ACTIONS.size():
		var entry: Dictionary = all[PaneTypes.ALL.size() + i]
		assert_eq([entry["command"], entry["label"]], actions[i],
			"the action tail keeps ACTIONS' order")

func test_commands_are_unique():
	var seen := {}
	for command in PaletteModel.commands():
		assert_false(seen.has(command), "'%s' is listed twice" % command)
		seen[command] = true

func test_every_entry_is_honest():
	for entry in PaletteModel.entries():
		var label := str(entry["label"])
		var command := str(entry["command"])
		assert_ne(label, "", "'%s' shows words" % command)
		assert_ne(label, command, "'%s' is not shown as its own id" % command)
		assert_ne(command, "spawn 16 terminals", "the developer-only command is gone")
		var action := str(entry["action"])
		if action != "":
			assert_true(action.begins_with("app:"),
				"'%s' names a ShortcutManager action, not a literal chord" % action)

func test_save_and_load_say_what_they_act_on():
	var save := str(_entry("save").get("label", ""))
	var load := str(_entry("load").get("label", ""))
	assert_ne(save, load, "the pair no longer reads as two four-letter verbs")
	assert_true(save.contains("Workspaces"), "'save' says what it saves")
	assert_true(load.contains("Workspaces"), "'load' says what it loads")
	assert_true(save.contains("Save"), "'save' starts with its verb")
	assert_true(load.contains("Reload"),
		"'load' destroys the open panes, so it says reload rather than load")

func test_matching_is_case_insensitive_and_ranked():
	assert_eq(PaletteModel.filter(""), PaletteModel.entries(),
		"an empty query keeps the whole list in order")
	assert_eq(_commands_of(PaletteModel.filter("WIKI")), ["new wiki"],
		"matching ignores case")
	assert_eq(_commands_of(PaletteModel.filter("cl")),
		["close active", "close all", "new cli view"],
		"two label prefixes in model order, then a label substring")
	assert_eq(PaletteModel.filter("no such command"), [],
		"a miss lists nothing")

func test_mutating_a_returned_entry_does_not_touch_the_model():
	var first := PaletteModel.entries()
	first[0]["label"] = "Mutated"
	assert_eq(str(PaletteModel.entries()[0]["label"]), "New Terminal",
		"a caller edits its own copy, never the const")

# ── Saved commands ─────────────────────────────────────────────────────

func _saved() -> Array:
	return [
		{"name": "Build", "command": "cargo build", "run": false},
		{"name": "Deploy", "command": "make deploy", "run": true},
	]

func test_saved_entries_follow_the_actions_in_store_order():
	var all := PaletteModel.entries(_saved())
	assert_eq(all.size(), PaneTypes.ALL.size() + PaletteModel.ACTIONS.size() + 2)
	var build: Dictionary = all[all.size() - 2]
	var deploy: Dictionary = all[all.size() - 1]
	assert_eq(build, {
		"command": "saved: Build", "label": "Build", "glyph": "", "action": "",
		"keywords": "saved command insert run", "variation": &"",
		"section": "Saved commands", "hint": "Insert", "run": false,
	})
	assert_eq(deploy["hint"], "Run", "the hint is the entry's own run flag")
	assert_true(bool(deploy["run"]))
	assert_eq(build["command"], PaletteModel.SAVED_PREFIX + "Build",
		"the dispatcher round-trips the exact name")

func test_nothing_saved_is_the_untruncated_list():
	assert_eq(PaletteModel.entries(), PaletteModel.entries([]),
		"the store being empty must not change one row")
	assert_eq(PaletteModel.commands(), PaletteModel.commands([]))
	assert_eq(PaletteModel.filter(""), PaletteModel.entries())

func test_a_bad_saved_item_costs_itself():
	var all := PaletteModel.entries([{"name": "", "command": "ls"}, "junk",
		{"command": "no name"}])
	assert_eq(all.size(), PaletteModel.entries().size())

func test_filtering_a_saved_command_by_name():
	var hits := PaletteModel.filter("build", _saved())
	assert_eq(_commands_of(hits), ["saved: Build"])
	assert_eq(_commands_of(PaletteModel.filter("deploy", _saved())), ["saved: Deploy"])

func test_a_saved_command_is_reachable_by_its_keywords():
	var hits := PaletteModel.filter("insert", _saved())
	assert_eq(_commands_of(hits), ["saved: Build", "saved: Deploy"],
		"both entries say how they behave, and the words stay in model order")
