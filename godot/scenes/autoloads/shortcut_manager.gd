extends Node

var _actions: Dictionary = {}

func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS

func register(action_name: String, default_bind: String, callback: Callable):
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
		var event = _parse_bind(default_bind)
		if event:
			InputMap.action_add_event(action_name, event)
	_actions[action_name] = callback

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
			_actions[action].call()
			get_viewport().set_input_as_handled()
			return
