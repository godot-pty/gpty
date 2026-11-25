extends GutTest
# UiMotion's two shared pieces: the declared-duration conversion and the one
# arrival helper (the fade every appearing surface runs through). The policy
# levels themselves are exercised where they are consumed (pane transitions,
# the badge, the guide); this file pins the helper's contract.

var _host: Control

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_motion = UiMotion.SUBTLE
	_host = Control.new()
	_host.size = Vector2(200, 100)
	add_child_autofree(_host)

func after_each():
	SettingsManager.cfg_motion = UiMotion.SUBTLE
	MockAutoloads.teardown()

## A child of the plain Control host, so `position` is the test's own and no
## container re-sorts it.
func _target(at := Vector2(10, 20)) -> Control:
	var node := Control.new()
	node.position = at
	node.size = Vector2(100, 50)
	_host.add_child(node)
	return node

func test_duration_is_zero_at_off_and_declared_above_it():
	SettingsManager.cfg_motion = UiMotion.OFF
	assert_eq(UiMotion.duration_s(0.2), 0.0, "Off draws the final frame")
	assert_eq(UiMotion.duration_s(-1.0), 0.0, "a negative duration is no duration")
	SettingsManager.cfg_motion = UiMotion.SUBTLE
	assert_almost_eq(UiMotion.duration_s(0.2), 0.2, 0.0001)
	SettingsManager.cfg_motion = UiMotion.FULL
	assert_almost_eq(UiMotion.duration_s(0.2), 0.2, 0.0001,
		"the level changes the curve, not a declared duration")

func test_off_draws_an_arrival_in_one_frame():
	SettingsManager.cfg_motion = UiMotion.OFF
	var node := _target()
	var tw := UiMotion.arrive(node, UiMotion.ARRIVAL_MS, UiMotion.ARRIVAL_RISE_PX)
	assert_null(tw, "there is nothing to run")
	assert_eq(node.modulate, Color.WHITE, "the surface is already final")
	assert_false(node.has_meta(UiMotion.ARRIVAL_META), "no arrival was recorded")

func test_an_arrival_fades_from_transparent_to_the_nodes_own_alpha():
	var node := _target()
	var tw := UiMotion.arrive(node)
	assert_not_null(tw)
	assert_almost_eq(node.modulate.a, 0.0, 0.001, "the first frame is transparent")
	await wait_seconds(0.25)
	assert_almost_eq(node.modulate.a, 1.0, 0.001)
	assert_true(node.size.is_equal_approx(Vector2(100, 50)),
		"an arrival never resizes")

func test_only_full_rises_and_the_rect_never_changes():
	var subtle := _target(Vector2(10, 20))
	UiMotion.arrive(subtle, UiMotion.ARRIVAL_MS, UiMotion.ARRIVAL_RISE_PX)
	assert_almost_eq(subtle.position.y, 20.0, 0.001,
		"Subtle fades without movement")
	await wait_seconds(0.2)
	assert_almost_eq(subtle.position.y, 20.0, 0.001)

	SettingsManager.cfg_motion = UiMotion.FULL
	var full := _target(Vector2(10, 40))
	UiMotion.arrive(full, UiMotion.ARRIVAL_MS, UiMotion.ARRIVAL_RISE_PX)
	assert_almost_eq(full.position.y, 44.0, 0.001,
		"Full starts the surface four pixels low")
	await wait_seconds(0.2)
	assert_almost_eq(full.position.y, 40.0, 0.001, "and lands on its own rect")
	assert_true(full.size.is_equal_approx(Vector2(100, 50)),
		"the rise never resizes")

func test_a_delay_staggers_the_fade():
	var node := _target()
	UiMotion.arrive(node, 60.0, 0.0, 150.0)
	await wait_seconds(0.05)
	assert_almost_eq(node.modulate.a, 0.0, 0.01, "the stagger holds it transparent")
	await wait_seconds(0.35)
	assert_almost_eq(node.modulate.a, 1.0, 0.01)

func test_pin_arrival_freezes_the_shipped_curve():
	SettingsManager.cfg_motion = UiMotion.FULL
	var node := _target()
	UiMotion.arrive(node, 200.0, UiMotion.ARRIVAL_RISE_PX)
	assert_almost_eq(node.modulate.a, 0.0, 0.001)
	UiMotion.pin_arrival(node, 0.5)
	var half := node.modulate.a
	assert_gt(half, 0.0, "the pinned frame is past the start")
	assert_lt(half, 1.0, "and before the end")
	var half_y := node.position.y
	await wait_seconds(0.3)
	assert_almost_eq(node.modulate.a, half, 0.001, "the paused arrival does not run")
	assert_almost_eq(node.position.y, half_y, 0.001)
	UiMotion.pin_arrival(node, 1.0)
	assert_almost_eq(node.modulate.a, 1.0, 0.01, "progress 1 is the completed frame")
	assert_almost_eq(node.position.y, 20.0, 0.01, "including the rise's landing")

# ── The dismissal and the shared list rules ────────────────────────────

func test_a_dismiss_fades_out_then_hides():
	SettingsManager.cfg_motion = UiMotion.SUBTLE
	var node := _target()
	var calls := [0]
	var tw := UiMotion.dismiss(node, 100.0, func(): calls[0] += 1)
	assert_not_null(tw)
	assert_true(node.visible, "the surface is still on screen while it fades")
	assert_gt(node.modulate.a, 0.0, "the fade starts from the alpha on screen")
	await wait_seconds(0.2)
	assert_false(node.visible, "a dismissal hides when the ramp ends")
	assert_almost_eq(node.modulate.a, 0.0, 0.001)
	assert_eq(calls[0], 1, "the finish callback runs once")

func test_off_dismisses_in_one_frame():
	SettingsManager.cfg_motion = UiMotion.OFF
	var node := _target()
	var calls := [0]
	var tw := UiMotion.dismiss(node, 100.0, func(): calls[0] += 1)
	assert_null(tw, "there is nothing to run")
	assert_false(node.visible)
	assert_eq(calls[0], 1)
	assert_almost_eq(node.modulate.a, 0.0, 0.001)

func test_an_arrival_after_a_dismiss_is_visible_again():
	var node := _target()
	UiMotion.dismiss(node, 10.0)
	await wait_seconds(0.1)
	assert_false(node.visible)
	node.visible = true
	SettingsManager.cfg_motion = UiMotion.OFF
	assert_null(UiMotion.arrive(node), "Off runs nothing")
	assert_almost_eq(node.modulate.a, 1.0, 0.001,
		"Off restores the settled alpha a dismissal left at zero")
	SettingsManager.cfg_motion = UiMotion.SUBTLE
	UiMotion.arrive(node, 50.0)
	assert_almost_eq(node.modulate.a, 0.0, 0.001,
		"a repeat arrival on a settled surface fades again")
	await wait_seconds(0.2)
	assert_almost_eq(node.modulate.a, 1.0, 0.001)

func test_an_interrupted_arrival_keeps_its_settled_target():
	var node := _target()
	var first := UiMotion.arrive(node, 200.0) as Tween
	await wait_seconds(0.05)
	var mid := node.modulate.a
	assert_gt(mid, 0.0, "the first ramp is under way")
	assert_lt(mid, 1.0)
	var second := UiMotion.arrive(node, 200.0) as Tween
	assert_not_null(second)
	assert_false(first.is_valid(), "the interrupted ramp is killed")
	assert_almost_eq(node.modulate.a, mid, 0.01,
		"the new ramp starts where the screen was")
	await wait_seconds(0.3)
	assert_almost_eq(node.modulate.a, 1.0, 0.001,
		"the settled alpha is still the target")
	UiMotion.arrive(node, 50.0)
	assert_almost_eq(node.modulate.a, 0.0, 0.001,
		"a settled surface fades again instead of resuming")

func test_only_a_prefix_append_is_an_arrival():
	assert_eq(UiMotion.appended_indices([], ["a"]).size(), 0,
		"a first render is not an arrival")
	assert_eq(UiMotion.appended_indices(["a"], ["a", "b"]), [1])
	assert_eq(UiMotion.appended_indices(["a"], ["a", "b", "c"]), [1, 2])
	assert_eq(UiMotion.appended_indices(["a"], ["a", "b", "c", "d"]), [1, 2, 3])
	assert_eq(UiMotion.appended_indices(["a"], ["a", "b", "c", "d", "e"]).size(), 0,
		"more than three new rows is a content change, not a created row")
	assert_eq(UiMotion.appended_indices(["a"], ["b"]).size(), 0,
		"a replacement never cascades fades")
	assert_eq(UiMotion.appended_indices(["a", "b"], ["a"]).size(), 0)
	assert_eq(UiMotion.appended_indices(["a", "b"], ["a", "c", "d"]).size(), 0,
		"a rename is not a prefix")

func test_stagger_is_full_only():
	SettingsManager.cfg_motion = UiMotion.OFF
	assert_eq(UiMotion.stagger_ms(1), 0.0)
	SettingsManager.cfg_motion = UiMotion.SUBTLE
	assert_eq(UiMotion.stagger_ms(1), 0.0, "Subtle has no stagger")
	SettingsManager.cfg_motion = UiMotion.FULL
	assert_eq(UiMotion.stagger_ms(0), 0.0, "the first row starts at once")
	assert_eq(UiMotion.stagger_ms(1), UiMotion.ARRIVAL_STAGGER_MS)
	assert_eq(UiMotion.stagger_ms(2), 2.0 * UiMotion.ARRIVAL_STAGGER_MS)
	assert_eq(UiMotion.stagger_ms(3), 0.0, "the cap is three staggered rows")
	assert_eq(UiMotion.stagger_ms(-1), 0.0)
