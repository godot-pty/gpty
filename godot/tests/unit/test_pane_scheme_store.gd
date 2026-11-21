extends GutTest
# PaneSchemeStore — the user-owned per-pane colour scheme. A file must not
# style a pane, and this store is the only thing that can; its loader is the
# same hand-edited-file boundary as every other store: typed reads, an
# id-pattern key check, and size caps. The UI being its only writer is pinned
# by the pane-settings integration path, not here.

func before_each():
	MockAutoloads.setup()

func after_each():
	MockAutoloads.teardown()

func test_set_get_remove_round_trip():
	PaneSchemeStore.set_scheme("pane-abc", " user://schemes/nord.json ")
	assert_eq(PaneSchemeStore.scheme_for("pane-abc"), "user://schemes/nord.json")
	assert_eq(MockAutoloads.get_store(PaneSchemeStore.SCHEME_FILE).get("pane-abc"),
		"user://schemes/nord.json")
	# An empty value removes the override — the pane follows Settings again.
	PaneSchemeStore.set_scheme("pane-abc", "  ")
	assert_eq(PaneSchemeStore.scheme_for("pane-abc"), "")
	assert_false(MockAutoloads.get_store(PaneSchemeStore.SCHEME_FILE).has("pane-abc"))

func test_a_path_over_the_cap_is_refused():
	var long := "x".repeat(PaneSchemeStore.MAX_PATH_CHARS + 1)
	PaneSchemeStore.set_scheme("pane-x", long)
	assert_eq(PaneSchemeStore.scheme_for("pane-x"), "",
		"a cut path names nothing, so an over-cap one is refused rather than truncated")

func test_a_bad_id_is_refused():
	assert_eq(PaneSchemeStore.scheme_for("nope"), "")
	PaneSchemeStore.set_scheme("NOT A VALID id!", "user://schemes/nord.json")
	assert_eq(PaneSchemeStore.scheme_for("NOT A VALID id!"), "")
	assert_false(MockAutoloads.get_store(PaneSchemeStore.SCHEME_FILE).has("NOT A VALID id!"))

func test_load_drops_bad_keys_and_wrong_types():
	MockAutoloads.set_store(PaneSchemeStore.SCHEME_FILE, {
		"ok": "user://schemes/nord.json",
		"BAD UPPER!": "user://schemes/nord.json",
		"not-string": 42,
		"empty": "",
	})
	PaneSchemeStore.reload()
	assert_eq(PaneSchemeStore.scheme_for("ok"), "user://schemes/nord.json")
	assert_eq(PaneSchemeStore.scheme_for("BAD UPPER!"), "", "keys outside the id pattern are dropped")
	assert_eq(PaneSchemeStore.scheme_for("not-string"), "", "a wrong-typed value costs one entry")
	assert_eq(PaneSchemeStore.scheme_for("empty"), "")

func test_setting_the_same_value_writes_nothing():
	PaneSchemeStore.set_scheme("pane-x", "user://schemes/nord.json")
	assert_eq(MockAutoloads.write_count(PaneSchemeStore.SCHEME_FILE), 1, "a real change writes")
	PaneSchemeStore.set_scheme("pane-x", "  user://schemes/nord.json  ")
	assert_eq(MockAutoloads.write_count(PaneSchemeStore.SCHEME_FILE), 1,
		"the same value must not rewrite the store")
	PaneSchemeStore.remove_scheme("pane-absent")
	assert_eq(MockAutoloads.write_count(PaneSchemeStore.SCHEME_FILE), 1,
		"removing an entry that is not there writes nothing")
