class_name VaultGraphCanvas
extends Control
## The contract shared by the wiki pane's two link-map presentations.
##
## [VaultGraphView] draws the planar canvas; [VaultGraph3D] runs the orbital
## map in a `SubViewport`. The pane types its view as this base and swaps the
## two at runtime, so the signals, the session geometry, the graph theme and
## the public verbs live here and neither presentation invents its own.
##
## `positions` is model-space geometry (`id -> Vector2`), owned per view. The
## model remains the data, layout and hit-test owner; this base only carries
## what the pane and the drawing code share. `graph_theme` selects one of
## [GraphTheme]'s closed tables; `_style` is the resolved snapshot both draw
## code reads, rebuilt by [method apply_graph_theme] and never cached from the
## palette in a class-body initializer.
##
## The verbs below are the contract. GDScript has no abstract methods, so each
## is declared with an empty body (a base body is never reached): subclasses
## must override every one.

## A note node was clicked. `id` is the vault-relative path the index uses.
signal node_activated(id: String)
## An unresolved-target node was clicked. `target` is the `[[…]]` target with
## its synthetic node prefix removed.
signal ghost_activated(target: String)
## The user asked to declare a weight for an edge. `current` is the pair's
## existing declaration, 0 when it has none.
signal weight_set_requested(a: String, b: String, current: int)
## The user asked to clear an edge's declared weight.
signal weight_cleared(a: String, b: String)
## The user asked for the other presentation: `"2d"` or `"3d"`.
signal mode_requested(mode: String)

## The click radius around a node, in screen pixels.
const HIT_RADIUS := 11.0
## How close a press must be to an edge's line, in screen pixels, to offer its
## declared-weight menu.
const EDGE_HIT_RADIUS := 6.0
## Screen pixels of pointer travel before a press counts as a drag rather than
## a click. Godot delivers motion in small steps, so this is measured from the
## press, not per event.
const DRAG_THRESHOLD := 4.0

var nodes: Array = []
var edges: Array = []
## Session geometry: id -> Vector2 in the model's world space. A view keeps it
## across re-queries so dragging a node lasts as long as the pane does.
var positions: Dictionary = {}
var selected_id := ""
var hovered_id := ""
var show_arrows := false
## The graph's own theme id ([GraphTheme.IDS]); the pane owns the setting and
## calls [method apply_graph_theme] on a fresh or live view.
var graph_theme := "default"
## The resolved [GraphTheme.style] snapshot the draw code reads.
var _style: Dictionary = {}

## The store capped the graph; the status says so instead of presenting a cut
## graph as whole.
var _truncated := false


## Re-resolve the graph style for `id` under the active appearance and apply it.
## Safe before the view enters the tree: subclasses store the style and guard
## their widgets, and `_ready` calls this again.
func apply_graph_theme(id: String) -> void:
	graph_theme = GraphTheme.normalize(id)
	_style = GraphTheme.style(graph_theme, SettingsManager.is_dark_appearance())
	_apply_style()
	queue_redraw()


## Subclass hook: re-derive materials, chrome colours, the status line and the
## backdrop from `_style`. Called after `_style` changes; never reads the
## palette directly.
func _apply_style() -> void:
	pass


## The style for the current theme, resolved lazily for a view shown before
## `_ready` ran.
func _theme_style() -> Dictionary:
	if _style.is_empty():
		_style = GraphTheme.style(graph_theme, SettingsManager.is_dark_appearance())
	return _style


## Replace the canvas with one normalized graph answer (the parse's result).
## `current_id` is the note the pane has open; `prepared_positions` may be a
## worker's Vector2 geometry or the `[x, y]` pairs a layout file carries.
func show_graph(_data: Dictionary, _current_id := "", _prepared_positions := {}) -> void:
	pass


## Re-apply the authored layer without re-querying the index.
func set_weights(_declared: Dictionary) -> void:
	pass


## Highlight one node without opening it (the pane passes its open note).
func set_selected(_id: String) -> void:
	pass


## Recompute the deterministic layout, discarding every drag in this session.
func relayout() -> void:
	pass


## Scale and centre the graph in the view.
func fit_to_view() -> void:
	pass


## Session geometry as the canonical `{id: [x, y]}` block the layout state
## stores. Only ids the current node list holds are written.
func export_positions() -> Dictionary:
	return {}


## Merge a prepared arrangement with the view's live geometry: the live value
## wins for every id both hold, and the prepared value supplies new ids. This
## is what lets a drag made during a worker build survive the result and what
## lets a mode switch hand pair-form geometry to a fresh view.
func _positions_source(prepared: Variant, previous: Dictionary) -> Dictionary:
	var source := {}
	if prepared is Dictionary:
		source = prepared.duplicate()
	for id in previous:
		source[id] = previous[id]
	return source


func _has_node(id: String) -> bool:
	for node in nodes:
		if node is Dictionary and str(node.get("id", "")) == id:
			return true
	return false


## The text this canvas draws for a node: its label, else its id.
func _label_for(id: String) -> String:
	for node in nodes:
		if node is Dictionary and str(node.get("id", "")) == id:
			return str(node.get("label", id))
	return id


func _make_button(text: String, tooltip: String) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.add_theme_font_size_override("font_size", UiTokens.FS_CAPTION)
	return button
