extends OverlayPanel
class_name CommandPalette
## The Ctrl+Shift+P command list. UI only: it names a command and
## `Workspace._execute_command` runs it, so the palette cannot reach a pane or a
## store by itself.
##
## Being an `OverlayPanel` is what gives it the keyboard half of the overlay
## contract: the field is its focus target, Escape closes it through `Workspace`
## (before a focused terminal can read it), and opening it moves focus off the
## terminal so a typed letter becomes part of the query instead of reaching the
## shell.

## A command chosen from the list or submitted from the field, exactly as
## `PaneTypes.build_palette_commands()` spells it.
signal command_chosen(command: String)

var _commands: Array[String] = []
var _field: LineEdit
var _results: VBoxContainer

func _init() -> void:
	_commands = PaneTypes.build_palette_commands()
	custom_minimum_size = Vector2(320, 160)

	var bg := Panel.new()
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", UiTokens.SPACE_SM)
	bg.add_child(v)
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var mc := MarginContainer.new()
	UiTheme.margins(mc, UiTokens.SPACE_LG)
	v.add_child(mc)

	_field = LineEdit.new()
	_field.placeholder_text = "Type command..."
	_field.add_theme_font_size_override("font_size", UiTokens.FS_BODY)
	mc.add_child(_field)

	_results = VBoxContainer.new()
	v.add_child(_results)

	_field.text_changed.connect(_refresh)
	_field.text_submitted.connect(func(_t: String): _choose(_first_match()))

## The field takes the keyboard: typing filters the list from the first letter.
func _initial_focus() -> Control:
	return _field

func _refresh(query: String) -> void:
	for c in _results.get_children():
		c.queue_free()
	for command in _commands:
		if query == "" or command.findn(query) != -1:
			var btn := Button.new()
			btn.text = command
			btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			btn.add_theme_font_size_override("font_size", UiTokens.FS_CONTROL)
			btn.pressed.connect(_choose.bind(command))
			_results.add_child(btn)

## The command currently listed first, or "" when the query matched nothing.
func _first_match() -> String:
	for c in _results.get_children():
		if c is Button and not c.is_queued_for_deletion():
			return (c as Button).text
	return ""

## Close first, then run: the command may open another overlay or focus a new
## pane, and that target must win the keyboard over the one this overlay gives
## back (`OverlayPanel.return_focus`).
func _choose(command: String) -> void:
	if command == "":
		return
	close()
	command_chosen.emit(command)
