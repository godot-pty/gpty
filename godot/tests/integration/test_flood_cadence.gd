extends GutTest
# Integration tests for the flood back-off: a pane whose grid work (fetch +
# repaint) exceeds its per-frame budget is looked at less often, so one
# flooding PTY cannot spend every frame rebuilding its canvas. View changes
# the user drives are exempt — the repaint rate is visible there.
#
# The probe pane stays out of the tree, so _ready() never runs and the
# terminal is created directly: an unstarted GptyTerminal answers the calls
# _process() makes (same pattern as test_cursor_blink).

class CadenceProbePane:
	extends TerminalPane

var _probe: CadenceProbePane

func before_each():
	_probe = CadenceProbePane.new()
	_probe._terminal = ClassDB.instantiate("GptyTerminal")
	_probe.max_fps = 60
	_probe._sync_interval = 0.016

func after_each():
	if _probe:
		if _probe._terminal:
			_probe._terminal.free()
		_probe.free()
	_probe = null

## Force the next _process() to see a grid change, preceded by a repaint that
## cost `draw_ms`, with the sync accumulator past any cadence.
func _run_over_budget_sync(draw_ms: int):
	# One below whatever an unstarted terminal reports, so the sync always sees
	# "changed" without depending on that default.
	_probe._last_grid_gen = _probe._terminal.get_grid_generation() - 1
	_probe._draw_ms = draw_ms
	_probe._time_since_sync = 1.0
	_probe._process(0.02)

func test_over_budget_sync_stretches_the_cadence():
	_run_over_budget_sync(TerminalPane.PANE_WORK_BUDGET_MS + 20)
	assert_gt(
		_probe._sync_backoff, 0.0,
		"a sync over the frame budget must stretch the next cadence")

func test_sync_within_budget_keeps_the_cadence():
	_run_over_budget_sync(TerminalPane.PANE_WORK_BUDGET_MS - 1)
	assert_eq(
		_probe._sync_backoff, 0.0,
		"a pane that fits the budget must not be throttled")

func test_user_driven_view_change_is_exempt():
	_probe._note_view_input()
	_run_over_budget_sync(TerminalPane.PANE_WORK_BUDGET_MS + 20)
	assert_eq(
		_probe._sync_backoff, 0.0,
		"scrolling the user asked for must not be pushed into the flood cadence")

func test_backoff_never_exceeds_the_cadence_ceiling():
	for _i in 20:
		_run_over_budget_sync(TerminalPane.PANE_WORK_BUDGET_MS + 20)
	assert_almost_eq(
		_probe._sync_interval + _probe._sync_backoff,
		TerminalPane.MAX_SYNC_INTERVAL, 0.0001,
		"the stretched cadence must stop at the ceiling")

func test_caught_up_pane_recovers_the_cadence():
	_probe._sync_backoff = TerminalPane.MAX_SYNC_INTERVAL - _probe._sync_interval
	_probe._last_grid_gen = _probe._terminal.get_grid_generation()
	# Long enough to pass the stretched cadence, so the sync is attempted and
	# finds nothing new.
	_probe._process(0.2)
	assert_lt(
		_probe._sync_backoff, TerminalPane.MAX_SYNC_INTERVAL - _probe._sync_interval,
		"a sync that finds nothing new must walk the cadence back")
