class_name ConceptGraphModel
## Pure logic for the Visual Concept Graph.
##
## The graph editor is an authoring front-end: the canvas is a set of rule
## chains (trigger → condition* → action) plus draft nodes that are not part
## of any complete rule. This class turns concepts + stored layout into a
## canvas, validates and compiles the canvas back into the concept vocabulary,
## and serializes the layout. It has no Godot UI and no FFI: [method analyze]
## takes the regex validator as a [Callable] so tests can run headless while
## the editor injects the engine-dialect check
## (`GptyTerminal.validate_regex`).
##
## Guarantees that keep this safe:
## - A compiled entry only ever carries the closed key set below. Node params
##   are read by name, never copied, so a hand-edited graph block cannot
##   smuggle a legacy `cmd` or any other key into `concepts.json`.
## - A malformed condition rejects the whole rule (drop to draft + error).
##   Dropping a condition would WIDEN matching — the dangerous direction.
## - `concepts` stays the single content store: this model never invents
##   content the canvas does not have, and untouched shipped rules write no
##   user entry at all (they keep tracking the shipped defaults).

const GRAPH_VERSION := 1
const MAX_RULES := 128
const MAX_CONDITIONS := 8
const MAX_NAME_LEN := 256
const MAX_PATTERN_LEN := 1024
const MAX_POSITIONS := 512
## Entries in the canvas order. A canvas holds at most [constant MAX_RULES]
## rules; the headroom is for names a rule rename left behind, and it keeps a
## hand-edited block bounded.
const MAX_ORDER := 256
const MAX_COORD := 100000.0
const MAX_DRAFT_CHAINS := 32
const MAX_DRAFT_NODES := 256

const KIND_TRIGGER := "trigger"
const KIND_CONDITION := "condition"
const KIND_ACTION := "action"

const MODE_CAPTURE := "until_stop"
const MODE_NOTIFY := "single_line"

## Canvas node id for a compiled rule's parts, derived from the rule name so
## positions survive reloads. Draft nodes keep whatever id they were stored
## with (`draft:…`); a demoted rule keeps its derived ids.
static func trigger_id(rule_name: String) -> String:
	return rule_name + "#t"

static func condition_id(rule_name: String, index: int) -> String:
	return rule_name + "#c" + str(index)

static func action_id(rule_name: String) -> String:
	return rule_name + "#a"

# ═══════════════════════════════════════════════════════════════════════
# Canvas construction
# ═══════════════════════════════════════════════════════════════════════

## Build the canvas from merged concepts and the sanitized graph block.
##
## Returns `{"nodes": [{id, kind, params}], "edges": [[from_id, to_id]],
## "positions": {id: [x, y]}}`. Nodes are in concept order, so a rule that
## already exists in the user file keeps its precedence position and new
## rules append after it. Shipped rules are materialized too — they are what
## the user sees and can edit; whether an edit is persisted is decided by
## [method analyze]'s default diff, not here.
static func build_canvas(concepts: Array, graph: Dictionary) -> Dictionary:
	var nodes: Array = []
	var edges: Array = []
	var stored: Dictionary = {}
	var raw_positions = graph.get("positions", {})
	if raw_positions is Dictionary:
		stored = raw_positions

	for entry in concepts:
		if not (entry is Dictionary):
			continue
		var name := str(entry.get("name", ""))
		if name == "":
			continue
		var trigger_node := {
			"id": trigger_id(name),
			"kind": KIND_TRIGGER,
			"params": {
				"name": name,
				"trigger": str(entry.get("trigger", "")),
				"enabled": entry.get("enabled", true) == true,
			},
		}
		nodes.append(trigger_node)
		var prev_id: String = trigger_node["id"]
		var conds = entry.get("conditions", [])
		if conds is Array:
			var i := 0
			for c in conds:
				if not (c is String) or c == "":
					continue
				var cid := condition_id(name, i)
				nodes.append({"id": cid, "kind": KIND_CONDITION, "params": {"pattern": c}})
				edges.append([prev_id, cid])
				prev_id = cid
				i += 1
		# `single_line` is notify-only: the action node still exists on the
		# canvas (it owns the mode), but it compiles without a target.
		var mode := MODE_NOTIFY if str(entry.get("capture_mode", "")) == MODE_NOTIFY else MODE_CAPTURE
		var target := ""
		var acts = entry.get("actions", [])
		if acts is Array and acts.size() > 0 and acts[0] is Dictionary:
			target = str(acts[0].get("target", ""))
		var action_node := {
			"id": action_id(name),
			"kind": KIND_ACTION,
			"params": {
				"mode": mode,
				"target": target,
				"stop_timeout_ms": int(_number(entry.get("stop_timeout_ms"), 300.0)),
				"stop_on_input": entry.get("stop_on_input", true) == true,
			},
		}
		nodes.append(action_node)
		edges.append([prev_id, action_node["id"]])

	var raw_drafts = graph.get("drafts", [])
	if raw_drafts is Array:
		for chain in raw_drafts:
			if not (chain is Dictionary):
				continue
			var draft_nodes = chain.get("nodes", [])
			if not (draft_nodes is Array):
				continue
			for dn in draft_nodes:
				if not (dn is Dictionary):
					continue
				var kind := str(dn.get("kind", ""))
				var id := str(dn.get("id", ""))
				if id == "" or not (kind in [KIND_TRIGGER, KIND_CONDITION, KIND_ACTION]):
					continue
				var params = dn.get("params", {})
				nodes.append({
					"id": id,
					"kind": kind,
					"params": params if params is Dictionary else {},
				})
			var draft_edges = chain.get("edges", [])
			if draft_edges is Array:
				for e in draft_edges:
					if e is Array and e.size() == 2:
						edges.append([str(e[0]), str(e[1])])

	return {"nodes": nodes, "edges": edges, "positions": _fill_positions(nodes, stored)}

## Every canvas node gets a position: stored when valid, deterministic
## auto-layout otherwise (chains left-to-right, one row per rule; drafts in
## their own rows below).
static func _fill_positions(nodes: Array, stored: Dictionary) -> Dictionary:
	var out := {}
	var cond_counts := {}
	for node in nodes:
		var id: String = node["id"]
		if id.get_slice("#", 1).begins_with("c"):
			var owner: String = id.get_slice("#", 0)
			cond_counts[owner] = int(cond_counts.get(owner, 0)) + 1
	var row_of := {}
	var next_row := 0
	# Auto rows start below every stored row: a rule the canvas has never
	# arranged (a newly shipped default) must not land on top of one the user
	# placed — it belongs after them, which is where the merge order puts it
	# too, so the canvas and the engine agree about a rule nobody has touched.
	var first_free_y := 40.0
	for id in stored:
		var v = stored[id]
		if v is Array and v.size() == 2 and _is_number(v[1]):
			first_free_y = maxf(first_free_y, float(v[1]) + 240.0)
	for node in nodes:
		var id: String = node["id"]
		var v = stored.get(id)
		if v is Array and v.size() == 2 and _is_number(v[0]) and _is_number(v[1]):
			out[id] = [float(v[0]), float(v[1])]
			continue
		var owner: String = id.get_slice("#", 0)
		var suffix: String = id.get_slice("#", 1)
		# Each rule gets one row; every draft node gets its own row below.
		var row_key := owner if suffix != "" else id
		if not row_of.has(row_key):
			row_of[row_key] = next_row
			next_row += 1
		var y := first_free_y + float(row_of[row_key]) * 240.0
		var x := 40.0
		if suffix == "a":
			x = 400.0 + float(int(cond_counts.get(owner, 0))) * 380.0
		elif suffix.begins_with("c"):
			x = 400.0 + float(suffix.substr(1).to_int()) * 380.0
		out[id] = [x, y]
	return out

## The canvas order: rule names top-to-bottom by their trigger's position (then
## left-to-right, then by name for the same spot). This is the order the rules
## are *tried* in — the editor saves it as the graph block's `order` and
## `ConceptManager` applies it — so the canvas draws priority, not just layout.
##
## A rule with no stored position keeps the order it came in `paths` and sorts
## after every arranged rule: a node the canvas has never shown must not
## displace an arrangement the user made.
static func rule_order(paths: Array, positions: Dictionary) -> Array:
	var keyed: Array = []
	for i in paths.size():
		var path = paths[i]
		if not (path is Dictionary):
			continue
		var name := str(path.get("name", ""))
		if name == "":
			continue
		var ids = path.get("node_ids", {})
		var trigger_id := str(ids.get("trigger", "")) if ids is Dictionary else ""
		var v = positions.get(trigger_id)
		var x := INF
		var y := INF
		# The editor holds canvas positions as Vector2; the file (and every
		# caller coming from it) holds [x, y] arrays.
		if v is Vector2:
			x = v.x
			y = v.y
		elif v is Array and v.size() == 2 and _is_number(v[0]) and _is_number(v[1]):
			x = float(v[0])
			y = float(v[1])
		keyed.append([y, x, i, name])
	keyed.sort_custom(func(a, b):
		if a[0] != b[0]:
			return a[0] < b[0]
		if a[1] != b[1]:
			return a[1] < b[1]
		if a[0] == INF:
			# Both unarranged: keep the order they were compiled in.
			return a[2] < b[2]
		return a[3] < b[3]
	)
	var names: Array = []
	for entry in keyed:
		names.append(entry[3])
	return names

## Tidy positions: one row per rule in precedence order, draft nodes in their
## own rows below. Replaces Godot's own arrangement — which lays a canvas out
## by connection shape and would silently reshuffle the order rules run in.
static func tidy_positions(paths: Array, drafts: Array, positions: Dictionary) -> Dictionary:
	var by_name := {}
	for path in paths:
		if path is Dictionary:
			by_name[str(path.get("name", ""))] = path
	var ordered: Array = []
	for name in rule_order(paths, positions):
		var path: Dictionary = by_name.get(name, {})
		var ids = path.get("node_ids", {})
		if not (ids is Dictionary):
			continue
		var trigger := str(ids.get("trigger", ""))
		if trigger != "":
			ordered.append({"id": trigger})
		var condition_ids = ids.get("conditions", [])
		if condition_ids is Array:
			for id in condition_ids:
				ordered.append({"id": str(id)})
		var action := str(ids.get("action", ""))
		if action != "":
			ordered.append({"id": action})
	for chain in drafts:
		if not (chain is Dictionary):
			continue
		var nodes = chain.get("nodes", [])
		if nodes is Array:
			for node in nodes:
				if node is Dictionary and str(node.get("id", "")) != "":
					ordered.append({"id": str(node["id"])})
	return _fill_positions(ordered, {})

# ═══════════════════════════════════════════════════════════════════════
# Connection validation (used by the GraphEdit gesture handlers)
# ═══════════════════════════════════════════════════════════════════════

## Why `from_id → to_id` is not a legal wire, or "" when it is.
##
## Rules are chains: exactly one trigger, zero or more conditions, one action.
## Ports hold at most one wire, so a chain can never fork or merge; sharing a
## node between rules is deliberately not expressible (the compiled entry's
## identity is the trigger's name).
static func can_connect(nodes: Array, edges: Array, from_id: String, to_id: String) -> String:
	var by_id := _index_nodes(nodes)
	if not by_id.has(from_id) or not by_id.has(to_id):
		return "Unknown node."
	if from_id == to_id:
		return "A node cannot connect to itself."
	var from_kind: String = by_id[from_id]["kind"]
	var to_kind: String = by_id[to_id]["kind"]
	if from_kind == KIND_ACTION:
		return "An action ends a rule — it has no output."
	if to_kind == KIND_TRIGGER:
		return "A trigger starts a rule — it has no input."
	for e in edges:
		if not (e is Array) or e.size() != 2:
			continue
		if e[0] == from_id:
			return "This output is already connected — disconnect it first."
		if e[1] == to_id:
			return "This input is already connected — disconnect it first."
	var out_map := _out_map(edges)
	var seen := {}
	var cursor := to_id
	while cursor != "":
		if cursor == from_id:
			return "That connection would create a cycle."
		if seen.has(cursor):
			break
		seen[cursor] = true
		var outs: Array = out_map.get(cursor, [])
		cursor = outs[0] if outs.size() == 1 else ""
	return ""

# ═══════════════════════════════════════════════════════════════════════
# Analyze + compile
# ═══════════════════════════════════════════════════════════════════════

## Validate the whole canvas and compile it.
##
## Returns
## `{"paths": [valid rules], "drafts": [{nodes, edges}], "concepts": [entries],
## "errors": [{message, ids}]}`.
##
## A rule is valid when its chain is intact, its name is present and unique,
## every pattern (trigger and conditions) passes `validator`, and a capturing
## action names a target. Everything else — broken chains, invalid content,
## orphan drafts — is reported and kept as a draft so no typed text is lost.
## `defaults` are the shipped entries (for the minimal-override diff) and
## `opened_default_names` are the shipped rules that were on the canvas at
## open (their deletion writes a `{name, enabled: false}` tombstone).
static func analyze(
	nodes: Array,
	edges: Array,
	defaults: Array,
	opened_default_names: Array,
	validator: Callable
) -> Dictionary:
	var by_id := _index_nodes(nodes)
	var clean_edges := _live_edges(edges, by_id)
	var out_map := _out_map(clean_edges)
	var in_map := _in_map(clean_edges)
	var errors: Array = []
	var claimed := {}
	var tainted := {}

	# ── structure: per-node port rules ──
	for node in nodes:
		var id: String = node["id"]
		var kind: String = node["kind"]
		var outs: Array = out_map.get(id, [])
		var ins: Array = in_map.get(id, [])
		var taint := func(message: String):
			errors.append(_error(message, [id]))
			tainted[id] = true
		if kind == KIND_TRIGGER and ins.size() > 0:
			taint.call("A trigger cannot have an input.")
		if kind == KIND_ACTION and outs.size() > 0:
			taint.call("An action cannot have an output.")
		if (kind == KIND_TRIGGER or kind == KIND_CONDITION) and outs.size() > 1:
			taint.call("A rule is one chain — disconnect before adding a second path.")
		if (kind == KIND_CONDITION or kind == KIND_ACTION) and ins.size() > 1:
			taint.call("Nodes cannot be shared between rules.")

	# ── walk each trigger chain ──
	var candidates: Array = []
	for node in nodes:
		if node["kind"] != KIND_TRIGGER:
			continue
		var walk := _walk_chain(node["id"], by_id, out_map)
		if not walk["ok"]:
			errors.append(_error(walk["reason"], walk["ids"]))
			continue
		if _any_tainted(walk["ids"], tainted):
			# The port violation was reported above; the chain stays a draft.
			continue
		var path := _path_from_walk(walk, by_id, validator)
		if not path["valid"]:
			errors.append(_error(path["reason"], walk["ids"]))
			continue
		candidates.append(path)

	# Duplicate names make every rule with that name invalid (the name is the
	# merge + toggle key, so duplicates would fight each other in the file).
	var name_counts := {}
	for candidate in candidates:
		var n: String = candidate["name"]
		name_counts[n] = int(name_counts.get(n, 0)) + 1
	var paths: Array = []
	var invalid_paths: Array = []
	for candidate in candidates:
		if int(name_counts[candidate["name"]]) > 1:
			invalid_paths.append(candidate)
			errors.append(_error(
				"Rule name '%s' is used more than once." % candidate["name"],
				candidate["ids"]
			))
		elif paths.size() >= MAX_RULES:
			invalid_paths.append(candidate)
			errors.append(_error(
				"Only %d rules are supported — this one is kept as a draft." % MAX_RULES,
				candidate["ids"]
			))
		else:
			paths.append(candidate)
			for id in candidate["ids"]:
				claimed[id] = true

	# ── leftovers → drafts (grouped by connectivity) ──
	var leftovers: Array = []
	for node in nodes:
		if not claimed.has(node["id"]):
			leftovers.append(node["id"])
	var draft_chains := _group_drafts(leftovers, clean_edges, by_id)

	var compiled := _compile(paths, defaults, opened_default_names)
	for message in compiled["errors"]:
		errors.append(_error(message, []))
	return {
		"paths": paths,
		"drafts": draft_chains,
		"concepts": compiled["concepts"],
		"errors": errors,
	}

static func _path_from_walk(walk: Dictionary, by_id: Dictionary, validator: Callable) -> Dictionary:
	var ids: Array = walk["ids"]
	var trig_params: Dictionary = by_id[ids[0]]["params"]
	var name := str(trig_params.get("name", "")).strip_edges()
	var result := {"valid": false, "reason": "", "ids": ids, "node_ids": {}}
	if name == "":
		result["reason"] = "Rule name is required."
		return result
	if name.length() > MAX_NAME_LEN:
		result["reason"] = "Rule name is longer than %d characters." % MAX_NAME_LEN
		return result
	var trigger := str(trig_params.get("trigger", ""))
	if trigger == "":
		result["reason"] = "Trigger pattern is required."
		return result
	if trigger.length() > MAX_PATTERN_LEN:
		result["reason"] = "Trigger pattern is longer than %d characters." % MAX_PATTERN_LEN
		return result
	var trigger_error := str(validator.call(trigger))
	if trigger_error != "":
		result["reason"] = "Trigger regex: " + trigger_error
		return result

	var condition_ids: Array = []
	var conditions: Array = []
	for i in range(1, ids.size() - 1):
		var cid: String = ids[i]
		var pattern := str(by_id[cid]["params"].get("pattern", ""))
		if pattern == "":
			result["reason"] = "Condition pattern is required."
			return result
		if pattern.length() > MAX_PATTERN_LEN:
			result["reason"] = "Condition pattern is longer than %d characters." % MAX_PATTERN_LEN
			return result
		var condition_error := str(validator.call(pattern))
		if condition_error != "":
			result["reason"] = "Condition regex: " + condition_error
			return result
		condition_ids.append(cid)
		conditions.append(pattern)
	if conditions.size() > MAX_CONDITIONS:
		result["reason"] = "More than %d conditions." % MAX_CONDITIONS
		return result

	var action_params: Dictionary = by_id[ids[ids.size() - 1]]["params"]
	var mode := str(action_params.get("mode", MODE_CAPTURE))
	if not (mode in [MODE_CAPTURE, MODE_NOTIFY]):
		result["reason"] = "Unknown action mode."
		return result
	var target := str(action_params.get("target", "")).strip_edges()
	if mode == MODE_CAPTURE and target == "":
		result["reason"] = "Pick a target pane for the captured output."
		return result

	result["valid"] = true
	result["name"] = name
	result["trigger"] = trigger
	result["enabled"] = trig_params.get("enabled", true) == true
	result["conditions"] = conditions
	result["action"] = {
		"mode": mode,
		"target": target,
		"stop_timeout_ms": int(_number(action_params.get("stop_timeout_ms"), 300.0)),
		"stop_on_input": action_params.get("stop_on_input", true) == true,
	}
	result["node_ids"] = {
		"trigger": ids[0],
		"conditions": condition_ids,
		"action": ids[ids.size() - 1],
	}
	return result

static func _compile(paths: Array, defaults: Array, opened_default_names: Array) -> Dictionary:
	var default_by_name := {}
	for d in defaults:
		if d is Dictionary:
			default_by_name[str(d.get("name", ""))] = d
	var concepts: Array = []
	for path in paths:
		var entry := entry_for_path(path)
		var default = default_by_name.get(path["name"])
		if default is Dictionary and _normalize(entry) == _normalize(default):
			# Untouched shipped rule: writing nothing keeps following updates
			# to the shipped default instead of freezing a copy.
			continue
		concepts.append(entry)
	var live_names := {}
	for path in paths:
		live_names[path["name"]] = true
	for name in opened_default_names:
		var n := str(name)
		if n == "" or not default_by_name.has(n) or live_names.has(n):
			continue
		concepts.append({"name": n, "enabled": false})
	return {"concepts": concepts, "errors": []}

## The concept entry a rule compiles to — the closed key set. Node params are
## read by name here; nothing else can reach the file.
static func entry_for_path(path: Dictionary) -> Dictionary:
	var entry := {
		"name": str(path.get("name", "")),
		"trigger": str(path.get("trigger", "")),
		"enabled": path.get("enabled", true) == true,
	}
	var action: Dictionary = path.get("action", {})
	var mode := str(action.get("mode", MODE_CAPTURE))
	if mode == MODE_NOTIFY:
		entry["capture_mode"] = MODE_NOTIFY
	else:
		entry["capture_mode"] = MODE_CAPTURE
		entry["stop_timeout_ms"] = clampi(int(_number(action.get("stop_timeout_ms"), 300.0)), 1, 600000)
		entry["stop_on_input"] = action.get("stop_on_input", true) == true
		entry["actions"] = [{"target": str(action.get("target", ""))}]
	var conditions = path.get("conditions", [])
	if conditions is Array and conditions.size() > 0:
		entry["conditions"] = conditions.duplicate()
	return entry

## Canonical projection used only for the "does this rule still match its
## shipped default?" comparison. Both sides go through it, so Variant type
## differences (JSON floats vs ints) cannot fake an edit.
static func _normalize(entry: Dictionary) -> Dictionary:
	var conditions: Array = []
	var raw_conditions = entry.get("conditions", [])
	if raw_conditions is Array:
		for c in raw_conditions:
			if c is String:
				conditions.append(c)
	var target := ""
	var raw_actions = entry.get("actions", [])
	if raw_actions is Array and raw_actions.size() > 0 and raw_actions[0] is Dictionary:
		target = str(raw_actions[0].get("target", ""))
	var mode := MODE_NOTIFY if str(entry.get("capture_mode", "")) == MODE_NOTIFY else MODE_CAPTURE
	var out := {
		"name": str(entry.get("name", "")),
		"trigger": str(entry.get("trigger", "")),
		"enabled": entry.get("enabled", true) == true,
		"capture_mode": mode,
		"conditions": conditions,
	}
	if mode == MODE_CAPTURE:
		out["stop_timeout_ms"] = int(_number(entry.get("stop_timeout_ms"), 300.0))
		out["stop_on_input"] = entry.get("stop_on_input", true) == true
		out["target"] = target
	return out

# ═══════════════════════════════════════════════════════════════════════
# Layout serialization
# ═══════════════════════════════════════════════════════════════════════

## Serialize positions, drafts and the rule order for the graph block.
## Positions are re-keyed to the canonical ids of the rules being saved, so a
## rule renamed in the editor keeps its canvas position across reloads, and
## the order is derived from those positions — it is the precedence order the
## concepts are tried in, so the canvas and the engine cannot disagree about
## it. Caps are applied here so a runaway canvas can never write an unbounded
## block.
static func layout(paths: Array, positions: Dictionary, drafts: Array) -> Dictionary:
	var out_positions := {}
	for path in paths:
		if out_positions.size() >= MAX_POSITIONS:
			break
		var name := str(path.get("name", ""))
		var ids: Dictionary = path.get("node_ids", {})
		_copy_position(positions, str(ids.get("trigger", "")), trigger_id(name), out_positions)
		var condition_ids = ids.get("conditions", [])
		if condition_ids is Array:
			for i in condition_ids.size():
				if out_positions.size() >= MAX_POSITIONS:
					break
				_copy_position(positions, str(condition_ids[i]), condition_id(name, i), out_positions)
		_copy_position(positions, str(ids.get("action", "")), action_id(name), out_positions)

	var out_drafts: Array = []
	var draft_nodes := 0
	for chain in drafts:
		if out_drafts.size() >= MAX_DRAFT_CHAINS or draft_nodes >= MAX_DRAFT_NODES:
			break
		if not (chain is Dictionary):
			continue
		var nodes_out: Array = []
		var raw_nodes = chain.get("nodes", [])
		if raw_nodes is Array:
			for node in raw_nodes:
				if draft_nodes >= MAX_DRAFT_NODES:
					break
				if not (node is Dictionary) or str(node.get("id", "")) == "":
					continue
				var kind := str(node.get("kind", ""))
				if not (kind in [KIND_TRIGGER, KIND_CONDITION, KIND_ACTION]):
					continue
				var params = node.get("params", {})
				var id := str(node["id"])
				nodes_out.append({
					"id": id,
					"kind": kind,
					"params": _sanitize_draft_params(kind, params),
				})
				_copy_position(positions, id, id, out_positions)
				draft_nodes += 1
		var ids_out := {}
		for node in nodes_out:
			ids_out[node["id"]] = true
		var edges_out: Array = []
		var raw_edges = chain.get("edges", [])
		if raw_edges is Array:
			for e in raw_edges:
				if e is Array and e.size() == 2 and ids_out.has(str(e[0])) and ids_out.has(str(e[1])):
					edges_out.append([str(e[0]), str(e[1])])
		if nodes_out.size() > 0:
			out_drafts.append({"nodes": nodes_out, "edges": edges_out})

	var out_order: Array = []
	for name in rule_order(paths, positions):
		if out_order.size() >= MAX_ORDER:
			break
		out_order.append(name)

	return {
		"version": GRAPH_VERSION,
		"positions": out_positions,
		"drafts": out_drafts,
		"order": out_order,
	}

## Closed key set per kind — mirrors ConceptManager's sanitizer so a canvas
## round-trip through this function cannot carry junk into the file.
static func _sanitize_draft_params(kind: String, params: Variant) -> Dictionary:
	var out := {}
	if not (params is Dictionary):
		return out
	match kind:
		KIND_TRIGGER:
			out["name"] = str(params.get("name", "")).substr(0, MAX_NAME_LEN)
			out["trigger"] = str(params.get("trigger", "")).substr(0, MAX_PATTERN_LEN)
			out["enabled"] = params.get("enabled", true) == true
		KIND_CONDITION:
			out["pattern"] = str(params.get("pattern", "")).substr(0, MAX_PATTERN_LEN)
		KIND_ACTION:
			var mode := str(params.get("mode", MODE_CAPTURE))
			out["mode"] = mode if mode in [MODE_CAPTURE, MODE_NOTIFY] else MODE_CAPTURE
			out["target"] = str(params.get("target", "")).substr(0, 64)
			out["stop_timeout_ms"] = clampi(int(_number(params.get("stop_timeout_ms"), 300.0)), 1, 600000)
			out["stop_on_input"] = params.get("stop_on_input", true) == true
	return out

# ═══════════════════════════════════════════════════════════════════════
# Internals
# ═══════════════════════════════════════════════════════════════════════

static func _index_nodes(nodes: Array) -> Dictionary:
	var by_id := {}
	for node in nodes:
		if not (node is Dictionary):
			continue
		var id := str(node.get("id", ""))
		var kind := str(node.get("kind", ""))
		if id == "" or not (kind in [KIND_TRIGGER, KIND_CONDITION, KIND_ACTION]):
			continue
		var params = node.get("params", {})
		by_id[id] = {"id": id, "kind": kind, "params": params if params is Dictionary else {}}
	return by_id

static func _live_edges(edges: Array, by_id: Dictionary) -> Array:
	var out: Array = []
	for e in edges:
		if e is Array and e.size() == 2 and by_id.has(str(e[0])) and by_id.has(str(e[1])):
			out.append([str(e[0]), str(e[1])])
	return out

## True when any node of a walk already failed a port rule — the violation was
## reported once for the node, so the chain is silently left out of the rules.
static func _any_tainted(ids: Array, tainted: Dictionary) -> bool:
	for id in ids:
		if tainted.has(str(id)):
			return true
	return false

static func _out_map(edges: Array) -> Dictionary:
	var map := {}
	for e in edges:
		if not (e is Array) or e.size() != 2:
			continue
		var from_id := str(e[0])
		if not map.has(from_id):
			map[from_id] = []
		map[from_id].append(str(e[1]))
	return map

static func _in_map(edges: Array) -> Dictionary:
	var map := {}
	for e in edges:
		if not (e is Array) or e.size() != 2:
			continue
		var to_id := str(e[1])
		if not map.has(to_id):
			map[to_id] = []
		map[to_id].append(str(e[0]))
	return map

## Walk forward from a trigger: every hop must be a single outgoing edge, no
## node may repeat (cycle), and the chain must end at an action.
static func _walk_chain(trigger_id_value: String, by_id: Dictionary, out_map: Dictionary) -> Dictionary:
	var ids: Array = []
	var seen := {}
	var cursor := trigger_id_value
	while true:
		if seen.has(cursor):
			return {"ok": false, "reason": "Chain loops back on itself.", "ids": ids}
		seen[cursor] = true
		ids.append(cursor)
		var node: Dictionary = by_id.get(cursor, {})
		if node.is_empty():
			return {"ok": false, "reason": "Chain points at a missing node.", "ids": ids}
		if node["kind"] == KIND_ACTION:
			if ids.size() < 2:
				return {"ok": false, "reason": "Trigger is attached directly to an action.", "ids": ids}
			return {"ok": true, "reason": "", "ids": ids}
		var outs: Array = out_map.get(cursor, [])
		if outs.size() != 1:
			var name := str(by_id[trigger_id_value]["params"].get("name", ""))
			var what := "Trigger" if cursor == trigger_id_value else "Condition"
			var rule := "'%s'" % name if name != "" else "(unnamed rule)"
			return {
				"ok": false,
				"reason": "%s in %s is not connected through to an action." % [what, rule],
				"ids": ids,
			}
		cursor = str(outs[0])
	return {"ok": false, "reason": "Chain could not be resolved.", "ids": ids}

## Group leftover nodes into connected components; each component is stored as
## one draft chain (nodes + the edges between them).
static func _group_drafts(leftover_ids: Array, edges: Array, by_id: Dictionary) -> Array:
	var alive := {}
	for id in leftover_ids:
		alive[id] = true
	var adjacency := {}
	for id in leftover_ids:
		adjacency[id] = []
	for e in edges:
		if not (e is Array) or e.size() != 2:
			continue
		var a := str(e[0])
		var b := str(e[1])
		if not alive.has(a) or not alive.has(b):
			continue
		adjacency[a].append(b)
		adjacency[b].append(a)
	var chains: Array = []
	var visited := {}
	for id in leftover_ids:
		if visited.has(id):
			continue
		var component: Array = []
		var queue: Array = [id]
		visited[id] = true
		while queue.size() > 0:
			var cursor: String = queue.pop_front()
			component.append(cursor)
			for neighbour in adjacency.get(cursor, []):
				if not visited.has(neighbour):
					visited[neighbour] = true
					queue.append(neighbour)
		component.sort()
		var nodes_out: Array = []
		for cid in component:
			nodes_out.append(by_id[cid])
		var component_set := {}
		for cid in component:
			component_set[cid] = true
		var edges_out: Array = []
		for e in edges:
			if (
				e is Array
				and e.size() == 2
				and component_set.has(str(e[0]))
				and component_set.has(str(e[1]))
			):
				edges_out.append([str(e[0]), str(e[1])])
		chains.append({"nodes": nodes_out, "edges": edges_out})
	return chains

static func _error(message: String, ids: Array) -> Dictionary:
	return {"message": message, "ids": ids}

static func _copy_position(source: Dictionary, from_id: String, to_id: String, out: Dictionary) -> void:
	if to_id == "" or out.has(to_id) or out.size() >= MAX_POSITIONS:
		return
	var v = source.get(from_id)
	if v is Vector2:
		out[to_id] = [clampf(v.x, -MAX_COORD, MAX_COORD), clampf(v.y, -MAX_COORD, MAX_COORD)]
	elif v is Array and v.size() == 2 and _is_number(v[0]) and _is_number(v[1]):
		out[to_id] = [
			clampf(float(v[0]), -MAX_COORD, MAX_COORD),
			clampf(float(v[1]), -MAX_COORD, MAX_COORD),
		]
	else:
		out[to_id] = [0.0, 0.0]

static func _is_number(v: Variant) -> bool:
	return (v is int or v is float) and is_finite(float(v))

## Read a numeric value that may have come from JSON or a hand-edited file
## (wrong types must not raise inside a loader).
static func _number(v: Variant, fallback: float) -> float:
	if v is int or v is float:
		var f := float(v)
		return f if is_finite(f) else fallback
	return fallback
