extends GutTest
# LinkWeights + LinkWeightsStore — the authored layer over the link graph's
# measured mention counts. The vocabulary is the index's own note-path shape,
# the store is a user-owned hand-editable file, and the rules that matter are:
# one spelling per vault, one spelling per note path, a bounded weight range,
# both directions of the canvas's pair written together, caps, and pruning
# only what a complete graph proved gone.

const VAULT := "/test/vault"

## A real directory for the IPC arm's own vault check. Nothing is written in
## it: the store is mocked, and the handler only asks whether the root is a
## directory.
var _ipc_vault := ""

func before_each():
	MockAutoloads.setup()
	_ipc_vault = ProjectSettings.globalize_path("user://link_weights_probe")
	DirAccess.make_dir_recursive_absolute(_ipc_vault)

func after_each():
	DirAccess.remove_absolute(_ipc_vault)
	MockAutoloads.teardown()


# ── Vocabulary ─────────────────────────────────────────────────────────

func test_note_paths_follow_the_walks_vocabulary():
	for good in ["a.md", "dir/b.md", "A.B.md", "deep/er/c.md"]:
		assert_true(LinkWeights.valid_note_path(good), "%s is a note path" % good)
	for bad in [
		"", "/abs/a.md", "../escape.md", "dir/../x.md", ".hidden.md",
		"dir/.hidden/b.md", "notes/x.txt", "notes//x.md", "notes\\x.md",
		".md", "x.md/",
	]:
		assert_false(LinkWeights.valid_note_path(bad), "%s is not a note path" % bad)
	assert_false(
		LinkWeights.valid_note_path("a".repeat(LinkWeights.MAX_NOTE_PATH_BYTES) + ".md"),
		"an over-long path is refused"
	)


func test_vault_normalization_is_one_spelling():
	assert_eq(LinkWeights.normalize_vault("/test/vault/"), VAULT)
	assert_eq(LinkWeights.normalize_vault("/test//vault"), VAULT)
	assert_eq(LinkWeights.normalize_vault("/test/./vault"), VAULT)
	assert_eq(LinkWeights.normalize_vault("/"), "/", "a filesystem root keeps its separator")
	assert_false(LinkWeights.valid_vault_path("relative/vault"))
	assert_true(LinkWeights.valid_vault_path(VAULT))


func test_lookup_ignores_wrong_types_and_out_of_range_values():
	var weights := {
		"a.md": {"b.md": 10, "c.md": "20", "d.md": 0, "e.md": LinkWeights.MAX_WEIGHT + 1},
		"bad": "not a map",
	}
	assert_eq(LinkWeights.lookup(weights, "a.md", "b.md"), 10)
	assert_eq(LinkWeights.lookup(weights, "a.md", "c.md"), 0, "a string is not a weight")
	assert_eq(LinkWeights.lookup(weights, "a.md", "d.md"), 0, "0 means absent, never stored")
	assert_eq(LinkWeights.lookup(weights, "a.md", "e.md"), 0, "out of range reads as absent")
	assert_eq(LinkWeights.lookup(weights, "bad", "x.md"), 0)
	assert_eq(LinkWeights.lookup(weights, "a.md", "missing.md"), 0)
	assert_eq(LinkWeights.count(weights), 4, "count sees the raw map's pairs")


# ── Writing ────────────────────────────────────────────────────────────

func test_a_weight_roundtrip_lands_in_the_user_store():
	assert_eq(LinkWeightsStore.set_weight(VAULT, "a.md", "b.md", 25), "")
	assert_eq(LinkWeightsStore.weight_of(VAULT, "a.md", "b.md"), 25)
	assert_eq(
		MockAutoloads.get_store(LinkWeightsStore.WEIGHTS_FILE),
		{"vaults": {VAULT: {"a.md": {"b.md": 25}}}},
		"the file is the nested, human-editable shape"
	)
	# A trailing separator is the same vault, not a second entry.
	assert_eq(LinkWeightsStore.weight_of(VAULT + "/", "a.md", "b.md"), 25)


func test_set_pair_writes_both_directions_and_clear_pair_removes_both():
	assert_eq(LinkWeightsStore.set_pair(VAULT, "a.md", "b.md", 40), "")
	assert_eq(LinkWeightsStore.weight_of(VAULT, "a.md", "b.md"), 40)
	assert_eq(LinkWeightsStore.weight_of(VAULT, "b.md", "a.md"), 40)
	assert_eq(LinkWeightsStore.clear_pair(VAULT, "a.md", "b.md"), "")
	assert_eq(LinkWeightsStore.weight_of(VAULT, "a.md", "b.md"), 0)
	assert_eq(LinkWeightsStore.weight_of(VAULT, "b.md", "a.md"), 0)
	# Clearing an absent declaration is a successful no-op.
	assert_eq(LinkWeightsStore.clear_weight(VAULT, "a.md", "b.md"), "")


func test_invalid_paths_and_weights_are_refused_without_writing():
	assert_ne(LinkWeightsStore.set_weight("relative", "a.md", "b.md", 5), "")
	assert_ne(LinkWeightsStore.set_weight(VAULT, "../a.md", "b.md", 5), "")
	assert_ne(LinkWeightsStore.set_weight(VAULT, "a.md", "b.txt", 5), "")
	assert_ne(LinkWeightsStore.set_weight(VAULT, "a.md", "b.md", 0), "")
	assert_ne(LinkWeightsStore.set_weight(VAULT, "a.md", "b.md", LinkWeights.MAX_WEIGHT + 1), "")
	assert_ne(LinkWeightsStore.set_pair(VAULT, "a.md", "a.md", 5), "",
		"a self-pair is not a link")
	assert_eq(MockAutoloads.get_store(LinkWeightsStore.WEIGHTS_FILE), {},
		"nothing invalid reached the file")


func test_vault_weights_returns_a_copy():
	LinkWeightsStore.set_weight(VAULT, "a.md", "b.md", 5)
	var copy := LinkWeightsStore.vault_weights(VAULT)
	copy["a.md"]["b.md"] = 99
	assert_eq(LinkWeightsStore.weight_of(VAULT, "a.md", "b.md"), 5,
		"a caller cannot mutate the store's map")


# ── Loading ────────────────────────────────────────────────────────────

func test_reload_drops_bad_entries_and_keeps_good_ones():
	MockAutoloads.set_store(LinkWeightsStore.WEIGHTS_FILE, {"vaults": {
		VAULT: {
			"a.md": {
				"b.md": 7,
				"..": 5,
				".hidden.md": 5,
				"c.txt": 5,
				"zero.md": 0,
				"big.md": LinkWeights.MAX_WEIGHT + 1,
				"str.md": "12",
				"bool.md": true,
			},
			"bad.txt": {"b.md": 5},
			"not-a-map": 5,
		},
		"relative/vault": {"a.md": {"b.md": 5}},
		"/other/vault": "not a map",
	}})
	LinkWeightsStore.reload()
	assert_eq(LinkWeightsStore.weight_of(VAULT, "a.md", "b.md"), 7)
	# The store reads a hand-edited value through the same typed accessors as
	# every other store: a numeric string is that number, a bool is 0/1.
	assert_eq(LinkWeightsStore.weight_of(VAULT, "a.md", "str.md"), 12)
	assert_eq(LinkWeightsStore.weight_of(VAULT, "a.md", "bool.md"), 1)
	assert_eq(LinkWeightsStore.weight_of(VAULT, "a.md", ".."), 0)
	assert_eq(LinkWeightsStore.weight_of(VAULT, "a.md", "big.md"), 0)
	assert_eq(LinkWeightsStore.weight_of(VAULT, "bad.txt", "b.md"), 0)
	assert_eq(LinkWeightsStore.weight_of("relative/vault", "a.md", "b.md"), 0,
		"a relative vault root is not a key")
	assert_true(LinkWeightsStore._vaults.has(VAULT))


func test_reload_caps_the_entries():
	var big := {}
	for i in LinkWeights.MAX_ENTRIES + 20:
		big["note-%04d.md" % i] = {"other-%04d.md" % i: 5}
	MockAutoloads.set_store(LinkWeightsStore.WEIGHTS_FILE, {"vaults": {VAULT: big}})
	LinkWeightsStore.reload()
	assert_eq(
		LinkWeights.count(LinkWeightsStore.vault_weights(VAULT)),
		LinkWeights.MAX_ENTRIES,
		"a bloated file cannot grow the map"
	)


func test_a_full_vault_refuses_a_new_pair():
	var big := {}
	for i in LinkWeights.MAX_ENTRIES:
		big["note-%04d.md" % i] = {"other-%04d.md" % i: 5}
	MockAutoloads.set_store(LinkWeightsStore.WEIGHTS_FILE, {"vaults": {VAULT: big}})
	LinkWeightsStore.reload()
	assert_ne(LinkWeightsStore.set_weight(VAULT, "new.md", "target.md", 5), "")

	# Overwriting an existing pair is not growth, so it still lands.
	assert_eq(LinkWeightsStore.set_weight(VAULT, "note-0000.md", "other-0000.md", 9), "")


# ── Renaming ───────────────────────────────────────────────────────────

func test_rekey_moves_both_endpoints_of_a_renamed_note():
	LinkWeightsStore.set_weight(VAULT, "old.md", "other.md", 5)
	LinkWeightsStore.set_weight(VAULT, "other.md", "old.md", 7)
	LinkWeightsStore.set_weight(VAULT, "old.md", "old.md", 9)
	LinkWeightsStore.set_weight(VAULT, "keep.md", "other.md", 3)

	assert_true(LinkWeightsStore.rekey_note(VAULT, "old.md", "new/dir.md"))

	assert_eq(LinkWeightsStore.weight_of(VAULT, "new/dir.md", "other.md"), 5,
		"a declaration authored on the renamed note follows it")
	assert_eq(LinkWeightsStore.weight_of(VAULT, "other.md", "new/dir.md"), 7,
		"a declaration pointing at the renamed note follows it")
	assert_eq(LinkWeightsStore.weight_of(VAULT, "new/dir.md", "new/dir.md"), 9,
		"a self-declaration moves with the note")
	assert_eq(LinkWeightsStore.weight_of(VAULT, "keep.md", "other.md"), 3,
		"unrelated declarations are untouched")
	assert_eq(LinkWeightsStore.weight_of(VAULT, "old.md", "other.md"), 0)
	assert_eq(LinkWeightsStore.weight_of(VAULT, "other.md", "old.md"), 0)


## A rename requires the destination note to be absent, so anything already
## stored under that path is stale (a note that used the name earlier). The
## moved declaration is the live one and wins the shared targets.
func test_rekey_merges_a_stale_destination_row_with_the_moved_value_winning():
	LinkWeightsStore.set_weight(VAULT, "new.md", "x.md", 4)
	LinkWeightsStore.set_weight(VAULT, "old.md", "x.md", 60)
	LinkWeightsStore.set_weight(VAULT, "old.md", "new.md", 70)

	assert_true(LinkWeightsStore.rekey_note(VAULT, "old.md", "new.md"))

	assert_eq(LinkWeightsStore.weight_of(VAULT, "new.md", "x.md"), 60)
	assert_eq(LinkWeightsStore.weight_of(VAULT, "new.md", "new.md"), 70,
		"the old target spelling is moved as well")


func test_rekey_with_nothing_to_move_is_a_no_op():
	LinkWeightsStore.set_weight(VAULT, "a.md", "b.md", 5)
	var before = MockAutoloads.get_store(LinkWeightsStore.WEIGHTS_FILE)

	assert_false(LinkWeightsStore.rekey_note(VAULT, "old.md", "new.md"))
	assert_false(LinkWeightsStore.rekey_note(VAULT, "a.md", "a.md"),
		"an unchanged name is not a move")
	assert_false(LinkWeightsStore.rekey_note(VAULT, "../old.md", "new.md"),
		"a path the walk could not produce is refused")
	assert_false(LinkWeightsStore.rekey_note("relative/vault", "a.md", "b.md"))
	assert_eq(MockAutoloads.get_store(LinkWeightsStore.WEIGHTS_FILE), before)
	assert_eq(LinkWeightsStore.weight_of(VAULT, "a.md", "b.md"), 5)


func test_rekey_touches_one_vault_only():
	LinkWeightsStore.set_weight(VAULT, "old.md", "a.md", 5)
	LinkWeightsStore.set_weight("/other", "old.md", "a.md", 8)

	assert_true(LinkWeightsStore.rekey_note(VAULT, "old.md", "new.md"))

	assert_eq(LinkWeightsStore.weight_of(VAULT, "new.md", "a.md"), 5)
	assert_eq(LinkWeightsStore.weight_of("/other", "old.md", "a.md"), 8,
		"another vault's declarations are not this rename's business")


# ── Pruning ────────────────────────────────────────────────────────────

func test_prune_removes_only_entries_whose_endpoint_vanished():
	LinkWeightsStore.set_weight(VAULT, "a.md", "b.md", 5)
	LinkWeightsStore.set_weight(VAULT, "a.md", "gone.md", 5)
	LinkWeightsStore.set_weight(VAULT, "gone.md", "b.md", 5)
	assert_true(LinkWeightsStore.prune(VAULT, {"a.md": true, "b.md": true}))
	assert_eq(LinkWeightsStore.weight_of(VAULT, "a.md", "b.md"), 5)
	assert_eq(LinkWeightsStore.weight_of(VAULT, "a.md", "gone.md"), 0)
	assert_eq(LinkWeightsStore.weight_of(VAULT, "gone.md", "b.md"), 0)
	assert_false(LinkWeightsStore.prune(VAULT, {"a.md": true, "b.md": true}),
		"nothing to prune is not a write")
	# An empty known set removes everything (the vault has no notes).
	LinkWeightsStore.set_weight(VAULT, "x.md", "y.md", 5)
	assert_true(LinkWeightsStore.prune(VAULT, {}))
	assert_eq(LinkWeightsStore.vault_weights(VAULT), {})


func test_the_store_caps_the_vault_count():
	var vaults := {}
	for i in LinkWeights.MAX_VAULTS:
		vaults["/vault-%02d" % i] = {"a.md": {"b.md": 5}}
	MockAutoloads.set_store(LinkWeightsStore.WEIGHTS_FILE, {"vaults": vaults})
	LinkWeightsStore.reload()
	assert_ne(LinkWeightsStore.set_weight("/one-too-many", "a.md", "b.md", 5), "",
		"a new vault past the cap is refused")
	# An existing vault still accepts writes.
	assert_eq(LinkWeightsStore.set_weight("/vault-00", "a.md", "c.md", 5), "")


func test_a_full_vault_refuses_the_whole_pair():
	var big := {}
	for i in LinkWeights.MAX_ENTRIES - 1:
		big["note-%04d.md" % i] = {"other-%04d.md" % i: 5}
	MockAutoloads.set_store(LinkWeightsStore.WEIGHTS_FILE, {"vaults": {VAULT: big}})
	LinkWeightsStore.reload()
	assert_ne(LinkWeightsStore.set_pair(VAULT, "x.md", "y.md", 5), "",
		"two new directions do not fit in one slot")
	assert_eq(LinkWeightsStore.weight_of(VAULT, "x.md", "y.md"), 0,
		"a refused pair writes neither direction")
	assert_eq(LinkWeightsStore.weight_of(VAULT, "y.md", "x.md"), 0)


# ── The agent verb (`vaultWeight`) ─────────────────────────────────────

func test_the_ipc_verb_sets_and_clears_one_directed_pair():
	var answer: Dictionary = WorkspaceIpcHandlers.handle(null, "vaultWeight", {
		"vault_path": _ipc_vault,
		"src": "a.md",
		"target": "b.md",
		"weight": "40",
	})
	assert_eq(int(answer.get("weight", 0)), 40, "a numeric string is accepted")
	assert_eq(LinkWeightsStore.weight_of(_ipc_vault, "a.md", "b.md"), 40)
	assert_eq(LinkWeightsStore.weight_of(_ipc_vault, "b.md", "a.md"), 0,
		"the agent writes one directed pair; only the canvas writes both")

	var cleared: Dictionary = WorkspaceIpcHandlers.handle(null, "vaultWeight", {
		"vault_path": _ipc_vault,
		"src": "a.md",
		"target": "b.md",
		"weight": null,
	})
	assert_eq(int(cleared.get("weight", -1)), 0)
	assert_eq(LinkWeightsStore.weight_of(_ipc_vault, "a.md", "b.md"), 0)


func test_the_ipc_verb_refuses_bad_params_before_writing():
	var cases := [
		{"vault_path": "relative", "src": "a.md", "target": "b.md", "weight": 5},
		{"vault_path": "/does/not/exist", "src": "a.md", "target": "b.md", "weight": 5},
		{"vault_path": _ipc_vault, "src": "../a.md", "target": "b.md", "weight": 5},
		{"vault_path": _ipc_vault, "src": "a.md", "target": "b.txt", "weight": 5},
		{"vault_path": _ipc_vault, "src": "a.md", "target": "b.md", "weight": 0},
		{"vault_path": _ipc_vault, "src": "a.md", "target": "b.md",
			"weight": LinkWeights.MAX_WEIGHT + 1},
		{"vault_path": _ipc_vault, "src": "a.md", "target": "b.md", "weight": "heavy"},
	]
	for params in cases:
		var answer: Dictionary = WorkspaceIpcHandlers.handle(null, "vaultWeight", params)
		var problem: Variant = answer.get("error")
		assert_true(problem is Dictionary, "a bad request must answer an error: %s" % params)
		if problem is Dictionary:
			assert_eq(int(problem.get("code", 0)), -32602,
				"a malformed request is INVALID_PARAMS: %s" % params)
	assert_eq(LinkWeightsStore.vault_weights(_ipc_vault), {},
		"nothing invalid reached the store")
