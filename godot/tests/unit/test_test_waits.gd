extends GutTest
# TestWaits — the bounded predicate used in place of fixed create_timer sleeps.

func test_an_immediate_condition_returns_at_once():
	var start := Time.get_ticks_msec()
	assert_true(await TestWaits.until(func(): return true, 1.0),
		"an already-true condition must return true")
	assert_lt(Time.get_ticks_msec() - start, 100,
		"an already-true condition must not wait for a frame")

func test_a_never_true_condition_times_out():
	var start := Time.get_ticks_msec()
	assert_false(await TestWaits.until(func(): return false, 0.1),
		"a condition that never holds must return false")
	var elapsed := Time.get_ticks_msec() - start
	assert_gte(elapsed, 90, "the timeout must actually be spent")
	assert_lt(elapsed, 500, "a 0.1 s timeout must not hang the frame loop")

func test_a_condition_that_becomes_true_after_frames_returns_true():
	var state := {"calls": 0}
	var condition := func() -> bool:
		state.calls += 1
		return state.calls >= 4
	assert_true(await TestWaits.until(condition, 1.0),
		"a condition that becomes true after a few frames must return true")
