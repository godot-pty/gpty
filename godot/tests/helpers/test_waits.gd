class_name TestWaits
## Poll a condition until it holds or the wall-clock deadline passes.
##
## Fixed sleeps made half of every GUT run wait without doing anything. A test
## that waits for an observable state (a pane spawned, a deferred push landed,
## a profile list refreshed) polls the state against `process_frame` instead,
## so it returns as soon as the work is done and still fails on a real timeout
## rather than hanging the run.
##
## `until` is wall-clock bounded because a stalled frame must not turn a
## timeout into a hang; GUT's own stall guard remains the backstop.
static func until(condition: Callable, timeout: float = 5.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await Engine.get_main_loop().process_frame
	return condition.call()
