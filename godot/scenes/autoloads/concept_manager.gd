extends BasePersistenceManager

const CONCEPTS_FILE = "user://concepts.json"
const DEFAULTS_FILE = "res://concepts.default.json"

# Extra regex predicates a concept may carry, ANDed with its trigger on the
# same line. The engine enforces the same cap; the editor caps here so the
# lines it shows are the lines that actually run.
const MAX_CONDITIONS := 8

# Layout block written by the visual concept editor. It holds the canvas's own
# state — positions, unfinished drafts, and the order rules are tried in — and
# never content: the concepts array stays the single content store, so nothing
# in the graph can invent a trigger, an action or an enable flag.
const GRAPH_VERSION := 1
const MAX_GRAPH_POSITIONS := 512
const MAX_GRAPH_COORD := 100000.0
const MAX_DRAFT_CHAINS := 32
const MAX_DRAFT_NODES := 256
const MAX_GRAPH_STRING := 1024
const MAX_GRAPH_ID := 96
## Entries in the canvas order, and the longest rule name one may carry
## (mirrors `ConceptGraphModel.MAX_NAME_LEN`, which bounds names on write).
const MAX_GRAPH_ORDER := 256
const MAX_GRAPH_ORDER_NAME := 256
const DRAFT_KINDS := ["trigger", "condition", "action"]

signal concepts_changed

func _on_init():
	# Defer push — GDExtension may not be registered yet during autoload init
	call_deferred("_push_to_rust")

func _push_to_rust():
	var concepts = _merge_concepts()
	# Filter out disabled concepts before pushing to Rust. An empty set is
	# pushed as `[]` rather than skipped: returning early would leave the
	# engine running whatever was pushed last, so disabling every concept
	# would not actually stop the captures the user just turned off.
	var enabled_only: Array = []
	for c in concepts:
		if c is Dictionary and c.get("enabled", true) == true:
			enabled_only.append(c)
	var t = ClassDB.instantiate("GptyTerminal")
	if t == null:
		push_warning("[ConceptManager] Failed to instantiate GptyTerminal, concepts not pushed")
		return
	t.set_global_concepts(JSON.stringify(enabled_only))

func _merge_concepts() -> Array:
	var defaults = _load_defaults()
	var user = _load_from_file()
	# Build a name→index map for user concepts
	var user_map := {}
	for i in user.size():
		var c = user[i]
		if c is Dictionary:
			user_map[c.get("name", "")] = i
	# Deep-merge: start with default fields, overlay user fields
	var merged: Array = []
	for d in defaults:
		if not (d is Dictionary):
			continue
		var name = d.get("name", "")
		if name in user_map:
			# Start from default, then overlay every user key
			var entry: Dictionary = d.duplicate(true)
			var u = user[user_map[name]]
			if u is Dictionary:
				for key in u.keys():
					entry[key] = u[key]
			# Migrate old default triggers to the new patterns
			_migrate_trigger(entry, d)
			merged.append(entry)
		else:
			merged.append(d)
	# Append user-only concepts (not in defaults)
	for i in user.size():
		var c = user[i]
		if not (c is Dictionary):
			continue
		# Already merged above — skip
		if c.get("name", "") in _default_names(defaults):
			continue
		merged.append(c)
	# Rewrite legacy observer targets — its active role is now Inspector.
	for entry in merged:
		if entry is Dictionary:
			_migrate_actions_target(entry)
	# The canvas order wins where it speaks: rules it names come first, in that
	# order, and everything else keeps the merge order behind them. This is the
	# precedence the engine runs (first match wins within a capture/notify
	# class), so the visual editor's rows are the order rules are tried in.
	return _apply_canvas_order(merged, get_graph_state())

## Sort the merged concepts by the order the visual editor saved.
##
## A rule the canvas does not name keeps its merged position (shipped defaults
## first, then user entries in file order) and is tried *after* the arranged
## ones: a newly shipped default must never quietly take precedence over an
## arrangement the user made — it appears on the canvas unranked the next time
## the editor opens. A store with no `order` key is untouched, so a user who
## never opened the editor gets exactly the order that shipped.
func _apply_canvas_order(concepts: Array, graph: Dictionary) -> Array:
	var raw = graph.get("order", [])
	if not (raw is Array) or raw.is_empty():
		return concepts
	var rank := {}
	for name in raw:
		if name is String and name != "" and not rank.has(name):
			rank[name] = rank.size()
	if rank.is_empty():
		return concepts
	var keyed: Array = []
	for i in concepts.size():
		var entry = concepts[i]
		var name := str(entry.get("name", "")) if entry is Dictionary else ""
		# Unlisted entries sort after every listed one, in merged order.
		var key := rank.size() + i
		if name != "" and rank.has(name):
			key = int(rank[name])
		keyed.append([key, entry])
	keyed.sort_custom(func(a, b): return a[0] < b[0])
	var sorted: Array = []
	for pair in keyed:
		sorted.append(pair[1])
	return sorted

func _default_names(defaults: Array) -> Dictionary:
	var names := {}
	for d in defaults:
		if d is Dictionary:
			names[d.get("name", "")] = true
	return names

func _load_defaults() -> Array:
	if not FileAccess.file_exists(DEFAULTS_FILE):
		return []
	var f = FileAccess.open(DEFAULTS_FILE, FileAccess.READ)
	if not f:
		return []
	var text = f.get_as_text()
	var json = JSON.new()
	var err = json.parse(text)
	if err != OK:
		return []
	var data = json.get_data()
	if not (data is Dictionary):
		return []
	var raw = data.get("concepts", [])
	if not (raw is Array):
		return []
	var result: Array = []
	for item in raw:
		if item is Dictionary:
			result.append(item)
	return result

func _load_from_file() -> Array:
	var d = _read_file(CONCEPTS_FILE)
	if d.is_empty():
		return []
	var raw = d.get("concepts", [])
	if not (raw is Array):
		return []
	return raw

## Return merged concepts with enabled status for IPC/MCP.
func get_concepts() -> Array:
	return _merge_concepts()

## Toggle a concept's enabled flag in the user overrides file.
func toggle_concept(name: String) -> bool:
	# Find the current enabled state from merged concepts
	var merged = _merge_concepts()
	var current_enabled = true
	for c in merged:
		if c is Dictionary and c.get("name", "") == name:
			current_enabled = c.get("enabled", true)
			break
	var new_enabled = not current_enabled
	var user = _load_from_file()
	var found = false
	for c in user:
		if c is Dictionary and c.get("name", "") == name:
			c["enabled"] = new_enabled
			found = true
			break
	if not found:
		var entry: Dictionary = {"name": name, "enabled": new_enabled}
		user.append(entry)
	save_concepts(user)
	return true


func save_concepts(concepts: Array):
	# Delegates so a manual edit rewrites the concepts array without dropping
	# the editor's layout: saving is a read-modify-write of the same file.
	save_state(concepts, get_graph_state())

## Replace the concept set and the editor's graph block in one write. Both
## halves are sanitized here, so an edit dialog and the visual editor can
## never disagree about what the file holds.
func save_state(concepts: Array, graph: Dictionary):
	var sanitized := _sanitize_concepts(concepts)
	var clean_graph := _sanitize_graph(graph)
	var d := {"concepts": sanitized}
	# A graph block with no positions, drafts or order carries nothing.
	# Omitting it keeps concepts.json clean for the users who never open the
	# editor and never hand-edited a key that only the editor writes.
	var positions: Dictionary = clean_graph["positions"]
	var drafts: Array = clean_graph["drafts"]
	var order: Array = clean_graph["order"]
	if not positions.is_empty() or not drafts.is_empty() or not order.is_empty():
		d["graph"] = clean_graph
	_write_file(CONCEPTS_FILE, d)
	concepts_changed.emit()
	call_deferred("_push_to_rust")

## The editor's layout block as stored on disk. Always well-formed: a missing,
## malformed or hand-edited block reads back as version 1 with no content.
func get_graph_state() -> Dictionary:
	return _sanitize_graph(_read_file(CONCEPTS_FILE).get("graph", {}))

## Deep-copy the entries that survive, dropping legacy command templates and
## writing back disabled legacy routing targets.
func _sanitize_concepts(concepts: Array) -> Array:
	var sanitized: Array = []
	for entry in concepts:
		if entry is Dictionary:
			var copy: Dictionary = entry.duplicate(true)
			_strip_legacy_commands(copy)
			_migrate_actions_target(copy)
			sanitized.append(copy)
	return sanitized

## The graph block is untrusted file input: nothing read from it is trusted to
## have the right shape, and nothing written to it comes from anywhere else.
func _sanitize_graph(raw) -> Dictionary:
	var out := {"version": GRAPH_VERSION, "positions": {}, "drafts": [], "order": []}
	if not (raw is Dictionary):
		return out
	# `version` is ours to write: a file claiming another version is ignored
	# rather than honoured, so an old file cannot change how we parse it.
	out["positions"] = _sanitize_positions(raw.get("positions", {}))
	out["drafts"] = _sanitize_drafts(raw.get("drafts", []))
	out["order"] = _sanitize_order(raw.get("order", []))
	return out

## The rule order the canvas arranged. Names only, deduplicated (the first
## occurrence is the rank), bounded in both count and length: this list is how
## the file asks for a precedence other than the merge order, so a hand-edited
## block must not be able to make it unbounded.
func _sanitize_order(raw) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	for entry in raw:
		if out.size() >= MAX_GRAPH_ORDER:
			break
		if not (entry is String):
			continue
		var name: String = entry
		if name == "" or name.length() > MAX_GRAPH_ORDER_NAME or out.has(name):
			continue
		out.append(name)
	return out

func _sanitize_positions(raw) -> Dictionary:
	var out := {}
	if not (raw is Dictionary):
		return out
	for key in raw.keys():
		if out.size() >= MAX_GRAPH_POSITIONS:
			break
		if not (key is String):
			continue
		var node_id: String = key
		if node_id == "" or node_id.length() > MAX_GRAPH_ID:
			continue
		var v = raw[key]
		if not (v is Array) or v.size() != 2:
			continue
		var x := _sanitize_coord(v[0])
		var y := _sanitize_coord(v[1])
		if is_nan(x) or is_nan(y):
			continue
		var pos: Array = [x, y]
		out[node_id] = pos
	return out

## A coordinate is a finite number inside the sane pan range. Booleans are
## rejected even though GDScript counts them as numbers: `true` from a
## hand-edited file must not become 1.0.
func _sanitize_coord(v) -> float:
	if v is bool:
		return NAN
	if not (v is int or v is float):
		return NAN
	var f := float(v)
	if not is_finite(f) or absf(f) > MAX_GRAPH_COORD:
		return NAN
	return f

func _sanitize_drafts(raw) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	var total_nodes := 0
	for entry in raw:
		if out.size() >= MAX_DRAFT_CHAINS or total_nodes >= MAX_DRAFT_NODES:
			break
		if not (entry is Dictionary):
			continue
		var nodes: Array = []
		var raw_nodes = entry.get("nodes", [])
		if raw_nodes is Array:
			for n in raw_nodes:
				if total_nodes >= MAX_DRAFT_NODES:
					break
				var node := _sanitize_draft_node(n)
				if node.is_empty():
					continue
				nodes.append(node)
				total_nodes += 1
		var edges := _sanitize_draft_edges(entry.get("edges", []))
		# A chain with no nodes and no edges carries nothing; keeping it would
		# let an empty dictionary in a hand-edited file survive as a draft.
		if nodes.is_empty() and edges.is_empty():
			continue
		out.append({"nodes": nodes, "edges": edges})
	return out

func _sanitize_draft_node(raw) -> Dictionary:
	if not (raw is Dictionary):
		return {}
	var raw_id = raw.get("id", "")
	if not (raw_id is String):
		return {}
	var id: String = raw_id
	# An edge can only name a node by id, so a nameless node is unusable.
	if id == "" or id.length() > MAX_GRAPH_ID:
		return {}
	var raw_kind = raw.get("kind", "")
	if not (raw_kind is String) or not (raw_kind in DRAFT_KINDS):
		return {}
	var kind: String = raw_kind
	return {"id": id, "kind": kind, "params": _sanitize_draft_params(kind, raw.get("params", {}))}

func _sanitize_draft_edges(raw) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	for edge in raw:
		if not (edge is Array) or edge.size() != 2:
			continue
		var from = edge[0]
		var to = edge[1]
		if not (from is String) or not (to is String):
			continue
		var a: String = from
		var b: String = to
		if a == "" or b == "" or a.length() > MAX_GRAPH_ID or b.length() > MAX_GRAPH_ID:
			continue
		out.append([a, b])
	return out

## Draft nodes carry the same closed key set as the concepts they compile
## into — per kind, with the same types and caps the engine applies. Unknown
## keys are never copied: a draft node is unfinished work, not a place to
## smuggle a field into the compiled concept.
func _sanitize_draft_params(kind: String, params) -> Dictionary:
	var out := {}
	if not (params is Dictionary):
		return out
	match kind:
		"trigger":
			_copy_graph_string(params, out, "name", 256)
			_copy_graph_string(params, out, "trigger", MAX_GRAPH_STRING)
			_copy_graph_bool(params, out, "enabled")
		"condition":
			_copy_graph_string(params, out, "pattern", MAX_GRAPH_STRING)
		"action":
			_copy_action_mode(params, out)
			_copy_graph_string(params, out, "target", 64)
			_copy_graph_int(params, out, "stop_timeout_ms", 1, 600000)
			_copy_graph_bool(params, out, "stop_on_input")
	return out

func _copy_graph_string(src: Dictionary, dst: Dictionary, key: String, max_len: int) -> void:
	var v = src.get(key)
	if v is String and (v as String).length() <= max_len:
		dst[key] = v

func _copy_graph_bool(src: Dictionary, dst: Dictionary, key: String) -> void:
	var v = src.get(key)
	if v is bool:
		dst[key] = v

func _copy_graph_int(src: Dictionary, dst: Dictionary, key: String, lo: int, hi: int) -> void:
	var v = src.get(key)
	if v is bool or not (v is int):
		return
	dst[key] = clampi(v, lo, hi)

func _copy_action_mode(src: Dictionary, dst: Dictionary) -> void:
	var v = src.get("mode")
	if v is String and (v == "until_stop" or v == "single_line"):
		dst["mode"] = v

## Concepts never carry a command. A `cmd` key can only come from the release
## where a concept action could inject one into a PTY, so it is dropped
## whenever a user file passes through the app and never carried forward.
func _strip_legacy_commands(entry: Dictionary) -> void:
	var actions = entry.get("actions", [])
	if not (actions is Array):
		return
	for action in actions:
		if action is Dictionary:
			action.erase("cmd")

# Migrate old default trigger patterns to the new ones.
const TRIGGER_MIGRATIONS := {
	"cat_command": {"old": ["^cat\\s+", "\\bcat\\s+\\S"], "new": "(?:^|[$#>]\\s)\\bcat\\s+\\S"},
	"git_diff":     {"old": ["^git\\s+diff", "\\bgit\\s+diff"], "new": "(?:^|[$#>]\\s)\\bgit\\s+diff"},
}

func _migrate_trigger(entry: Dictionary, default: Dictionary):
	var name: String = entry.get("name", "")
	if not name in TRIGGER_MIGRATIONS:
		return
	var mig = TRIGGER_MIGRATIONS[name]
	var trigger: String = entry.get("trigger", "")
	var olds: Array = mig["old"] if mig["old"] is Array else [mig["old"]]
	if trigger in olds:
		entry["trigger"] = mig["new"]

# Legacy concepts routed captures to the removed "observer" pane. Inspector
# is private Q&A (not wired to the terminal OMP session). Reasoning never
# accepts captures. Disable legacy observer-target concepts so terminal
# redraws cannot silently start Inspector jobs.
func _migrate_actions_target(entry: Dictionary):
	var actions = entry.get("actions", [])
	if not (actions is Array):
		return
	for action in actions:
		if action is Dictionary and action.get("target", "") == "observer":
			entry["enabled"] = false
