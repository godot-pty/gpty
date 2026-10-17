class_name VaultGraphModel
## Pure logic for the wiki pane's link graph canvas.
##
## The graph is a *view* of the vault index, never a second store:
## [code]GptyTerminal.vault_graph[/code] reads the nodes (every indexed note)
## and the aggregated links from `vaults.db`, and this class turns that answer
## into what the canvas draws:
##
## - **One edge per note pair.** The index stores one row per ordered
##   `(src, resolved)` pair with a mention count; parallel curves for every
##   note pair would be noise, and the per-occurrence detail already lives in
##   the backlink panel. A pair that exists in both directions carries
##   [code]mutual[/code] and the total count; direction is kept in
##   [code]ab[/code]/[code]ba[/code] for the optional arrowheads.
## - **Self-references are not drawn.** A note mentioning itself is an edge
##   from a node to that same node — invisible on a flat canvas and already
##   listed by the link panel — so it is dropped here rather than drawn as a
##   growing loop.
## - **Weights are damped, never linear.** Width is logarithmic between
##   [constant EDGE_MIN_WIDTH] and [constant EDGE_MAX_WIDTH], and the layout
##   spring uses the same logarithm, so one chatty note cannot dominate the
##   drawing or pull the whole graph into a point.
## - **Layout is deterministic.** The same graph always lays out the same way
##   (a sunflower seed plus a fixed iteration count and a hash-derived jitter,
##   never a random source), which is what makes it testable and what lets a
##   later persistent arrangement be compared against it. Geometry is the
##   canvas's session state, not this model's: [method layout] takes the
##   positions the view already holds and only places nodes it has not seen.
##
## Nothing here touches the vault, the index, or the scene tree.

## Edge stroke range, in pixels. A mention count maps onto it logarithmically.
const EDGE_MIN_WIDTH := 1.0
const EDGE_MAX_WIDTH := 3.0
## Node radius range, in world units (scaled by the canvas's zoom).
const NODE_MIN_RADIUS := 4.0
const NODE_MAX_RADIUS := 8.0
## Longest label the canvas draws for one node/target (vault text is arbitrary).
const MAX_LABEL_CHARS := 40
## World box the deterministic layout fits into before the view applies its own
## zoom. The view owns pan/zoom; this is only the layout's coordinate space.
const LAYOUT_SIZE := 1000.0
## Fraction of [constant LAYOUT_SIZE] left as padding around the fitted graph.
const LAYOUT_MARGIN := 0.04
## The layout's relaxation is bounded on both ends: fewer than this many
## sweeps leaves clusters overlapping, more cannot pay for itself. The large
## end scales /down/ with the node count, because one sweep costs O(n) and a
## vault at the walk's 2000-note ceiling opens the view on this call.
const MIN_LAYOUT_ITERATIONS := 24
const MAX_LAYOUT_ITERATIONS := 240
## Spring strength is clamped so a note with a thousand mentions is heavier
## than a note with ten, but not a thousand times heavier.
const MAX_SPRING := 4.0

# ═══════════════════════════════════════════════════════════════════════
# The FFI answer
# ═══════════════════════════════════════════════════════════════════════

## Normalize one `vault_graph` answer.
##
## Returns `{"ok": bool, "error": String, "nodes": Array, "edges": Array,
## "truncated": bool}`:
## - `nodes`: `{id, label, ghost}` in the store's order (every note, then one
##   ghost per distinct unresolved target).
## - `edges`: `{a, b, count, ab, ba, mutual, ghost}` in a deterministic order
##   (`a`, then `b`). `a`/`b` are the pair's sorted ids, `count` is the total
##   mentions both ways, `ab`/`ba` the per-direction counts, `mutual` says both
##   directions exist, and `ghost` says one endpoint is an unresolved target.
## - `truncated`: the store capped its edges or ghost nodes (the canvas says
##   so instead of silently showing part of the vault as if it were all).
##
## A malformed answer is an error answer, never a half-built graph: the pane's
## only alternative is to draw something the user would read as the vault.
static func parse(answer: Variant) -> Dictionary:
	if not (answer is Dictionary):
		return _failed("Vault graph unavailable.")
	if answer.has("error"):
		return _failed(str(answer["error"]))
	var by_id := {}
	var nodes: Array = []
	var raw_nodes: Variant = answer.get("nodes", [])
	if raw_nodes is Array:
		for raw in raw_nodes:
			if not (raw is Dictionary):
				continue
			var id := str(raw.get("id", ""))
			if id == "" or by_id.has(id):
				continue
			var label := str(raw.get("label", ""))
			if label.strip_edges() == "":
				label = id.trim_suffix(".md")
			var node := {
				"id": id,
				"label": _label(label),
				"ghost": bool(raw.get("ghost", false)),
			}
			by_id[id] = node
			nodes.append(node)
	# One pair per note pair: an ordered row is a direction, and the canvas
	# draws the pair once with both directions counted.
	var pairs := {}
	var raw_edges: Variant = answer.get("edges", [])
	if raw_edges is Array:
		for raw in raw_edges:
			if not (raw is Dictionary):
				continue
			var src := str(raw.get("src", ""))
			var dst := str(raw.get("dst", ""))
			if src == "" or dst == "" or src == dst:
				continue
			if not by_id.has(src) or not by_id.has(dst):
				# The answer always names nodes it also lists; a row that does
				# not is a store/view skew, and drawing a dangling endpoint
				# would put a node on screen that no record backs.
				continue
			var count := maxi(0, int(raw.get("count", 0)))
			if count == 0:
				continue
			var a := src
			var b := dst
			var forward := true
			if a > b:
				a = dst
				b = src
				forward = false
			var key := a + "\u0000" + b
			if not pairs.has(key):
				pairs[key] = {
					"a": a,
					"b": b,
					"ab": 0,
					"ba": 0,
					"ghost": false,
				}
			var pair: Dictionary = pairs[key]
			if forward:
				pair["ab"] = int(pair["ab"]) + count
			else:
				pair["ba"] = int(pair["ba"]) + count
			if bool(raw.get("ghost", false)) or bool(by_id[a]["ghost"]) or bool(by_id[b]["ghost"]):
				pair["ghost"] = true
	var edges: Array = []
	for key in pairs:
		var pair: Dictionary = pairs[key]
		var ab := int(pair["ab"])
		var ba := int(pair["ba"])
		pair["count"] = ab + ba
		pair["mutual"] = ab > 0 and ba > 0
		edges.append(pair)
	edges.sort_custom(func(left, right):
		if str(left["a"]) != str(right["a"]):
			return str(left["a"]) < str(right["a"])
		return str(left["b"]) < str(right["b"])
	)
	return {
		"ok": true,
		"error": "",
		"nodes": nodes,
		"edges": edges,
		"truncated": bool(answer.get("truncated", false)),
	}

static func _failed(message: String) -> Dictionary:
	return {"ok": false, "error": message, "nodes": [], "edges": [], "truncated": false}

## A label the canvas can draw: one line, bounded. A title can contain a
## newline (the index stores the body's first heading), and `draw_string`
## would render the rest of it off the node.
static func _label(text: String) -> String:
	var flat := text.replace("\r", " ").replace("\n", " ").strip_edges()
	if flat.length() <= MAX_LABEL_CHARS:
		return flat
	return flat.left(MAX_LABEL_CHARS - 1) + "…"

# ═══════════════════════════════════════════════════════════════════════
# Weights and degrees
# ═══════════════════════════════════════════════════════════════════════

## `id -> {in: mentions, out: mentions}` for the drawn edges.
static func degrees(edges: Array) -> Dictionary:
	var out := {}
	for edge in edges:
		if not (edge is Dictionary):
			continue
		var a := str(edge.get("a", ""))
		var b := str(edge.get("b", ""))
		if a == "" or b == "":
			continue
		var ab := maxi(0, int(edge.get("ab", 0)))
		var ba := maxi(0, int(edge.get("ba", 0)))
		if not out.has(a):
			out[a] = {"in": 0, "out": 0}
		if not out.has(b):
			out[b] = {"in": 0, "out": 0}
		out[a]["out"] = int(out[a]["out"]) + ab
		out[a]["in"] = int(out[a]["in"]) + ba
		out[b]["out"] = int(out[b]["out"]) + ba
		out[b]["in"] = int(out[b]["in"]) + ab
	return out

## An edge's stroke width: logarithmic between the two constants, so a pair
## mentioned twice is visibly lighter than one mentioned twenty times and a
## pair mentioned two thousand times does not get a stripe.
static func edge_width(count: int, max_count: int) -> float:
	var top := maxi(1, maxf(1, float(max_count)))
	var value := log(1.0 + float(maxi(0, count))) / log(1.0 + top)
	return clampf(
		EDGE_MIN_WIDTH + (EDGE_MAX_WIDTH - EDGE_MIN_WIDTH) * value,
		EDGE_MIN_WIDTH,
		EDGE_MAX_WIDTH
	)

## The spring strength layout gives one pair: the same logarithm, clamped —
## a linear count would let one hub collapse the graph onto itself.
static func spring_strength(count: int) -> float:
	return clampf(1.0 + log(1.0 + float(maxi(0, count))), 1.0, MAX_SPRING)

## A node's radius in world units: degree raises it within the clamp, so hubs
## read as hubs without swallowing their neighbours.
static func node_radius(degree: int, max_degree: int) -> float:
	var top := maxi(1, max_degree)
	var t := clampf(float(maxi(0, degree)) / float(top), 0.0, 1.0)
	return NODE_MIN_RADIUS + (NODE_MAX_RADIUS - NODE_MIN_RADIUS) * sqrt(t)

# ═══════════════════════════════════════════════════════════════════════
# Layout
# ═══════════════════════════════════════════════════════════════════════

## Positions for `nodes`, in the [constant LAYOUT_SIZE] world box.
##
## `previous` is the canvas's session geometry: an id it holds keeps exactly
## that position (a drag survives a re-query), and only ids it does not hold
## are placed. With no previous geometry the whole graph is laid out
## deterministically — same nodes and edges in, same positions out.
static func layout(nodes: Array, edges: Array, previous := {}) -> Dictionary:
	var positions := {}
	var missing: Array = []
	for node in nodes:
		if not (node is Dictionary):
			continue
		var id := str(node.get("id", ""))
		if id == "":
			continue
		var stored: Variant = previous.get(id) if previous is Dictionary else null
		if stored is Vector2:
			positions[id] = stored
		else:
			missing.append(id)
	if missing.is_empty():
		return positions
	if positions.is_empty():
		_relax(nodes, edges, positions)
	else:
		_place_missing(nodes, edges, positions, missing)
	return positions

## Place the ids the canvas has never seen without touching the ones it has:
## next to a laid-out neighbour when the graph connects one, otherwise on a
## deterministic ring around the current cluster.
static func _place_missing(nodes: Array, edges: Array, positions: Dictionary, missing: Array) -> void:
	var wanted := {}
	for id in missing:
		wanted[id] = true
	var placed := {}
	for edge in edges:
		if not (edge is Dictionary):
			continue
		var a := str(edge.get("a", ""))
		var b := str(edge.get("b", ""))
		for pair in [[a, b], [b, a]]:
			var mine: String = pair[0]
			var other: String = pair[1]
			if not wanted.has(mine) or placed.has(mine) or not positions.has(other):
				continue
			var angle := _hash_unit(mine) * TAU
			var distance := NODE_MIN_RADIUS * 4.0
			positions[mine] = positions[other] + Vector2(cos(angle), sin(angle)) * distance
			placed[mine] = true
	var centre := Vector2.ZERO
	for id in positions:
		centre += positions[id]
	if positions.size() > 0:
		centre /= float(positions.size())
	var ring := 0
	for id in missing:
		if placed.has(id):
			continue
		var angle := _hash_unit(id) * TAU + float(ring) * 0.7
		var distance := NODE_MIN_RADIUS * (6.0 + float(ring) * 1.5)
		positions[id] = centre + Vector2(cos(angle), sin(angle)) * distance
		ring += 1

## Full deterministic layout: a sunflower seed (no random source), then a
## bounded Fruchterman–Reingold relaxation with a spatial grid — the graph can
## hold the walk's 2000 notes, so all-pairs repulsion would be 4M pairs per
## sweep and is not an option.
static func _relax(nodes: Array, edges: Array, positions: Dictionary) -> void:
	var ids: Array = []
	for node in nodes:
		if not (node is Dictionary):
			continue
		var id := str(node.get("id", ""))
		if id != "" and not positions.has(id):
			ids.append(id)
	var n := ids.size()
	var centre := Vector2.ONE * LAYOUT_SIZE * 0.5
	if n == 0:
		return
	if n == 1:
		positions[ids[0]] = centre
		return
	var ideal := LAYOUT_SIZE / sqrt(float(n))
	# Seed on a sunflower: even coverage, index-ordered, plus a hash jitter so
	# a symmetric graph does not start in a symmetric equilibrium (a torus of
	# notes would otherwise stay a ring forever).
	for index in n:
		var id := str(ids[index])
		var angle := float(index) * 2.399963229728653
		var radius := sqrt((float(index) + 0.5) / float(n)) * LAYOUT_SIZE * 0.46
		var jitter := _hash_unit(id) * ideal * 0.2
		var jitter_angle := _hash_unit(id + "j") * TAU
		positions[id] = centre + Vector2(cos(angle), sin(angle)) * radius \
			+ Vector2(cos(jitter_angle), sin(jitter_angle)) * jitter
	var iterations := clampi(
		int(round(float(MAX_LAYOUT_ITERATIONS) / (1.0 + float(n) / 120.0))),
		MIN_LAYOUT_ITERATIONS,
		MAX_LAYOUT_ITERATIONS
	)
	for sweep in iterations:
		var temperature := ideal * (1.0 - float(sweep) / float(iterations)) * 0.6 + ideal * 0.02
		var displacement := {}
		for id in ids:
			displacement[id] = Vector2.ZERO
		# Repulsion, grid-accelerated: each node pushes on the nodes of its own
		# cell and the eight around it. The cutoff is 1.5 cells, so a pair that
		# is far apart (which is the layout's goal) costs nothing.
		var cell := ideal * 2.0
		var grid := {}
		var mass := {}
		for id in ids:
			var point: Vector2 = positions[id]
			var key := Vector2i(int(floor(point.x / cell)), int(floor(point.y / cell)))
			if not grid.has(key):
				grid[key] = []
			grid[key].append(id)
			mass[key] = mass.get(key, Vector2.ZERO) + point
		var repel_cap := ideal * 2.0
		for id in ids:
			var point: Vector2 = positions[id]
			var cell_x := int(floor(point.x / cell))
			var cell_y := int(floor(point.y / cell))
			var force := Vector2.ZERO
			# Own cell: pairwise, because that is what keeps two nodes in the
			# same cell from stacking (the two closest nodes share a cell).
			var own: Array = grid.get(Vector2i(cell_x, cell_y), [])
			for other in own:
				if other == id:
					continue
				var delta: Vector2 = point - positions[other]
				var distance := delta.length()
				if distance < 0.0001:
					delta = Vector2(0.70710678, 0.70710678)
					distance = 0.0001
				force += delta / distance * minf(ideal * ideal / distance, repel_cap)
			# Neighbouring cells: one force from the cell's centre of mass,
			# weighted by its population. The alternative — every node in the
			# nine cells against every other — is what made a 2000-note vault
			# pay milliseconds per sweep; a cell is a small enough cluster for
			# its centroid to stand in for its members.
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					if dx == 0 and dy == 0:
						continue
					var key := Vector2i(cell_x + dx, cell_y + dy)
					if not grid.has(key):
						continue
					var bucket: Array = grid[key]
					if bucket.is_empty():
						continue
					var centroid: Vector2 = (mass[key] as Vector2) / float(bucket.size())
					var delta: Vector2 = point - centroid
					var distance := delta.length()
					if distance < 0.0001:
						delta = Vector2(0.70710678, 0.70710678)
						distance = 0.0001
					force += delta / distance * minf(ideal * ideal / distance, repel_cap) \
						* float(bucket.size()) * 0.5
			displacement[id] += force
		# Attraction along each drawn pair, damped by the same logarithm.
		for edge in edges:
			if not (edge is Dictionary):
				continue
			var a := str(edge.get("a", ""))
			var b := str(edge.get("b", ""))
			if not positions.has(a) or not positions.has(b):
				continue
			var delta: Vector2 = positions[b] - positions[a]
			var distance := delta.length()
			if distance < 0.0001:
				continue
			var magnitude := (distance * distance / ideal) * spring_strength(int(edge.get("count", 1))) * 0.25
			var pull := delta / distance * magnitude
			displacement[a] += pull
			displacement[b] -= pull
		# Gravity keeps disconnected islands from drifting out of the box;
		# without it a component with no edges only feels the seed.
		for id in ids:
			displacement[id] += (centre - positions[id]) * 0.02
			var move: Vector2 = displacement[id]
			var length := move.length()
			if length > temperature and length > 0.0:
				move = move / length * temperature
			positions[id] = positions[id] + move
	_fit(positions, ids)

## Scale the layout into the world box, centred, preserving its shape.
static func _fit(positions: Dictionary, ids: Array) -> void:
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for id in ids:
		var point: Vector2 = positions[id]
		low = low.min(point)
		high = high.max(point)
	var span := high - low
	var extent := maxf(span.x, span.y)
	if extent < 0.001:
		for id in ids:
			positions[id] = Vector2.ONE * LAYOUT_SIZE * 0.5
		return
	var usable := LAYOUT_SIZE * (1.0 - 2.0 * LAYOUT_MARGIN)
	var scale := usable / extent
	var used := span * scale
	var pad := (Vector2.ONE * LAYOUT_SIZE - used) * 0.5
	for id in ids:
		positions[id] = (positions[id] - low) * scale + pad

## The bounding box of the laid-out graph, or an empty rect.
static func bounds(positions: Dictionary) -> Rect2:
	if positions.is_empty():
		return Rect2()
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for id in positions:
		var point: Vector2 = positions[id]
		low = low.min(point)
		high = high.max(point)
	return Rect2(low, high - low)

## The node nearest `point` within `radius` world units, or `""`.
##
## Ties break by id so the answer is deterministic when two nodes sit on the
## same spot (a dragged stack, or two ghosts with the same label).
static func hit_test(nodes: Array, positions: Dictionary, point: Vector2, radius: float) -> String:
	var best := ""
	var best_distance := INF
	for node in nodes:
		if not (node is Dictionary):
			continue
		var id := str(node.get("id", ""))
		if id == "" or not positions.has(id):
			continue
		var distance := (positions[id] as Vector2).distance_to(point)
		if distance > radius:
			continue
		if distance < best_distance or (is_equal_approx(distance, best_distance) and (best == "" or id < best)):
			best = id
			best_distance = distance
	return best

# ═══════════════════════════════════════════════════════════════════════
# Determinism
# ═══════════════════════════════════════════════════════════════════════

## 32-bit FNV-1a, spelled out rather than `hash()`: the model's layout must be
## identical across runs and machines, and `hash()` is a process-seeded
## implementation detail just like `DefaultHasher` is in Rust.
static func _hash_unit(text: String) -> float:
	var value := 2166136261
	for byte in text.to_utf8_buffer():
		value = (value ^ int(byte)) & 0xFFFFFFFF
		value = (value * 16777619) & 0xFFFFFFFF
	return float(value) / 4294967295.0
