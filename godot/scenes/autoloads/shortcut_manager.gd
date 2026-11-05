extends Node

## Actions that keep firing while a workspace overlay owns the keyboard: the
## window actions (the palette and sidebar toggles and fullscreen) and nothing
## that changes the workspace the overlay is configuring.
var _survives_overlay: Dictionary = {}

## Whether an overlay owns the keyboard. `Workspace` injects its
## `_keyboard_overlay()` - the one predicate - and a bare manager (the autoload
## before a workspace exists, a unit test) answers false.
var overlay_owns_keyboard: Callable = func() -> bool: return false

var _actions: Dictionary = {}

func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS

## Wire an action to the chord that fires it. `survives_overlay` is only for an
## action that acts on the window itself (the palette and sidebar toggles and
## fullscreen): every other chord is refused while an overlay owns the keyboard,
## so a spawn or a reset cannot land behind an open panel.
func register(action_name: String, default_bind: String, callback: Callable, survives_overlay := false):
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
		var event = _parse_bind(default_bind)
		if event:
			InputMap.action_add_event(action_name, event)
	_actions[action_name] = callback
	_survives_overlay[action_name] = survives_overlay

func _parse_bind(bind_str: String) -> InputEventKey:
	if bind_str.strip_edges() == "":
		return null
	var parts = bind_str.split("+")
	var ev = InputEventKey.new()
	for p in parts:
		p = p.strip_edges().to_upper()
		if p == "CTRL": ev.ctrl_pressed = true
		elif p == "SHIFT": ev.shift_pressed = true
		elif p == "ALT": ev.alt_pressed = true
		else:
			var kc = OS.find_keycode_from_string(p)
			if kc == 0:
				push_error("Unknown keycode: ", p)
			ev.keycode = kc
	return ev

func is_shortcut(event: InputEvent) -> bool:
	if not event is InputEventKey: return false
	for action in _actions.keys():
		if event.is_action(action, true): # true = exact match
			return true
	return false

func _unhandled_input(event):
	if not event is InputEventKey or not event.pressed: return
	for action in _actions.keys():
		if event.is_action_pressed(action, false, true): # exact match
			if not bool(_survives_overlay.get(action, false)) and _overlay_owns_keyboard():
				# Refused on purpose, and consumed: a chord typed into an open
				# panel must not land behind it as an action or as a keystroke.
				get_viewport().set_input_as_handled()
				return
			_actions[action].call()
			get_viewport().set_input_as_handled()
			return

## `overlay_owns_keyboard`, safe against a workspace that has already been freed
## (a test's workspace, or a shutting-down tree).
func _overlay_owns_keyboard() -> bool:
	return overlay_owns_keyboard.is_valid() and bool(overlay_owns_keyboard.call())
