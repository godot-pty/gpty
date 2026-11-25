extends GutTest
# The Settings card's live sample: the transition runner and the effect host
# are the shipped implementations, so these tests check the preview is wired to
# them (and not to a second animation or shader model).

var _preview: SettingsPreview = null

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_motion = UiMotion.SUBTLE
	SettingsManager.cfg_pane_animation = {}
	SettingsManager.cfg_pane_animation_params = {}
	SettingsManager.cfg_effect = "crt"
	SettingsManager.cfg_effect_intensity = UiEffects.OFF
	SettingsManager.cfg_effect_scope = UiEffects.SCOPE_PANES
	SettingsManager.cfg_reactive_effects = {}
	_preview = SettingsPreview.new()
	add_child_autofree(_preview)
	_preview.size = Vector2(232, 420)
	await wait_frames(2)
	_preview.refresh()
	await wait_frames(1)

func after_each():
	if is_instance_valid(_preview):
		_preview.pause()
	SettingsManager.cfg_motion = UiMotion.SUBTLE
	SettingsManager.cfg_pane_animation = {}
	SettingsManager.cfg_pane_animation_params = {}
	SettingsManager.cfg_effect = "crt"
	SettingsManager.cfg_effect_intensity = UiEffects.OFF
	SettingsManager.cfg_effect_scope = UiEffects.SCOPE_PANES
	SettingsManager.cfg_reactive_effects = {}
	MockAutoloads.teardown()

func _sample() -> SettingsSample:
	return _preview._sample_a

func _effect_clock() -> Timer:
	var surface: EffectSurface = _sample().effect_surface()
	var pane := surface.get_node_or_null("PaneEffects")
	if pane == null:
		return null
	return pane.get_node_or_null("EffectClock") as Timer

# ── Motion ─────────────────────────────────────────────────────────────

func test_play_motion_runs_the_selected_registry_entry():
	SettingsManager.cfg_motion = UiMotion.FULL
	SettingsManager.cfg_pane_animation = {"create": "pop"}
	_preview.play_motion("create")
	assert_eq(_preview._transitions.playing(), 1, "the Pop tween is the one playing")
	var sample := _sample()
	assert_true(sample != null, "the sample exists")
	if sample != null:
		assert_true(sample.scale.x < 1.0 or sample.modulate.a < 1.0,
			"the mid-Pop frame is scaled or faded")

func test_a_property_edit_reaches_the_next_preview_without_a_save():
	SettingsManager.cfg_motion = UiMotion.FULL
	SettingsManager.cfg_pane_animation = {"create": "pop"}
	SettingsManager.cfg_pane_animation_params = {
		"create:pop": {"duration_ms": 400.0},
	}
	_preview.play_motion("create")
	assert_string_contains(_preview.caption_text(), "400 ms",
		"the preview read the in-memory parameter, not a saved one")

func test_motion_off_leaves_the_sample_final():
	SettingsManager.cfg_motion = UiMotion.OFF
	SettingsManager.cfg_pane_animation = {"create": "pop"}
	_preview.play_motion("create")
	assert_eq(_preview._transitions.playing(), 0, "Off starts no tween")
	var sample := _sample()
	if sample != null:
		assert_eq(sample.modulate.a, 1.0)
		assert_true(sample.scale.is_equal_approx(Vector2.ONE))
	assert_string_contains(_preview.caption_text(), "motion Off")

# ── Effects ────────────────────────────────────────────────────────────

func test_play_effect_adds_the_same_layer_a_pane_would():
	SettingsManager.cfg_effect = "grain"
	SettingsManager.cfg_effect_intensity = UiEffects.FULL
	_preview.play_effect()
	var effect := _sample().effect_surface()
	assert_true(effect.wants_backdrop(), "the sample carries the effect")
	assert_true(effect.uses_buffer(), "grain is the animated half-resolution path")
	assert_eq(effect.active_shader(), UiEffects.AMBIENT["grain"]["shader"],
		"the preview runs the table's shader, not a second one")

func test_off_draws_the_plain_ground():
	SettingsManager.cfg_effect = "aurora"
	SettingsManager.cfg_effect_intensity = UiEffects.OFF
	_preview.play_effect()
	var effect := _sample().effect_surface()
	assert_false(effect.wants_backdrop(), "Off leaves the scheme ground")
	assert_string_contains(_preview.caption_text(), "Off")

func test_the_scope_strip_appears_only_when_the_sidebar_carries_it():
	SettingsManager.cfg_effect = "crt"
	SettingsManager.cfg_effect_intensity = UiEffects.FULL
	SettingsManager.cfg_effect_scope = UiEffects.SCOPE_PANES
	_preview.play_effect()
	assert_false(_preview._strip.visible, "panes-only has no sidebar strip")
	assert_true(_sample().effect_surface().wants_backdrop())

	SettingsManager.cfg_effect_scope = UiEffects.SCOPE_BOTH
	_preview.play_effect()
	assert_true(_preview._strip.visible)
	assert_true(_preview._strip_effect.wants_backdrop())

	SettingsManager.cfg_effect_scope = UiEffects.SCOPE_SIDEBAR
	_preview.play_effect()
	assert_true(_preview._strip.visible)
	assert_false(_sample().effect_surface().wants_backdrop(),
		"sidebar-only leaves the pane's ground plain")

func test_a_cue_test_is_rate_limited_like_a_concept_fire():
	assert_true(_preview.play_cue("tint"), "the first cue starts")
	assert_false(_preview.play_cue("tint"), "the second inside 334 ms is dropped")
	await wait_seconds(0.4)
	assert_true(_preview.play_cue("tint"), "the gate reopens after 334 ms")

func test_the_preview_names_the_effect_the_scope_and_the_rate():
	SettingsManager.cfg_effect = "aurora"
	SettingsManager.cfg_effect_intensity = UiEffects.FULL
	SettingsManager.cfg_effect_scope = UiEffects.SCOPE_BOTH
	_preview.play_effect()
	var caption := _preview.caption_text()
	assert_string_contains(caption, "Aurora")
	assert_string_contains(caption, "Full")
	assert_string_contains(caption, "30 Hz")
	assert_string_contains(caption, "Panes and sidebar")
	var sample := _sample()
	if sample != null:
		assert_string_contains(sample.accessibility_name, "Aurora")
		assert_string_contains(sample.accessibility_name, "Panes and sidebar")

func test_the_preview_plays_every_ambient_entry():
	SettingsManager.cfg_effect_intensity = UiEffects.FULL
	SettingsManager.cfg_effect_scope = UiEffects.SCOPE_PANES
	for id in UiEffects.AMBIENT_IDS:
		SettingsManager.cfg_effect = id
		_preview.play_effect()
		var effect := _sample().effect_surface()
		var entry: Dictionary = UiEffects.AMBIENT[id]
		assert_true(effect.wants_backdrop(), "%s paints a backdrop" % id)
		assert_eq(effect.active_shader(), entry["shader"],
			"%s plays the table's shader" % id)
		assert_eq(effect.uses_buffer(), bool(entry["animated"]),
			"%s's buffer path matches its animated flag" % id)

# ── Pins and pause ─────────────────────────────────────────────────────

func test_pin_motion_holds_a_fraction():
	SettingsManager.cfg_motion = UiMotion.FULL
	SettingsManager.cfg_pane_animation = {"create": "fade"}
	_preview.play_motion("create")
	_preview.pin_motion(0.5)
	assert_eq(_preview._transitions.playing(), 1,
		"a pinned transition is still the playing entry")
	var sample := _sample()
	if sample != null:
		assert_gt(sample.modulate.a, 0.05, "the pinned fade is past the start")
		assert_lt(sample.modulate.a, 0.95, "and before the end")

func test_pin_effect_stops_the_clock():
	SettingsManager.cfg_effect = "grain"
	SettingsManager.cfg_effect_intensity = UiEffects.FULL
	_preview.play_effect()
	var clock := _effect_clock()
	assert_not_null(clock, "grain owns the 30 Hz clock")
	if clock == null:
		return
	_preview.pin_effect()
	assert_true(clock.is_stopped(), "a pinned effect renders one frame and stops")

func test_pin_effect_with_a_cue_draws_the_cue_final_frame():
	assert_true(_preview.play_cue("tint"))
	_preview.pin_effect("tint")
	var cue := _sample().cue_layer()
	assert_almost_eq(float(cue.get("_cue_alpha")),
		PaneEffects.TINT_PEAK_ALPHA, 0.001,
		"the pinned cue is the table's peak so a capture repeats")

func test_pause_finishes_transitions_and_freezes_the_effect_clock():
	SettingsManager.cfg_motion = UiMotion.FULL
	SettingsManager.cfg_pane_animation = {"create": "pop"}
	SettingsManager.cfg_effect = "grain"
	SettingsManager.cfg_effect_intensity = UiEffects.FULL
	_preview.play_effect()
	_preview.play_motion("create")
	assert_eq(_preview._transitions.playing(), 1)
	var clock := _effect_clock()
	_preview.pause()
	assert_eq(_preview._transitions.playing(), 0, "pause snaps every tween")
	if clock != null:
		assert_true(clock.is_stopped(), "pause freezes the effect clock")
