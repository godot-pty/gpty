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

func test_a_default_background_run_is_skipped_only_while_a_backdrop_owns_the_ground():
	_seed_cache(2, 4)
	_probe._repaint_all()
	assert_false(_probe._backdrop_covers_background(_probe._ground),
		"with no effect the ground run is still painted by the band")
	assert_false(_probe._backdrop_covers_background(Color.RED))

	_apply("crt", UiEffects.SUBTLE)
	assert_true(_probe._backdrop_covers_background(_probe._ground),
		"the effect layer is the ground, so its run must stay uncovered")
	assert_false(_probe._backdrop_covers_background(Color.RED),
		"a coloured cell still paints its own rect over the effect")

	_apply("crt", UiEffects.OFF)
	assert_false(_probe._backdrop_covers_background(_probe._ground),
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

## Mount the probe so `is_visible_in_tree()` is true. Its size stays zero, so
## no shell is spawned for a cue test; the effect host anchors itself to it.
func _mount_probe() -> void:
	add_child(_probe)
	await get_tree().process_frame

func test_a_cue_is_rate_limited_to_three_a_second():
	await _mount_probe()
	_probe._ensure_effects()
	var effects = _probe._effects
	assert_true(effects.flash_at("tint", 0), "the first start is accepted")
	assert_false(effects.flash_at("tint", 100), "inside the 334 ms window")
	assert_false(effects.flash_at("tint", 200), "still inside it")
	assert_true(effects.flash_at("tint", 400), "the window has passed")

func test_a_hidden_pane_never_cues():
	await _mount_probe()
	_probe._ensure_effects()
	_probe.hide()
	assert_false(_probe._effects.flash_at("tint", 0), "a hidden pane draws nothing")
	assert_eq(_probe._effects._last_flash_ms, -1,
		"and consumes no part of the rate window")
	_probe.show()

func test_a_tint_cue_uses_the_danger_tone():
	assert_eq(UiEffects.tone_color("tint"), UiPalette.active().DANGER)
	assert_eq(UiEffects.tone_color("pulse"), UiPalette.active().ACCENT)
	assert_eq(UiEffects.tone_color("particles"), UiPalette.active().SUCCESS)

func test_pinning_a_cue_draws_its_final_frame():
	await _mount_probe()
	_probe._ensure_effects()
	_probe._effects.pin_cue("tint")
	assert_eq(_probe._effects._cue_alpha, PaneEffects.TINT_PEAK_ALPHA)
	assert_eq(_probe._effects._pulse_alpha, 0.0)
	_probe._effects.pin_cue("pulse")
	assert_eq(_probe._effects._pulse_alpha, PaneEffects.PULSE_PEAK_ALPHA)
	assert_eq(_probe._effects._cue_alpha, 0.0)

func test_particles_are_a_fixed_preallocated_burst():
	await _mount_probe()
	_probe._ensure_effects()
	assert_null(_probe._effects._particles, "the pool is created on first use")
	assert_true(_probe._effects.flash_at("particles", 1000))
	var pool: CPUParticles2D = _probe._effects._particles
	assert_not_null(pool)
	assert_eq(pool.amount, PaneEffects.PARTICLES_AMOUNT, "the cap is the amount")
	assert_true(pool.one_shot, "a burst, not a stream")
	assert_true(pool.emitting, "the burst started")
	assert_null(pool.material, "the default material is normal blend; nothing adds")


# ── The Motion setting ─────────────────────────────────────────────────

## Motion Off is a promise about the screen, not the next restart: the animated
## field stops at the frame a capture pins, and the next save starts it again.
func test_motion_off_stops_the_animated_clock():
	_seed_cache(2, 4)
	_apply("grain", UiEffects.FULL)
	await _mount_probe()
	_probe._effects._sync_clock()
	assert_false(_probe._effects._timer.is_stopped(), "grain advances while motion is on")

	SettingsManager.cfg_motion = UiMotion.OFF
	SettingsManager.settings_changed.emit()
	assert_true(_probe._effects._timer.is_stopped(), "Off stops the clock")
	assert_eq(_probe._effects._phase, 0.0, "at the pinned phase")
	assert_eq(_probe._effects._buffer.render_target_update_mode, SubViewport.UPDATE_ONCE,
		"and renders that one frame")

	SettingsManager.cfg_motion = UiMotion.SUBTLE
	SettingsManager.settings_changed.emit()
	assert_false(_probe._effects._timer.is_stopped(), "turning it back on restarts it")

## A cue at Off keeps its state perceivable without motion: one still border in
## the cue's own tone for its hold, no fade and no particle burst.
func test_a_cue_at_motion_off_is_a_still_border():
	await _mount_probe()
	_probe._ensure_effects()
	SettingsManager.cfg_motion = UiMotion.OFF
	assert_true(_probe._effects.flash_at("tint", 1000))
	assert_almost_eq(_probe._effects._still_alpha, PaneEffects.PULSE_PEAK_ALPHA, 0.001)
	assert_eq(_probe._effects._cue_alpha, 0.0, "no tint fade")
	assert_eq(_probe._effects._cue_effect, "tint", "the border wears the cue's tone")
	assert_true(_probe._effects.flash_at("particles", 2000), "the rate window has passed")
	assert_null(_probe._effects._particles, "no burst at Off")
	await wait_seconds(0.55)
	assert_eq(_probe._effects._still_alpha, 0.0, "the still border clears after its hold")
	SettingsManager.cfg_motion = UiMotion.SUBTLE

func test_a_cue_at_motion_off_keeps_the_rate_limit():
	await _mount_probe()
	_probe._ensure_effects()
	SettingsManager.cfg_motion = UiMotion.OFF
	assert_true(_probe._effects.flash_at("pulse", 0))
	assert_false(_probe._effects.flash_at("pulse", 100), "inside the 334 ms window")
	assert_true(_probe._effects.flash_at("pulse", 400), "the window has passed")
	SettingsManager.cfg_motion = UiMotion.SUBTLE
