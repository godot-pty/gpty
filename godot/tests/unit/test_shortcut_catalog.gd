extends GutTest
# ShortcutCatalog — the Settings > About list's data.
#
# Defends: the catalog never spells a chord itself (`rows` takes the registry
# reader), a group with no bound action contributes no heading, and the "New
# Panes" group follows `PaneTypes.ALL` instead of a second list.

## The reader every row passes: a fixed chord, so the assertions are about the
## list's shape, not the bindings.
func _every_action_bound(_action: String) -> String:
	return "Ctrl+X"

func _nothing_bound(_action: String) -> String:
	return ""

func test_the_groups_keep_their_reading_order():
	var titles: Array[String] = []
	for group in ShortcutCatalog.groups():
		titles.append(str(group["title"]))
	var expected: Array[String] = [
		"Workspace", "New Panes", "Panes", "Keyboard Focus", "Terminal"]
	assert_eq(titles, expected,
		"the list reads workspace → creating → acting → reaching → terminal")


func test_every_row_carries_the_registry_chord():
	var rows := ShortcutCatalog.rows(_every_action_bound)
	assert_gt(rows.size(), 0, "the catalog always offers rows")
	for row in rows:
		assert_eq(str(row["chord"]), "Ctrl+X", "the chord is the reader's answer")
		assert_ne(str(row["label"]), "", "a row without words is not a row")
		assert_ne(str(row["group"]), "", "every row belongs to a heading")


func test_an_unbound_action_drops_out_instead_of_claiming_a_key():
	assert_eq(ShortcutCatalog.rows(_nothing_bound), [],
		"a reader that knows no binding yields no rows, so no heading either")


func test_the_new_pane_group_follows_the_pane_registry():
	var expected: Array[String] = []
	for key in PaneTypes.ALL:
		var info: Dictionary = PaneTypes.ALL[key]
		if str(info.get("shortcut", "")).strip_edges() == "":
			continue
		expected.append("New %s pane" % info["name"])
	assert_gt(expected.size(), 0, "the registry declares spawn shortcuts")
	var actual: Array[String] = []
	for entry in ShortcutCatalog.new_pane_entries():
		actual.append(str(entry["label"]))
	assert_eq(actual, expected,
		"one row per type that declares a shortcut, in registry order")


func test_a_pane_type_without_a_spawn_shortcut_has_no_row():
	# The media pane ships with no chord; a row for it would print an empty
	# hint and read as a binding that does nothing.
	for entry in ShortcutCatalog.new_pane_entries():
		assert_false(str(entry["action"]).ends_with("_media"),
			"a type with no shortcut must not get a row")


func test_the_declared_terminal_chords_are_listed_without_a_workspace():
	# `term:*` is declared by the autoload, so this list is populated in a bare
	# test process; the app:* group is not, because only a workspace registers
	# it. One real reader, no fake.
	var rows := ShortcutCatalog.rows(func(action: String): return ShortcutManager.chord(action))
	var terminal: Array[String] = []
	for row in rows:
		if str(row["group"]) == "Terminal":
			terminal.append("%s = %s" % [str(row["label"]), str(row["chord"])])
	var expected: Array[String] = [
		"Open the scrollback search bar = Ctrl+Shift+F",
		"Copy the selection = Ctrl+Shift+C",
		"Paste the clipboard = Ctrl+Shift+V",
	]
	assert_eq(terminal, expected,
		"the terminal group spells the declared chords as the handler reads them")
