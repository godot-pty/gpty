extends GutTest
# SavedCommandStore — the user-owned saved commands. The store is the one place
# a saved command lives, and its file is hand-editable, so the loader is the
# same boundary as every other store's: typed reads, sanitizing, a uniqueness
# rule and caps. The store being the UI's only target is pinned by the
# integration test, not here.

func before_each():
	MockAutoloads.setup()

func after_each():
	MockAutoloads.teardown()

func test_add_keeps_order_and_the_run_flag():
	assert_eq(SavedCommandStore.add("Build", "cargo build", false), "")
	assert_eq(SavedCommandStore.add("Test", "cargo test", true), "")
	var entries := SavedCommandStore.all()
	assert_eq(entries.size(), 2)
	assert_eq(entries[0], {"name": "Build", "command": "cargo build", "run": false})
	assert_eq(entries[1], {"name": "Test", "command": "cargo test", "run": true})
	# The file is the same list: a reload sees exactly what the API returned.
	assert_eq(MockAutoloads.get_store(SavedCommandStore.COMMANDS_FILE),
		{"commands": [{"name": "Build", "command": "cargo build", "run": false},
			{"name": "Test", "command": "cargo test", "run": true}]})

func test_run_defaults_off():
	SavedCommandStore.add("Quiet", "ls")
	assert_false(SavedCommandStore.all()[0]["run"],
		"a new command inserts; pressing Enter is opt-in")

func test_find_matches_the_exact_name():
	SavedCommandStore.add("Build", "cargo build")
	assert_eq(SavedCommandStore.find("Build")["command"], "cargo build")
	assert_eq(SavedCommandStore.find("build"), {}, "the palette round-trips the exact name")
	assert_eq(SavedCommandStore.find("Build")["run"], false)

func test_all_and_find_hand_out_copies():
	SavedCommandStore.add("Build", "cargo build")
	SavedCommandStore.all()[0]["command"] = "rm -rf /"
	SavedCommandStore.find("Build")["command"] = "rm -rf /"
	assert_eq(SavedCommandStore.all()[0]["command"], "cargo build")

func test_clean_command_makes_one_line():
	# A Godot String cannot hold a NUL at all (measured: both a `\u0000`
	# literal and `String.chr(0)` read back as U+FFFD), so a control character
	# that reaches here is one of the ones below.
	# LF, CR and TAB become a space; every other control is dropped outright,
	# so the bell between "c" and "d" leaves them adjacent.
	assert_eq(SavedCommandStore.clean_command("a\nb\tc\u0007d"), "a b cd")
	assert_eq(SavedCommandStore.clean_command("  cargo build  "), "cargo build")
	assert_eq(SavedCommandStore.clean_command("a\u0007b\u007fc"), "abc",
		"a bell or DEL is dropped, not spaced")

func test_clean_name_drops_controls_and_is_not_a_line():
	assert_eq(SavedCommandStore.clean_name("  Build\tall\n\u0001 "), "Buildall")

func test_command_is_capped_at_the_cap():
	var long := "x".repeat(SavedCommandStore.MAX_COMMAND_CHARS * 2)
	assert_eq(SavedCommandStore.add("Long", long), "")
	assert_eq(SavedCommandStore.all()[0]["command"].length(), SavedCommandStore.MAX_COMMAND_CHARS)

func test_a_duplicate_name_is_refused_and_changes_nothing():
	SavedCommandStore.add("Build", "cargo build")
	var before := SavedCommandStore.all()
	assert_eq(SavedCommandStore.add("build", "cargo test"),
		"A saved command named 'build' already exists",
		"names are compared case-insensitively: two rows the dispatcher cannot tell apart")
	assert_eq(SavedCommandStore.all(), before)

func test_empty_name_or_command_is_refused():
	assert_eq(SavedCommandStore.add("  ", "ls"), "A saved command needs a name")
	assert_eq(SavedCommandStore.add("Name", " \n "), "A saved command needs a command")
	assert_eq(SavedCommandStore.all(), [])

func test_the_entry_cap_is_refused():
	for i in SavedCommandStore.MAX_ENTRIES:
		assert_eq(SavedCommandStore.add("c%03d" % i, "true", false), "")
	assert_eq(SavedCommandStore.add("one more", "true"),
		"At most %d saved commands" % SavedCommandStore.MAX_ENTRIES)
	assert_eq(SavedCommandStore.all().size(), SavedCommandStore.MAX_ENTRIES)

func test_update_replaces_in_place_and_keeps_its_own_name():
	SavedCommandStore.add("Build", "cargo build", false)
	SavedCommandStore.add("Test", "cargo test", false)
	assert_eq(SavedCommandStore.update(1, "Test", "cargo test --workspace", true), "",
		"an edit may keep the name it already has")
	assert_eq(SavedCommandStore.all()[1],
		{"name": "Test", "command": "cargo test --workspace", "run": true})
	assert_eq(SavedCommandStore.update(1, "Build", "ls"),
		"A saved command named 'Build' already exists")
	assert_eq(SavedCommandStore.update(9, "Gone", "ls"),
		"That command is no longer in the list")

func test_remove_and_move():
	SavedCommandStore.add("A", "a")
	SavedCommandStore.add("B", "b")
	SavedCommandStore.add("C", "c")
	assert_eq(SavedCommandStore.move(0, 1), 1)
	assert_eq(SavedCommandStore.all().map(func(e): return e["name"]), ["B", "A", "C"])
	assert_eq(SavedCommandStore.move(0, -1), 0, "the first row cannot move up")
	assert_eq(SavedCommandStore.all().map(func(e): return e["name"]), ["B", "A", "C"])
	assert_eq(SavedCommandStore.move(2, 5), 2, "the last row cannot move down")
	SavedCommandStore.remove(0)
	assert_eq(SavedCommandStore.all().map(func(e): return e["name"]), ["A", "C"])
	SavedCommandStore.remove(9)
	assert_eq(SavedCommandStore.all().size(), 2, "an out-of-range remove is a no-op")

# ── The hand-edited file ───────────────────────────────────────────────

func test_load_drops_junk_duplicates_and_caps_the_oversize():
	MockAutoloads.set_store(SavedCommandStore.COMMANDS_FILE, {"commands": [
		{"name": "Build", "command": "cargo build", "run": false},
		"not an entry",
		{"name": 42, "command": "ls"},
		{"name": "NoCommand", "command": "   "},
		{"name": "build", "command": "cargo test", "run": true},
		{"name": "Long", "command": "x".repeat(SavedCommandStore.MAX_COMMAND_CHARS + 10)},
		{"name": "Run", "command": "true", "run": 1},
	]})
	SavedCommandStore.reload()
	var names := SavedCommandStore.all().map(func(e): return e["name"])
	assert_eq(names, ["Build", "Long", "Run"],
		"a bad item costs itself; the first of two duplicate names wins")
	assert_eq(SavedCommandStore.all()[1]["command"].length(), SavedCommandStore.MAX_COMMAND_CHARS)
	assert_true(SavedCommandStore.all()[2]["run"], "a truthy 1 reads as run")

func test_load_caps_the_entry_count():
	var big := []
	for i in SavedCommandStore.MAX_ENTRIES + 20:
		big.append({"name": "c%03d" % i, "command": "true"})
	MockAutoloads.set_store(SavedCommandStore.COMMANDS_FILE, {"commands": big})
	SavedCommandStore.reload()
	assert_eq(SavedCommandStore.all().size(), SavedCommandStore.MAX_ENTRIES)

func test_a_wrong_shaped_file_is_empty_not_fatal():
	MockAutoloads.set_store(SavedCommandStore.COMMANDS_FILE, {"commands": {"name": "Build"}})
	SavedCommandStore.reload()
	assert_eq(SavedCommandStore.all(), [], "a non-array costs every entry, not the launch")
