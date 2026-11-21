extends GutTest
# The per-pane effect host: the ground layer's place in the paint order, the
# default-background runs it leaves uncovered, the static material, the
# half-resolution buffer behind an animated effect, and (later in this file) the
# reactive cue's rate limit.
#
# The draw-layer half uses the same synthetic cache as `test_terminal_repaint.gd`
# and needs no PTY: the layer tree is what is asserted, not pixels. The visible
# half is `scripts/ui-capture`'s `effect-*` states.

class ProbePane:
	extends TerminalPane

var _probe: ProbePane

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_shell_command = SettingsManager.default_shell_command()
	SettingsManager.cfg_effect = UiEffects.DEFAULT_AMBIENT
	SettingsManager.cfg_effect_intensity = UiEffects.OFF
	SettingsManager.cfg_reactive_effects = {}
	_probe = ProbePane.new()

func after_each():
	if _probe:
		if _probe._terminal:
			_probe._terminal.free()
		_probe.free()
	_probe = null
	SettingsManager.cfg_effect = UiEffects.DEFAULT_AMBIENT
	SettingsManager.cfg_effect_intensity = UiEffects.OFF
	SettingsManager.cfg_reactive_effects = {}
	MockAutoloads.teardown()

## A synthetic packed cache: the layer order and the row-run decision do not
## need a PTY, and a literal cache is what makes the geometry assertable.
func _seed_cache(rows: int, cols: int) -> void:
	var line := "x".repeat(cols)
	var chars: Array = []
	var fg := PackedColorArray()
	var bg := PackedColorArray()
	var attrs := PackedInt32Array()
	for _r in rows:
		chars.append(line)
		for _c in cols:
			fg.append(Color.WHITE)
			bg.append(Color.BLACK)
			attrs.append(0)
	_probe._cell_w = 9.0
	_probe._cell_h = 18.0
	_probe.size = Vector2(200.0, 200.0)
	_probe._cell_cache = {
		"is_full": true, "rows": rows, "cols": cols,
		"chars": chars, "fg": fg, "bg": bg, "attrs": attrs,
	}

func _apply(effect: String, intensity: int) -> void:
	_probe.apply_settings({"effect": effect, "effect_intensity": intensity})
	_probe._repaint_all()

func test_an_active_effect_adds_one_ground_layer_below_every_band():
	_seed_cache(4, 10)
	_apply("crt", UiEffects.FULL)
	assert_not_null(_probe._effect_layer, "an active effect owns a layer")
	assert_eq(_probe._effect_layer.get_index(), 0, "the effect paints first: it is the ground")
	for i in 4:
		assert_eq(_probe._row_backgrounds[i].get_index(), 1 + i,
			"background bands paint above the effect, in row order")
		assert_eq(_probe._row_texts[i].get_index(), 5 + i,
			"every text band paints above every background")
	assert_eq(_probe._overlay.get_index(), 9, "the overlay paints above the bands")

func test_no_effect_layer_exists_while_the_intensity_is_off():
	_seed_cache(4, 10)
	_probe._repaint_all()
	assert_null(_probe._effect_layer, "Off owns no layer")
	for i in 4:
		assert_eq(_probe._row_backgrounds[i].get_index(), i)
		assert_eq(_probe._row_texts[i].get_index(), 4 + i)
	assert_eq(_probe._overlay.get_index(), 8, "the unshifted order the repaint tests pin")

func test_a_default_background_run_is_skipped_only_while_an_effect_is_active():
	_seed_cache(2, 4)
	_probe._repaint_all()
	assert_false(_probe._effect_covers_background(_probe._ground),
		"with no effect the ground run is still painted by the band")
	assert_false(_probe._effect_covers_background(Color.RED))

	_apply("crt", UiEffects.SUBTLE)
	assert_true(_probe._effect_covers_background(_probe._ground),
		"the effect layer is the ground, so its run must stay uncovered")
	assert_false(_probe._effect_covers_background(Color.RED),
		"a coloured cell still paints its own rect over the effect")

	_apply("crt", UiEffects.OFF)
	assert_false(_probe._effect_covers_background(_probe._ground),
		"turning it off returns the run to the band")

func test_the_static_effect_carries_its_shader_on_the_layer():
	_seed_cache(2, 4)
	_apply("crt", UiEffects.FULL)
	var material := _probe._effect_layer.material as ShaderMaterial
	assert_not_null(material, "the static path carries a material on its own layer")
	assert_eq(material.shader, UiEffects.AMBIENT["crt"]["shader"],
		"the layer runs the table's shader")
	assert_eq(_probe._effect_layer.texture_filter, CanvasItem.TEXTURE_FILTER_LINEAR,
		"a static effect draws its own colour, not a buffer texture")

func test_the_animated_effect_renders_into_a_half_resolution_buffer():
	_seed_cache(2, 4)
	_apply("grain", UiEffects.FULL)
	assert_true(_probe._effects.uses_buffer(), "grain is the animated half")
	assert_null(_probe._effect_layer.material,
		"the animated path draws a buffer, not a static rect")
	_probe._effects._sync_buffer_size(Vector2(400.0, 300.0))
	var buffer: SubViewport = _probe._effects._buffer
	assert_not_null(buffer)
	assert_eq(buffer.size, Vector2i(200, 150), "the buffer is half the pane")
	assert_eq(buffer.render_target_update_mode, SubViewport.UPDATE_ONCE,
		"one frame per tick, not every frame")
	assert_eq(_probe._effect_layer.texture_filter, CanvasItem.TEXTURE_FILTER_NEAREST,
		"the half-res texture is sampled without smoothing")

func test_a_pin_renders_one_buffer_frame_and_stops_the_clock():
	_seed_cache(2, 4)
	_apply("grain", UiEffects.FULL)
	_probe._effects.pin(true)
	assert_true(_probe._effects._pinned, "the capture frozen the clock")
	assert_eq(_probe._effects._phase, 0.0, "the pinned frame is phase 0")
	assert_eq(_probe._effects._buffer.render_target_update_mode, SubViewport.UPDATE_ONCE,
		"the pinned frame is still rendered once")
	assert_true(_probe._effects._timer.is_stopped(), "the pinned clock does not tick")

func test_turning_the_effect_off_frees_the_layer_and_the_buffer():
	_seed_cache(2, 4)
	_apply("grain", UiEffects.FULL)
	assert_not_null(_probe._effects._buffer)
	_apply("grain", UiEffects.OFF)
	assert_null(_probe._effect_layer, "the layer is gone")
	assert_false(_probe._effects.wants_backdrop(), "no ground is claimed")
	assert_null(_probe._effects._buffer, "the buffer is freed")
