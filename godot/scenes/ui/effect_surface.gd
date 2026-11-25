class_name EffectSurface
extends Control
## A reusable ambient-effect host for grounds that are not terminal panes: the
## Settings preview sample and the sidebar's ground.
##
## `PaneEffects` owns the closed table, the material/buffer and the clock; this
## node supplies the one thing a non-pane ground needs - a `CanvasItem` that
## draws the effect quad and carries the material. On a terminal pane the
## `Layer.EFFECT` node does this, and the pane's own band layout stays its own
## concern; this class deliberately does not refactor `TerminalPane`.
##
## The `PaneEffects` child draws the reactive cues; the parent draws the ground.
## The material is set on this node, never on the child, so a cue is not shaded.

var _effects: PaneEffects = null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	_ensure_effects()
	resized.connect(queue_redraw)

func _ensure_effects() -> void:
	if _effects != null:
		return
	_effects = PaneEffects.new()
	_effects.name = "PaneEffects"
	_effects.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_effects.focus_mode = Control.FOCUS_NONE
	add_child(_effects)
	_effects.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_effects.backdrop_frame.connect(queue_redraw)

## Apply an effect id and an intensity. A repeated call with the same pair is
## free inside `PaneEffects`; the material and texture filter are re-derived
## here because a static and an animated entry need different ones.
func configure(id: String, intensity: int) -> void:
	_ensure_effects()
	_effects.configure(id, intensity)
	material = _effects.layer_material()
	texture_filter = (
		CanvasItem.TEXTURE_FILTER_NEAREST if _effects.uses_buffer()
		else CanvasItem.TEXTURE_FILTER_LINEAR)
	queue_redraw()

func set_ground(color: Color) -> void:
	_ensure_effects()
	_effects.set_ground(color)
	queue_redraw()

func set_cell_height(px: float) -> void:
	_ensure_effects()
	_effects.set_cell_height(px)

func wants_backdrop() -> bool:
	_ensure_effects()
	return _effects.wants_backdrop()

func uses_buffer() -> bool:
	_ensure_effects()
	return _effects.uses_buffer()

func layer_material() -> ShaderMaterial:
	_ensure_effects()
	return _effects.layer_material()

func active_shader() -> Shader:
	_ensure_effects()
	return _effects.active_shader()

## Freeze (or resume) the animated clock for a capture. The redraw is the
## parent's: the static path has no `backdrop_frame` to trigger one.
func pin(pinned: bool) -> void:
	_ensure_effects()
	_effects.pin(pinned)
	queue_redraw()

func _draw() -> void:
	if _effects != null and _effects.wants_backdrop():
		_effects.paint(self, size)
