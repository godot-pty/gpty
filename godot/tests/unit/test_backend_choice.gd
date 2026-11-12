extends GutTest
# BackendChoice — the Inspector's backend vocabulary.
# Defends: the dropdown matches every alias the Rust parser accepts
# (`oh-my-pi`/`pi` -> `omp`), a value the list does not know is kept rather
# than reset, and a missing program is announced without losing its row.

func _roster() -> Array:
	return [
		{"kind": "mock", "name": "Mock", "available": true},
		{"kind": "omp", "name": "Oh-My-Pi (omp RPC)", "available": false},
		{"kind": "cli", "name": "CLI bridge (NDJSON)", "available": true},
	]

# ── The vocabulary mirrors BackendKind::parse ──────────────────────────

func test_aliases_normalize_to_the_rust_parsers_kinds():
	assert_eq(BackendChoice.normalize("mock"), "mock")
	assert_eq(BackendChoice.normalize(" OMP "), "omp", "trimmed and case-folded")
	assert_eq(BackendChoice.normalize("oh-my-pi"), "omp")
	assert_eq(BackendChoice.normalize("Pi"), "omp")
	assert_eq(BackendChoice.normalize("cli"), "cli")
	assert_eq(BackendChoice.normalize("gpt-5"), "", "an unknown name has no kind")

func test_selected_kind_defaults_an_empty_value_to_omp():
	assert_eq(BackendChoice.selected_kind(""), "omp", "an empty value means the pane default")
	assert_eq(BackendChoice.selected_kind("pi"), "omp")
	assert_eq(BackendChoice.selected_kind("gpt-5"), "gpt-5", "an unknown value stays itself")

func test_a_roster_that_is_not_a_json_array_is_empty():
	assert_eq(BackendChoice.roster(""), [])
	assert_eq(BackendChoice.roster("{}"), [])
	assert_eq(BackendChoice.roster("[{\"kind\":\"mock\"}]").size(), 1)

# ── Dropdown rows ──────────────────────────────────────────────────────

func test_options_mark_a_missing_program_and_keep_its_row():
	var rows := BackendChoice.options(_roster(), "omp")
	assert_eq(rows.size(), 3, "an unavailable program keeps its row")
	assert_eq(rows[1]["kind"], "omp")
	assert_eq(rows[1]["label"], "Oh-My-Pi (omp RPC) (not found)")
	assert_eq(rows[1]["hint"], BackendChoice.OMP_HINT)
	assert_string_contains(BackendChoice.OMP_HINT, "GPTY_OMP")
	assert_eq(rows[0]["hint"], "", "an available backend needs no hint")

func test_an_unknown_value_becomes_a_custom_row():
	var rows := BackendChoice.options(_roster(), "gpt-5")
	assert_eq(rows.size(), 4)
	assert_eq(rows[3]["kind"], "gpt-5")
	assert_eq(rows[3]["label"], "Custom: gpt-5")
	assert_eq(rows[3]["hint"], BackendChoice.CUSTOM_HINT)
	assert_eq(BackendChoice.selected_kind("gpt-5"), rows[3]["kind"],
		"the dropdown selects the row the pane's own value names")

func test_a_missing_roster_keeps_the_current_kind():
	var rows := BackendChoice.options([], "pi")
	assert_eq(rows.size(), 1)
	assert_eq(rows[0]["kind"], "omp", "the alias still matches its kind")
	assert_eq(rows[0]["hint"], BackendChoice.NO_ROSTER_HINT)

func test_duplicate_and_unknown_roster_entries_are_dropped():
	var rows := BackendChoice.options([
		{"kind": "omp", "name": "One", "available": true},
		{"kind": "pi", "name": "Two", "available": false},
		{"kind": "mystery", "name": "Three", "available": true},
		"not a dictionary",
	], "omp")
	assert_eq(rows.size(), 1, "one row per kind, and only known kinds")
	assert_eq(rows[0]["label"], "One", "the first entry for a kind wins")
