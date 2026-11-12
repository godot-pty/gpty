class_name BackendChoice
## The Inspector's backend vocabulary, in the shape the pane settings dropdown
## needs.
##
## `BackendKind::parse` in `crates/gpty-ai/src/types.rs` is the authority: it
## accepts `mock`, `omp` (and the aliases `oh-my-pi` and `pi`) and `cli`, trimmed
## and case-folded. The pane's `backend` is layout state a profile or workspace
## file can carry, so the dropdown has to match every spelling the parser
## accepts, and a value it does not know must stay visible instead of being
## reset to a default the user did not choose.

const DEFAULT_KIND := "omp"
const OMP_HINT := "Not found — install Oh-My-Pi or set GPTY_OMP."
const UNAVAILABLE_HINT := "Not found — a session cannot open until this program is installed."
const CUSTOM_HINT := "Unknown backend — a session cannot open until this names mock, omp or cli."
const NO_ROSTER_HINT := "Backend list unavailable — rebuild gpty-gdext and restart Godot."

## The canonical kind for a persisted value, or "" when the value is unknown.
static func normalize(value: String) -> String:
	match value.strip_edges().to_lower():
		"mock":
			return "mock"
		"omp", "oh-my-pi", "pi":
			return "omp"
		"cli":
			return "cli"
	return ""

## The value the dropdown matches against and the pane stores: empty means the
## pane default, a known alias means its canonical kind, anything else stays
## itself.
static func selected_kind(value: String) -> String:
	var trimmed := value.strip_edges()
	if trimmed == "":
		return DEFAULT_KIND
	var known := normalize(trimmed)
	return known if known != "" else trimmed

## `GptyAi.list_backends()`'s answer, parsed. Anything that is not a JSON array
## is no roster at all. `JSON.parse` (not `JSON.parse_string`) answers with an
## error code instead of logging an engine error for a stale or empty answer.
static func roster(raw_json: String) -> Array:
	var parser := JSON.new()
	if parser.parse(raw_json) != OK:
		return []
	return parser.data if parser.data is Array else []

## The dropdown rows for `backends` (one `{kind,name,available}` entry per
## backend), with an unknown persisted value appended as its own row.
## Row: `{kind, label, hint}`.
static func options(backends: Array, current: String) -> Array:
	var rows: Array = []
	var listed := {}
	for entry in backends:
		if not (entry is Dictionary):
			continue
		var kind := normalize(str(entry.get("kind", "")))
		if kind == "" or listed.has(kind):
			continue
		listed[kind] = true
		var name := str(entry.get("name", ""))
		if name == "":
			name = kind
		var hint := ""
		if entry.get("available", true) != true:
			# A missing program keeps its row: the persisted choice stays
			# selectable, and the hint is the reason a session will refuse.
			name += " (not found)"
			hint = OMP_HINT if kind == "omp" else UNAVAILABLE_HINT
		rows.append({"kind": kind, "label": name, "hint": hint})

	var wanted := selected_kind(current)
	if rows.is_empty():
		return [{"kind": wanted, "label": wanted, "hint": NO_ROSTER_HINT}]
	for row in rows:
		if row["kind"] == wanted:
			return rows
	rows.append({"kind": wanted, "label": "Custom: %s" % wanted, "hint": CUSTOM_HINT})
	return rows
