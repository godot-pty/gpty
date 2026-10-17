extends GutTest
# Unit tests for PaneBody — settings, serialization, signals.
# Instantiate PaneBody directly (add to TestRoot so signals work).

var _scene: Control

func before_each():
	MockAutoloads.setup()
	_scene = TestScene.create()
	add_child(_scene)

func after_each():
	for c in _scene.get_children():
		_scene.remove_child(c)
		c.free()
	MockAutoloads.teardown()
	if _scene:
		remove_child(_scene)
		_scene.free()

# ── Initial state ──────────────────────────────────────────────────────

func test_default_pane_name_empty():
	var body = PaneBody.new()
	_scene.add_child(body)
	assert_eq(body.pane_name, "", "pane_name should default to empty")

func test_default_title_returns_class_name():
	var body = PaneBody.new()
	_scene.add_child(body)
	# PaneBody extends Control; get_class() returns "Control" in Godot
	assert_eq(body._default_title(), "Control")

func test_pane_type_is_base():
	var body = PaneBody.new()
	_scene.add_child(body)
	assert_eq(body._pane_type(), "base")

func test_agent_state_contract_defaults_to_observing_nothing():
	# The workspace dispatches to every pane whose source id matches a
	# terminal; an empty id (the base default) can never match, so a pane that
	# implements nothing is never called.
	var body = PaneBody.new()
	_scene.add_child(body)
	assert_eq(body.agent_state_source_id(), "", "the base pane observes no terminal")

# ── apply_settings ─────────────────────────────────────────────────────

func test_apply_settings_pane_name():
	var body = PaneBody.new()
	_scene.add_child(body)
	body.apply_settings({"pane_name": "test"})
	assert_eq(body.pane_name, "test")

func test_apply_settings_attachment_id_is_independent_of_pane_name():
	var body = PaneBody.new()
	_scene.add_child(body)
	body.apply_settings({
		"pane_name": "OMP Terminal",
		"attachment_id": "omp-terminal",
	})
	assert_eq(body.pane_name, "OMP Terminal")
	assert_eq(body.attachment_id, "omp-terminal")

func test_apply_settings_font_size():
	var body = PaneBody.new()
	_scene.add_child(body)
	body.apply_settings({"font_size": 20})
	assert_eq(body.font_size, 20)

func test_apply_settings_unknown_key():
	var body = PaneBody.new()
	_scene.add_child(body)
	# Unknown keys are ignored — layout JSON is untrusted input. "Ignored" is
	# judged by what the pane saves: nothing about it may change, and the key
	# must not have become a property.
	body.apply_settings({"pane_name": "Stable", "font_size": 17})
	var before := body._get_layout_state()
	body.apply_settings({"bogus": 42, "another-unknown": "x"})
	assert_eq(body._get_layout_state(), before, "unknown keys must not touch the saved state")
	assert_false("bogus" in body, "an unknown key must not create a property")
	assert_eq(body.get("bogus"), null)

func test_apply_settings_bad_type_ignored():
	var body = PaneBody.new()
	_scene.add_child(body)
	body.font_size = 14
	body.apply_settings({"font_size": "big"})
	assert_eq(body.font_size, 14, "string font_size must not overwrite int property")

func test_apply_settings_emits_title_changed():
	var body = PaneBody.new()
	_scene.add_child(body)
	watch_signals(body)
	body.apply_settings({"pane_name": "MyPane"})
	assert_signal_emitted(body, "title_changed")
	assert_signal_emitted_with_parameters(body, "title_changed", ["MyPane"])

func test_apply_settings_emits_default_title_when_pane_name_empty():
	var body = PaneBody.new()
	_scene.add_child(body)
	body.pane_name = "HadName"
	watch_signals(body)
	body.apply_settings({"pane_name": ""})
	assert_signal_emitted_with_parameters(body, "title_changed", [body._default_title()])

# ── _get_layout_state ──────────────────────────────────────────────────

func test_get_layout_state_has_type():
	var body = PaneBody.new()
	_scene.add_child(body)
	body.apply_settings({
		"pane_name": "Saved", "attachment_id": "saved-id",
		"font_size": 17, "tags": ["a", "b"],
	})
	var state = body._get_layout_state()
	assert_eq(state["type"], "base")
	assert_eq(state["pane_name"], "Saved")
	assert_eq(state["attachment_id"], "saved-id")
	assert_eq(state["font_size"], 17)
	assert_eq(state["tags"], ["a", "b"])
	# And the state is what a restore needs: applying it to a fresh pane
	# reproduces it exactly.
	var twin = PaneBody.new()
	_scene.add_child(twin)
	twin.apply_settings(state)
	assert_eq(twin._get_layout_state(), state, "state -> apply -> state is stable")
