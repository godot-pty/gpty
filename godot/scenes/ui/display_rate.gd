class_name DisplayRate
## The display the window is on, and how fast it refreshes.
##
## `Engine.max_fps` (while it follows the display) and each terminal's
## follow-the-display sync cadence are resolved against the window's own screen:
## the primary screen is not necessarily where the window is, and two displays
## can refresh at different rates. `window_screen`/`screen_hz` are the
## replaceable seams (a test models a move to a second display without one), so
## every reader resolves the same display through the same pair.

## The cadence a pane runs at when the display answers no rate: a headless run,
## or a driver that reports 0.
const FALLBACK_HZ := 60.0

static var window_screen: Callable = func() -> int:
	return DisplayServer.window_get_current_screen()
static var screen_hz: Callable = func(screen: int) -> float:
	return DisplayServer.screen_get_refresh_rate(screen)

## The screen the window is on right now.
static func current_screen() -> int:
	return int(window_screen.call())

## A screen's refresh rate in Hz; 0 when the platform reports none.
static func rate_for(screen: int) -> float:
	return float(screen_hz.call(screen))

## The window's screen refresh rate in Hz; 0 when unknown.
static func current_rate() -> float:
	return rate_for(current_screen())

## The rate a follow-the-display cadence runs at: the display's, or
## `FALLBACK_HZ` when it answers none.
static func follow_hz() -> float:
	var hz := current_rate()
	return hz if hz > 0.0 else FALLBACK_HZ
