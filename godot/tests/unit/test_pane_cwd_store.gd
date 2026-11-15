extends GutTest
# PaneCwdStore — the user-owned per-pane directory map, keyed by
# `<workspace id>/<attachment id>`.
#
# A file must not supply a directory (the settings table marks `pane_cwd`
# `file: false`/`ipc: false`, and the workspace half of the key is minted
# locally), so its loader is the same hand-edited-file boundary as every other
# store: typed reads, an id-pattern key check, and size caps. The pane settings
# UI being its only writer is pinned by the integration test, not here.

const WS := "ws-0123456789ab"
const WS2 := "ws-ba9876543210"

var _dirs: Array[String] = []

func before_each():
	MockAutoloads.setup()

func after_each():
	for dir in _dirs:
		DirAccess.remove_absolute(dir)
	_dirs.clear()
	MockAutoloads.teardown()

## An existing absolute directory in the throwaway user-data dir.
func _temp_dir(slug: String) -> String:
	var dir := OS.get_user_data_dir().path_join(
		"gpty-test-%s-%d" % [slug, Time.get_ticks_usec()])
	DirAccess.make_dir_absolute(dir)
	_dirs.append(dir)
	return dir

func test_set_and_remove_roundtrip():
	var dir := _temp_dir("set")
	PaneCwdStore.set_dir(WS, "pane-abc", dir)
	assert_eq(PaneCwdStore.dir_for(WS, "pane-abc"), dir)
	assert_eq(
		MockAutoloads.get_store(PaneCwdStore.DIR_FILE).get("%s/pane-abc" % WS), dir,
		"the entry must reach the store file")
	# An empty value removes the override — the pane inherits the workspace's.
	PaneCwdStore.set_dir(WS, "pane-abc", "   ")
	assert_eq(PaneCwdStore.dir_for(WS, "pane-abc"), "")
	assert_false(MockAutoloads.get_store(PaneCwdStore.DIR_FILE).has("%s/pane-abc" % WS))

func test_relative_oversized_control_and_virtual_paths_are_refused():
	var cases := {
		"relative": "repo",
		"oversized": "/tmp/" + "x".repeat(PaneCwdStore.MAX_DIR_CHARS),
		"newline": "/tmp/a\nb",
		"delete": "/tmp/a\u007fb",
		"virtual": "user://pane_cwd",
	}
	for label in cases:
		PaneCwdStore.set_dir(WS, "pane-" + label, str(cases[label]))
		assert_eq(PaneCwdStore.dir_for(WS, "pane-" + label), "",
			"%s must not be stored as a directory" % label)

func test_unknown_and_invalid_keys_are_empty():
	assert_eq(PaneCwdStore.dir_for(WS, "nope"), "")
	var dir := _temp_dir("keys")
	# Both halves are the grammars the app mints: an entry outside them could
	# never match a workspace or a pane, so it is refused instead of stored.
	PaneCwdStore.set_dir("agent-workspace", "pane-x", dir)
	assert_false(MockAutoloads.get_store(PaneCwdStore.DIR_FILE).has("agent-workspace/pane-x"))
	PaneCwdStore.set_dir("ws-XYZ", "pane-x", dir)
	assert_eq(PaneCwdStore.dir_for("ws-XYZ", "pane-x"), "")
	PaneCwdStore.set_dir(WS, "NOT A VALID id!", dir)
	assert_eq(PaneCwdStore.dir_for(WS, "NOT A VALID id!"), "")

func test_load_drops_bad_keys_and_wrong_types():
	var dir := _temp_dir("load")
	MockAutoloads.set_store(PaneCwdStore.DIR_FILE, {
		"%s/ok" % WS: dir,
		"no-slash-at-all": dir,
		"agent-workspace/ok": dir,
		"%s/two/slashes" % WS: dir,
		"%s/not-string" % WS: 42,
		"%s/relative" % WS: "repo",
		"%s/empty" % WS: "",
	})
	PaneCwdStore.reload()
	assert_eq(PaneCwdStore.dir_for(WS, "ok"), dir)
	assert_eq(PaneCwdStore.dir_for(WS, "not-string"), "", "a wrong-typed value costs one entry")
	assert_eq(PaneCwdStore.dir_for(WS, "relative"), "", "a relative value is dropped on load too")
	assert_eq(PaneCwdStore.dir_for(WS, "empty"), "")

func test_load_caps_entry_count():
	var seed := {}
	for i in PaneCwdStore.MAX_ENTRIES + 20:
		seed["%s/pane-%03d" % [WS, i]] = "/tmp/gpty-pane-%d" % i
	MockAutoloads.set_store(PaneCwdStore.DIR_FILE, seed)
	PaneCwdStore.reload()
	var count := 0
	for _key in PaneCwdStore._dirs:
		count += 1
	assert_eq(count, PaneCwdStore.MAX_ENTRIES, "a bloated file cannot grow the map")

func test_move_pane_carries_the_entry():
	var dir := _temp_dir("move")
	PaneCwdStore.set_dir(WS, "old-id", dir)
	PaneCwdStore.move_pane(WS, "old-id", "new-id")
	assert_eq(PaneCwdStore.dir_for(WS, "new-id"), dir)
	assert_eq(PaneCwdStore.dir_for(WS, "old-id"), "", "the old id must not keep the entry")

func test_drop_workspace_removes_only_that_workspace():
	var a := _temp_dir("drop-a")
	var b := _temp_dir("drop-b")
	PaneCwdStore.set_dir(WS, "pane-a", a)
	PaneCwdStore.set_dir(WS2, "pane-b", b)
	PaneCwdStore.drop_workspace(WS)
	assert_eq(PaneCwdStore.dir_for(WS, "pane-a"), "")
	assert_eq(PaneCwdStore.dir_for(WS2, "pane-b"), b, "another workspace keeps its entries")

func test_retain_workspaces_drops_the_rest():
	var a := _temp_dir("retain-a")
	var b := _temp_dir("retain-b")
	PaneCwdStore.set_dir(WS, "pane-a", a)
	PaneCwdStore.set_dir(WS2, "pane-b", b)
	PaneCwdStore.retain_workspaces(PackedStringArray([WS]))
	assert_eq(PaneCwdStore.dir_for(WS, "pane-a"), a)
	assert_eq(PaneCwdStore.dir_for(WS2, "pane-b"), "")

func test_resolve_prefers_the_pane_then_the_workspace():
	var own := _temp_dir("resolve-own")
	var ws_dir := _temp_dir("resolve-ws")
	assert_eq(
		PaneCwdStore.resolve(WS, "pane-a", own, ws_dir), own,
		"a usable override wins over the workspace's directory")
	assert_eq(
		PaneCwdStore.resolve(WS, "pane-a", "", ws_dir), ws_dir,
		"no override means the workspace's directory")
	assert_eq(
		PaneCwdStore.resolve(WS, "pane-a", "", ""), "",
		"neither means the child inherits gpty's own directory")

func test_resolve_falls_back_when_a_directory_is_missing():
	var ws_dir := _temp_dir("stale-ws")
	var gone := OS.get_user_data_dir().path_join("gpty-test-gone-%d" % Time.get_ticks_usec())
	assert_eq(
		PaneCwdStore.resolve(WS, "pane-a", gone, ws_dir), ws_dir,
		"a stale override falls back to the workspace's directory")
	assert_eq(
		PaneCwdStore.resolve(WS, "pane-b", gone, ""), "",
		"both unusable means gpty's own directory, never the stale path")
