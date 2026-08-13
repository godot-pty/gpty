extends GutTest
# Integration tests: cursor blink visibility.
# Defends the fix for "cursor blink never triggers a redraw": the toggle
# must request a redraw itself so the blink renders even when the grid
# is idle (no grid-generation change to ride on).

class BlinkProbePane:
	extends TerminalPane

	var redraw_requests: int = 0

	func _request_cursor_redraw() -> void:
		redraw_requests += 1


var _probe: BlinkProbePane

func before_each():
	_probe = BlinkProbePane.new()
	# _ready() never runs (probe stays out of the tree), so _terminal is
	# created directly. An unstarted GptyTerminal is enough: get_title() /
	# get_grid_generation() return defaults via with_grid().
	_probe._terminal = ClassDB.instantiate("GptyTerminal")
	# max_fps = 1 → _sync_interval = 1.0s. Manual _process() calls below
	# stay under that, so the grid-sync redraw never fires and the only
	# redraw source is the blink toggle itself.
	_probe.max_fps = 1
	_probe.cursor_blink_speed = 0.4

func after_each():
	if _probe:
		if _probe._terminal:
			_probe._terminal.free()
		_probe.free()
	_probe = null

func test_blink_toggle_requests_redraw():
	_probe._process(0.45)  # 0.45 > cursor_blink_speed (0.4)
	assert_eq(_probe.redraw_requests, 1, "blink toggle should request a redraw")
	assert_false(_probe._cursor_visible, "cursor should hide on first toggle")

func test_no_redraw_before_half_period_elapses():
	_probe._process(0.2)
	_probe._process(0.2)  # blink timer at 0.4, not > 0.4 — no toggle yet
	assert_eq(_probe.redraw_requests, 0, "no redraw until the blink interval is exceeded")
	_probe._process(0.01)  # crosses 0.4 — first toggle
	assert_eq(_probe.redraw_requests, 1, "first toggle after the interval requests a redraw")
