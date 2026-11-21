class_name PaneEffects
extends Control
## The per-pane effect host: the ambient GPU effect behind a terminal's text
## (and, in the reactive half, one short cue above it).
##
## The terminal paints one full-pane rect from its own `Layer.EFFECT` and asks
## this node how: a static effect carries a `ShaderMaterial` on that layer, and
## an animated one renders in a half-resolution `SubViewport` at its table's
## rate, which the layer draws as a texture. `UiEffects` owns the closed table;
## this class owns the nodes and the clock.
##
## A Control rather than a RefCounted because the reactive cue draws above the
## text bands: this node is the pane's last child and its `_draw` carries the
## tint and the pulse. It never takes input or focus.
##
## Nothing is allocated per frame: the shader is evaluated on the GPU, the
## static path is redrawn only when the pane changes, and the animated path
## ticks once per `1 / hz` from a Timer. A hidden pane stops the clock.

## The per-pane flash ceiling: three starts in any second (WCAG's flash rule).
const FLASH_MIN_INTERVAL_MS := 334
## How fast the grain's noise field advances, independent of frame rate.
const GRAIN_RATE := 8.0
## Half resolution: the row's declared budget for a `TIME`-driven effect.
const BUFFER_SHRINK := 0.5

## A new buffer frame is ready; the pane queues its effect layer.
signal backdrop_frame

var _ambient_id := ""
var _intensity := 0
var _ground: Color = Color(0, 0, 0)
var _cell_height: float = 0.0
var _static_material: ShaderMaterial = null
var _animated_material: ShaderMaterial = null
var _buffer: SubViewport = null
var _buffer_rect: ColorRect = null
var _timer: Timer = null
var _phase := 0.0
var _pinned := false
var _configured_key := ""

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	visibility_changed.connect(_sync_clock)
	_sync_clock()

## Apply the ambient effect the pane's settings name. A repeated call is free:
## the key covers both the id and the intensity. Intensity 0 (Off) frees the
## material and the buffer, so a pane with no effect owns nothing extra.
func configure(id: String, intensity: int) -> void:
	var key := "%s:%d" % [id, intensity]
	if key == _configured_key:
		return
	_configured_key = key
	var wanted := UiEffects.AMBIENT.has(id) and intensity > UiEffects.OFF
	_ambient_id = id if wanted else ""
	_intensity = intensity
	_clear_backdrop()
	if _ambient_id == "":
		return
	var entry: Dictionary = UiEffects.AMBIENT[_ambient_id]
	var shader: Shader = entry["shader"]
	if bool(entry["animated"]):
		_build_buffer(shader, int(entry["hz"]))
	else:
		_static_material = ShaderMaterial.new()
		_static_material.shader = shader
		_static_material.set_shader_parameter("strength", _strength())
	_sync_clock()

func wants_backdrop() -> bool:
	return _ambient_id != ""

func uses_buffer() -> bool:
	return _animated_material != null

## The material the pane's effect layer carries on the static path; null when
## the animated path draws the buffer texture instead.
func layer_material() -> ShaderMaterial:
	return _static_material

func set_ground(color: Color) -> void:
	_ground = color
	if _buffer_rect != null:
		_buffer_rect.color = color

func set_cell_height(height: float) -> void:
	_cell_height = height

## One full-pane effect quad. Called from the pane's effect layer's `_draw`, so
## the layer is the only item carrying the draw command (a material on the grid
## itself would run per band and per glyph run).
func paint(item: CanvasItem, pane_size: Vector2) -> void:
	if _ambient_id == "":
		return
	if _animated_material != null:
		_sync_buffer_size(pane_size)
		_animated_material.set_shader_parameter("strength", _strength())
		_animated_material.set_shader_parameter("phase", _phase)
		if _buffer != null:
			item.draw_texture_rect(_buffer.get_texture(), Rect2(Vector2.ZERO, pane_size), false)
		return
	if _static_material == null:
		return
	_static_material.set_shader_parameter("strength", _strength())
	_static_material.set_shader_parameter("rows", _rows_for(pane_size))
	_static_material.set_shader_parameter("quad_px", pane_size)
	item.draw_rect(Rect2(Vector2.ZERO, pane_size), _ground)

## Freeze (or resume) the animated clock for a capture: a pinned grain renders
## one deterministic frame and stops, so two runs of a state are identical.
func pin(pinned: bool) -> void:
	_pinned = pinned
	_phase = 0.0
	if _animated_material != null:
		_animated_material.set_shader_parameter("phase", 0.0)
	if _buffer != null:
		_buffer.render_target_update_mode = SubViewport.UPDATE_ONCE
	_sync_clock()

func _strength() -> float:
	return float(UiEffects.STRENGTH.get(_intensity, 0.0))

## Scanline periods across the quad: derived from the terminal's own cell
## height, so the pattern tracks the type size and never the window size.
func _rows_for(pane_size: Vector2) -> float:
	var period := maxf(2.0, roundf(_cell_height / 6.0))
	return maxf(1.0, pane_size.y / period)

func _sync_buffer_size(pane_size: Vector2) -> void:
	if _buffer == null:
		return
	var wanted := Vector2i(
		maxi(1, int(pane_size.x * BUFFER_SHRINK)),
		maxi(1, int(pane_size.y * BUFFER_SHRINK)))
	if _buffer.size != wanted:
		_buffer.size = wanted
		if _buffer_rect != null:
			_buffer_rect.size = Vector2(wanted)

func _sync_clock() -> void:
	if _timer == null:
		return
	var run := _animated_material != null and not _pinned and is_visible_in_tree()
	if run and _timer.is_stopped():
		_timer.start()
	elif not run and not _timer.is_stopped():
		_timer.stop()

func _tick() -> void:
	_phase = fmod(Time.get_ticks_msec() / 1000.0 * GRAIN_RATE, 1000.0)
	if _animated_material != null:
		_animated_material.set_shader_parameter("phase", _phase)
	if _buffer != null:
		_buffer.render_target_update_mode = SubViewport.UPDATE_ONCE
	backdrop_frame.emit()

func _build_buffer(shader: Shader, hz: int) -> void:
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("strength", _strength())
	_animated_material = material
	_buffer = SubViewport.new()
	_buffer.name = "EffectBuffer"
	_buffer.disable_3d = true
	_buffer.transparent_bg = false
	_buffer.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_buffer)
	_buffer_rect = ColorRect.new()
	_buffer_rect.name = "Ground"
	_buffer_rect.color = _ground
	_buffer_rect.material = material
	_buffer.add_child(_buffer_rect)
	_timer = Timer.new()
	_timer.name = "EffectClock"
	_timer.wait_time = 1.0 / maxf(1.0, float(hz))
	_timer.timeout.connect(_tick)
	add_child(_timer)

func _clear_backdrop() -> void:
	if _timer != null:
		_timer.stop()
		remove_child(_timer)
		_timer.free()
		_timer = null
	if _buffer != null:
		remove_child(_buffer)
		_buffer.free()
		_buffer = null
		_buffer_rect = null
	_animated_material = null
	_static_material = null
