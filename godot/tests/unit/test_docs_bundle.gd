extends GutTest
# DocsBundle — the shipped `res://docs.json` the Settings > About tab reads.
# The bundle is generated (`scripts/build-docs`) and read-only, but it becomes
# label text, so its shape, path vocabulary and caps are validated before a
# single document is served.

const FIXTURE := "docs_bundle_fixture.json"

func before_each():
	DocsBundle.bundle_path = DocsBundle.BUNDLE_FILE
	DocsBundle.reset()

func after_each():
	DocsBundle.reset()
	DocsBundle.bundle_path = DocsBundle.BUNDLE_FILE
	var fixture := TestPaths.user_path(FIXTURE)
	if FileAccess.file_exists(fixture):
		DirAccess.remove_absolute(fixture)

func _entry(path: String, text := "body") -> Dictionary:
	return {"path": path, "text": text}

func _bundle(docs: Array) -> String:
	return JSON.stringify({"version": "0123456789abcdef", "docs": docs})

func test_a_valid_bundle_parses_into_keyed_documents():
	var parsed := DocsBundle.parse_bundle(_bundle([
		_entry("README.md", "# gPTY"),
		_entry("docs/content/docs/agents/security.md"),
	]))
	assert_false(parsed.has("error"), str(parsed.get("error", "")))
	var docs: Dictionary = parsed["docs"]
	assert_eq(docs.size(), 2)
	assert_eq(str(docs["README.md"]["text"]), "# gPTY")
	assert_true(docs.has("docs/content/docs/agents/security.md"))

func test_invalid_json_is_refused():
	assert_true(DocsBundle.parse_bundle("{").has("error"))

func test_a_bundle_without_documents_is_refused():
	assert_true(DocsBundle.parse_bundle(JSON.stringify({"docs": []})).has("error"))
	assert_true(DocsBundle.parse_bundle(JSON.stringify({"version": "0123456789abcdef"})).has("error"))

func test_a_path_that_is_not_a_markdown_document_is_refused():
	for bad in ["notes.txt", "docs/", "", "/README.md", "docs\\README.md",
			"docs//README.md", "docs/../README.md", "docs/.hidden.md"]:
		var parsed := DocsBundle.parse_bundle(_bundle([_entry(bad)]))
		assert_true(parsed.has("error"), "%s must be refused" % bad)

func test_two_paths_that_differ_only_by_case_are_refused():
	var parsed := DocsBundle.parse_bundle(_bundle([
		_entry("README.md"), _entry("readme.md"),
	]))
	assert_true(parsed.has("error"),
		"a case-insensitive filesystem would resolve the two to one file")

func test_a_document_without_text_is_refused():
	var parsed := DocsBundle.parse_bundle(JSON.stringify({
		"docs": [{"path": "README.md"}],
	}))
	assert_true(parsed.has("error"))

func test_a_document_past_the_cap_is_refused():
	var body := "a".repeat(DocsBundle.MAX_DOC_BYTES + 1)
	assert_true(DocsBundle.parse_bundle(_bundle([_entry("README.md", body)])).has("error"))

func test_a_missing_bundle_answers_a_sentence_and_nothing_else():
	DocsBundle.bundle_path = TestPaths.user_path("no-such-docs-bundle.json")
	var why := DocsBundle.ensure()
	assert_ne(why, "")
	assert_string_contains(why, "missing")
	assert_false(DocsBundle.has("README.md"))
	assert_eq(DocsBundle.text("README.md"), "")
	assert_eq(DocsBundle.paths().size(), 0)

func test_a_fixture_bundle_loads_and_reset_reloads_it():
	var fixture := TestPaths.user_path(FIXTURE)
	var file := FileAccess.open(fixture, FileAccess.WRITE)
	assert_not_null(file, "the fixture is writable under the run's user dir")
	file.store_string(_bundle([_entry("README.md", "hello")]))
	file.close()
	DocsBundle.bundle_path = fixture
	assert_eq(DocsBundle.ensure(), "")
	assert_true(DocsBundle.has("README.md"))
	assert_eq(DocsBundle.text("README.md"), "hello")
	assert_eq(DocsBundle.paths(), PackedStringArray(["README.md"]))
	# A second ensure is a cache hit; reset() makes the next one read the file.
	DocsBundle.reset()
	assert_eq(DocsBundle.ensure(), "")
	assert_eq(DocsBundle.text("README.md"), "hello")

func test_a_malformed_fixture_reports_the_validation_sentence():
	var fixture := TestPaths.user_path(FIXTURE)
	var file := FileAccess.open(fixture, FileAccess.WRITE)
	assert_not_null(file)
	file.store_string(_bundle([_entry("not-a-note.txt")]))
	file.close()
	DocsBundle.bundle_path = fixture
	var why := DocsBundle.ensure()
	assert_ne(why, "")
	assert_string_contains(why, "Markdown")

func test_the_shipped_bundle_carries_the_readme_and_its_links():
	# The real `res://docs.json` is the artefact this class exists for: the
	# README plus the documents it links, with internal links already in the
	# bundle's own scheme.
	assert_eq(DocsBundle.ensure(), "")
	assert_true(DocsBundle.has(DocsBundle.ROOT_DOC), "the About tab's home page ships")
	var readme := DocsBundle.text(DocsBundle.ROOT_DOC)
	assert_false(readme.contains("<div align=\"center\">"),
		"the generator drops the badge header")
	assert_string_contains(readme, "gpty-doc:", "internal links are rewritten")
	for path in ["SECURITY.md", "ROADMAP.md", "CONTRIBUTING.md"]:
		assert_true(DocsBundle.has(path), "%s is bundled" % path)
