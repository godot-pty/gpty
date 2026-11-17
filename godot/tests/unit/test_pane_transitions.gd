extends GutTest
# Pane transition framework — the registry, the stored-choice resolution and
# the motion policy. The tween runner itself is exercised against a real
# workspace in tests/integration/test_pane_motion.gd; here the guards are
# checked without a scene so a refused transition is provably inert.

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_motion = UiMotion.SUBTLE
	SettingsManager.cfg_pane_animation = {}
	SettingsManager.cfg_pane_animation_params = {}

func after_each():
	SettingsManager.cfg_motion = UiMotion.SUBTLE
	SettingsManager.cfg_pane_animation = {}
	SettingsManager.cfg_pane_animation_params = {}
	MockAutoloads.teardown()

# ── Registry shape ─────────────────────────────────────────────────────

func test_every_kind_has_a_default_that_accepts_it():
	for kind in PaneTransitions.KINDS:
		var k := str(kind)
		assert_true(PaneTransitions.DEFAULTS.has(k), "%s needs a default" % k)
		var id := str(PaneTransitions.DEFAULTS[k])
		assert_true(PaneTransitions.ANIMATIONS.has(id), "%s names an unknown id" % id)
		assert_true(PaneTransitions.is_valid(k, id),
			"%s must serve %s" % [id, k])
		assert_true(PaneTransitions.animations_for(k).has(id),
			"%s must be offered for %s" % [id, k])

func test_none_serves_every_kind():
	for kind in PaneTransitions.KINDS:
		assert_true(PaneTransitions.is_valid(str(kind), "none"))

func test_every_animation_only_lists_registry_kinds():
	for id in PaneTransitions.ANIMATIONS:
		var def: Dictionary = PaneTransitions.ANIMATIONS[id]
		for kind in def["kinds"]:
			assert_true(PaneTransitions.KINDS.has(str(kind)),
				"%s lists the unknown kind %s" % [id, kind])

func test_the_pickers_are_filtered_by_kind():
	var create_ids := PaneTransitions.animations_for("create")
	assert_true(create_ids.has("none"))
	assert_true(create_ids.has("fade"))
	assert_true(create_ids.has("fade_scale"))
	assert_false(create_ids.has("move"), "a rect move cannot serve a create")
	var swap_ids := PaneTransitions.animations_for("swap")
	assert_true(swap_ids.has("move"))
	assert_false(swap_ids.has("fade_scale"))

func test_every_param_schema_entry_is_complete_and_in_range():
	for id in PaneTransitions.ANIMATIONS:
		var def: Dictionary = PaneTransitions.ANIMATIONS[id]
		for kind in def["kinds"]:
			for p in PaneTransitions.param_schema(str(kind), str(id)):
				for key in ["key", "label", "default", "min", "max", "step"]:
					assert_true((p as Dictionary).has(key),
						"%s/%s param misses %s" % [id, kind, key])
				assert_true(float(p["min"]) <= float(p["default"]),
					"%s default is under its minimum" % p["key"])
				assert_true(float(p["default"]) <= float(p["max"]),
					"%s default is over its maximum" % p["key"])
				assert_true(float(p["step"]) > 0.0, "%s needs a step" % p["key"])

# ── Stored choice resolution ───────────────────────────────────────────

func test_unknown_choice_falls_back_to_the_kind_default():
	SettingsManager.cfg_pane_animation = {"create": "no_such_animation"}
	assert_eq(PaneTransitions.choice("create"), "fade_scale")

func test_an_animation_from_another_kind_falls_back():
	SettingsManager.cfg_pane_animation = {"create": "move"}
	assert_eq(PaneTransitions.choice("create"), "fade_scale",
		"a swap animation must not run as a create")

func test_a_stored_choice_is_used_when_it_serves_the_kind():
	SettingsManager.cfg_pane_animation = {"create": "fade"}
	assert_eq(PaneTransitions.choice("create"), "fade")

func test_sanitize_choices_fills_every_kind():
	var out := PaneTransitions.sanitize_choices({})
	for kind in PaneTransitions.KINDS:
		assert_eq(str(out[str(kind)]), str(PaneTransitions.DEFAULTS[str(kind)]))

func test_sanitize_choices_replaces_a_wrong_kind_id():
	var out := PaneTransitions.sanitize_choices({"create": "move", "swap": "fade_scale"})
	assert_eq(str(out["create"]), "fade_scale")
	assert_eq(str(out["swap"]), "move")

# ── Parameter sanitation ───────────────────────────────────────────────

func test_sanitize_params_drops_unknown_pairs_and_clamps():
	var out := PaneTransitions.sanitize_params_store({
		"create:nope": {"duration_ms": 100},
		"create:move": {"duration_ms": 100},
		"create:fade_scale": {"duration_ms": 99999, "bogus": 1, "scale_from": "x"},
		"swap:move": {"duration_ms": "soon"},
		"close:none": {"duration_ms": 100},
		"garbage": {},
	})
	assert_false(out.has("create:nope"), "an unknown id is dropped")
	assert_false(out.has("create:move"), "an id of another kind is dropped")
	assert_false(out.has("close:none"), "none declares no properties")
	assert_false(out.has("garbage"), "a key without a kind:id pair is dropped")
	var fade: Dictionary = out["create:fade_scale"]
	assert_almost_eq(float(fade["duration_ms"]), 600.0, 0.001,
		"an out-of-range value clamps to the maximum")
	assert_almost_eq(float(fade["scale_from"]), 0.92, 0.001,
		"a non-number falls back to the schema default")
	assert_false(fade.has("bogus"), "an undeclared property is dropped")
	assert_almost_eq(float(out["swap:move"]["duration_ms"]), 180.0, 0.001)

func test_param_values_fill_missing_keys_with_schema_defaults():
	SettingsManager.cfg_pane_animation_params = {"create:fade_scale": {"scale_from": 0.85}}
	var values := PaneTransitions.param_values("create", "fade_scale")
	assert_almost_eq(float(values["scale_from"]), 0.85, 0.001)
	assert_almost_eq(float(values["duration_ms"]), 160.0, 0.001)
	assert_almost_eq(float(values["overshoot_pct"]), 2.0, 0.001)

func test_param_values_are_empty_for_none():
	assert_eq(PaneTransitions.param_values("create", "none").size(), 0)

# ── Motion policy ──────────────────────────────────────────────────────

func test_overshoot_is_zero_at_subtle_and_capped_at_full():
	SettingsManager.cfg_motion = UiMotion.SUBTLE
	assert_eq(UiMotion.overshoot(3.0), 0.0)
	assert_true(UiMotion.enabled())
	assert_false(UiMotion.allows_overshoot())

	SettingsManager.cfg_motion = UiMotion.FULL
	assert_almost_eq(UiMotion.overshoot(9.0), 0.03, 0.0001)
	assert_almost_eq(UiMotion.overshoot(-1.0), 0.0, 0.0001)
	assert_true(UiMotion.allows_overshoot())

func test_motion_level_is_clamped():
	SettingsManager.cfg_motion = 99
	assert_eq(UiMotion.level(), UiMotion.FULL)
	SettingsManager.cfg_motion = -3
	assert_eq(UiMotion.level(), UiMotion.OFF)
	assert_false(UiMotion.enabled())

# ── Runner guards (no scene) ───────────────────────────────────────────

func test_create_refuses_a_wrapper_with_no_size():
	var w := Control.new()
	add_child_autofree(w)
	var transitions := PaneTransitions.new()
	assert_false(transitions.create(w, true))
	assert_eq(transitions.playing(), 0)

func test_create_refuses_a_hidden_wrapper():
	var w := Control.new()
	w.size = Vector2(100, 100)
	w.visible = false
	add_child_autofree(w)
	var transitions := PaneTransitions.new()
	assert_false(transitions.create(w, true))
	assert_eq(transitions.playing(), 0)

func test_close_without_an_animation_frees_the_wrapper():
	var w := Control.new()
	w.size = Vector2(10, 10)
	add_child(w)
	var transitions := PaneTransitions.new()
	assert_false(transitions.close(w, false))
	await wait_process_frames(1)
	assert_false(is_instance_valid(w))
	assert_eq(transitions.playing(), 0)
