extends GutTest
# Unit/integration tests for the bundled knowledge base: path containment,
# bundle shape, version handling, and the real seed + index path.

const Store = preload("res://scenes/autoloads/knowledge_store.gd")

func after_each():
	KnowledgeStore.store_root = KnowledgeStore.STORE_ROOT
	KnowledgeStore.bundle_path = KnowledgeStore.BUNDLE_FILE
	KnowledgeStore.reset()

func test_note_paths_stay_inside_the_vault():
	assert_eq(Store.note_path_problem("index.md"), "")
	assert_eq(Store.note_path_problem("foundations/pty.md"), "")
	for bad in [
		"",
		"../escape.md",
		"/absolute.md",
		".hidden.md",
		"notes/.hidden.md",
		"notes//note.md",
		"notes/note.txt",
		"c:/note.md",
		"notes\\note.md",
	]:
		assert_ne(Store.note_path_problem(bad), "", "%s must be refused" % bad)

func test_bundle_parser_rejects_malformed_notes():
	var good := JSON.stringify({
		"version": "0123456789abcdef",
		"notes": [{"path": "a.md", "text": "# A"}],
	})
	var parsed := Store.parse_bundle(good)
	assert_false(parsed.has("error"), str(parsed.get("error", "")))
	assert_eq((parsed.get("notes", []) as Array).size(), 1)

	assert_true(Store.parse_bundle("{").has("error"), "invalid JSON is refused")
	assert_true(Store.parse_bundle(JSON.stringify({"notes": []})).has("error"),
		"an empty bundle is refused")
	assert_true(Store.parse_bundle(JSON.stringify({
		"notes": [{"path": "../a.md", "text": "x"}],
	})).has("error"), "a parent path is refused")
	assert_true(Store.parse_bundle(JSON.stringify({
		"notes": [{"path": "a.md"}],
	})).has("error"), "a note without text is refused")
	assert_true(Store.parse_bundle(JSON.stringify({
		"notes": [{"path": "a.md", "text": "x"}, {"path": "A.md", "text": "y"}],
	})).has("error"), "case-insensitive duplicate paths are refused")

func test_unusable_version_is_hashed_not_used():
	var parsed := Store.parse_bundle(JSON.stringify({
		"version": "../../evil",
		"notes": [{"path": "a.md", "text": "x"}],
	}))
	assert_false(parsed.has("error"))
	assert_eq(str(parsed["version"]).length(), 16,
		"an invalid version becomes a content hash, never a path")

func test_the_shipped_bundle_seeds_and_indexes_without_ghosts():
	# The bundle is the release copy; this is the same index/graph path the
	# Wiki pane uses, exercised against a temporary store root.
	KnowledgeStore.store_root = TestPaths.user_path("knowledge_seed")
	KnowledgeStore.reset()
	var path := KnowledgeStore.resolve(KnowledgeStore.TOKEN)
	assert_ne(path, "", KnowledgeStore.last_error())
	assert_true(path.is_absolute_path(), "the seeded vault is an absolute path")
	assert_true(DirAccess.dir_exists_absolute(path), "the seed directory exists")

	var bundle = JSON.parse_string(FileAccess.get_file_as_string(KnowledgeStore.BUNDLE_FILE))
	assert_true(bundle is Dictionary, "the shipped bundle is valid JSON")
	var expected: int = (bundle.get("notes", []) as Array).size()
	assert_gt(expected, 0, "the shipped bundle carries notes")

	var index = JSON.parse_string(str(GptyTerminal.vault_index(path)))
	assert_true(index is Dictionary and not index.has("error"), "the seeded vault indexes")
	assert_eq((index.get("notes", []) as Array).size(), expected,
		"the index sees every bundled note")

	var graph = JSON.parse_string(str(GptyTerminal.vault_graph(path)))
	assert_true(graph is Dictionary and not graph.has("error"), "the seeded vault draws")
	var ghosts := 0
	for node in graph.get("nodes", []):
		if node is Dictionary and bool(node.get("ghost", false)):
			ghosts += 1
	assert_eq(ghosts, 0, "the bundled vault has no unresolved links")
