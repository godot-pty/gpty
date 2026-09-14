extends GutTest
# PaneEnvStore — the user-owned per-pane env map. A file must not supply env,
# and this store is the only thing that can; so its loader is the same
# hand-edited-file boundary as every other store: typed reads, an id-pattern
# key check, and size caps. The UI being its only writer is pinned by the
# integration test, not here.

func before_each():
	MockAutoloads.setup()

func after_each():
	MockAutoloads.teardown()

func test_set_and_remove_roundtrip():
	PaneEnvStore.set_env("pane-abc", "  A=1\nB=2  ")
	assert_eq(PaneEnvStore.env_for("pane-abc"), "A=1\nB=2")
	assert_eq(MockAutoloads.get_store(PaneEnvStore.ENV_FILE).get("pane-abc"), "A=1\nB=2")
	# An empty value removes the override — the pane inherits the global env.
	PaneEnvStore.set_env("pane-abc", "   ")
	assert_eq(PaneEnvStore.env_for("pane-abc"), "")
	assert_false(MockAutoloads.get_store(PaneEnvStore.ENV_FILE).has("pane-abc"))

func test_unknown_and_invalid_ids_are_empty():
	assert_eq(PaneEnvStore.env_for("nope"), "")
	# The id pattern is the panes' own: an entry outside it can never match a
	# pane, so it is refused instead of stored.
	PaneEnvStore.set_env("NOT A VALID id!", "A=1")
	assert_eq(PaneEnvStore.env_for("NOT A VALID id!"), "")
	assert_false(MockAutoloads.get_store(PaneEnvStore.ENV_FILE).has("NOT A VALID id!"))

func test_set_caps_the_value():
	var long := "x".repeat(PaneEnvStore.MAX_VALUE_CHARS + 50)
	PaneEnvStore.set_env("pane-x", long)
	assert_eq(PaneEnvStore.env_for("pane-x").length(), PaneEnvStore.MAX_VALUE_CHARS)

func test_load_drops_bad_keys_and_wrong_types():
	MockAutoloads.set_store(PaneEnvStore.ENV_FILE, {
		"ok": "A=1",
		"BAD UPPER!": "B=2",
		"not-string": 42,
		"empty": "",
	})
	PaneEnvStore.reload()
	assert_eq(PaneEnvStore.env_for("ok"), "A=1")
	assert_eq(PaneEnvStore.env_for("BAD UPPER!"), "", "keys outside the id pattern are dropped")
	assert_eq(PaneEnvStore.env_for("not-string"), "", "a wrong-typed value costs one entry")
	assert_eq(PaneEnvStore.env_for("empty"), "")

func test_load_caps_value_length():
	MockAutoloads.set_store(PaneEnvStore.ENV_FILE, {
		"pane-x": "x".repeat(PaneEnvStore.MAX_VALUE_CHARS + 100),
	})
	PaneEnvStore.reload()
	assert_eq(PaneEnvStore.env_for("pane-x").length(), PaneEnvStore.MAX_VALUE_CHARS)

func test_load_caps_entry_count():
	var big := {}
	for i in PaneEnvStore.MAX_ENTRIES + 20:
		big["pane-%03d" % i] = "A=1"
	MockAutoloads.set_store(PaneEnvStore.ENV_FILE, big)
	PaneEnvStore.reload()
	var count := 0
	for _id in PaneEnvStore._env:
		count += 1
	assert_eq(count, PaneEnvStore.MAX_ENTRIES, "a bloated file cannot grow the map")
