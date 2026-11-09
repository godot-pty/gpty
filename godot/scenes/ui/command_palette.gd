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
##
## Layout: this overlay is a full-rect mouse-transparent host holding a centred
## fixed-size card. The workspace used to anchor the whole panel `PRESET_CENTER`
## while its size was still zero, which put the top-left corner on the centre.
##
## Keyboard: one surface. The field owns the keyboard and the arrow keys move a
## `UiTheme.SELECTED_ROW` cursor that stays visible underneath it; Enter runs
## the cursor (not "whatever matched first"). Rows are deliberately
## `FOCUS_NONE` — Tab must not park a user on a row that cannot also type the
## filter. What the list offers is `PaletteModel`, so an entry's cost is data,
## not code here.

## A command chosen from the list or submitted from the field, exactly as
## `PaletteModel.commands()` spells it.
signal command_chosen(command: String)

const PALETTE_WIDTH := 560
const PALETTE_HEIGHT := 480
const ROW_HEIGHT := 28
const GLYPH_WIDTH := 24
const NO_MATCH_TEXT := "No matching command"
const KEY_HINT_TEXT := "↑/↓ select · Enter run · Esc close"

var _field: LineEdit
var _scroll: ScrollContainer
var _results: VBoxContainer
var _empty: Label
var _card: Panel
var _rows: Array[Button] = []
var _selected: int = -1

func _init() -> void:
	# The card swallows its own clicks; the host must not block the workspace
	# around it (the same split `SettingsPanel` makes).
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var cc := CenterContainer.new()
	add_child(cc)
	cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_card = Panel.new()
	_card.name = "Card"
	_card.custom_minimum_size = Vector2(PALETTE_WIDTH, PALETTE_HEIGHT)
	cc.add_child(_card)

	var mc := MarginContainer.new()
	UiTheme.margins(mc, UiTokens.SPACE_LG)
	_card.add_child(mc)
	mc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", UiTokens.SPACE_SM)
	mc.add_child(body)

	_field = LineEdit.new()
	_field.name = "Query"
	_field.placeholder_text = "Type a command…"
	_field.add_theme_font_size_override("font_size", UiTokens.FS_BODY)
	body.add_child(_field)

	_scroll = ScrollContainer.new()
	_scroll.name = "ResultScroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(_scroll)

	_results = VBoxContainer.new()
	_results.name = "Results"
	_results.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_results.add_theme_constant_override("separation", UiTokens.SPACE_XS)
	_scroll.add_child(_results)

	_empty = Label.new()
	_empty.name = "Empty"
	_empty.text = NO_MATCH_TEXT
	_empty.theme_type_variation = UiTheme.MUTED_LABEL
	_empty.add_theme_font_size_override("font_size", UiTokens.FS_SMALL)
	_empty.visible = false
	body.add_child(_empty)

	var hint := Label.new()
	hint.name = "KeyHint"
	hint.text = KEY_HINT_TEXT
	hint.theme_type_variation = UiTheme.MUTED_LABEL
	hint.add_theme_font_size_override("font_size", UiTokens.FS_CAPTION)
	body.add_child(hint)

	_field.text_changed.connect(_refresh)
	_field.text_submitted.connect(func(_t: String): _activate_selected())

## The field takes the keyboard: typing filters the list from the first letter.
func _initial_focus() -> Control:
	return _field

## Opening always starts from an unfiltered list: the field is cleared (a
## stale query from the last visit used to hide every entry) and the list is
## rebuilt before focus moves in. The card is also clamped to the overlay's own
## rect first: at the 560x340 layout floor a fixed 480 px card would hang
## outside the window (the small-window rework is v0.8.2's; the palette just
## never draws outside its host).
func _before_open() -> void:
	var edge := float(UiTokens.SPACE_XXL)
	_card.custom_minimum_size = Vector2(
		minf(PALETTE_WIDTH, size.x - edge * 2.0),
		minf(PALETTE_HEIGHT, size.y - edge * 2.0))
	_field.text = ""
	_refresh("")

func _refresh(query: String) -> void:
	# Remove before freeing so the list a caller (or a test) reads in this
	# frame is the new one, never the old rows waiting on `queue_free`.
	for child in _results.get_children():
		_results.remove_child(child)
		child.queue_free()
	_rows.clear()
	for entry in PaletteModel.filter(query):
		var row := _make_row(entry)
		_results.add_child(row)
		_rows.append(row)
	_selected = 0 if not _rows.is_empty() else -1
	_empty.visible = _rows.is_empty()
	_apply_selection()

## Move the cursor. Clamped, not wrapped: the ends stay put so holding an
## arrow cannot tour the list without a stop.
func _move_selection(delta: int) -> void:
	if _rows.is_empty():
		return
	_selected = clampi(_selected + delta, 0, _rows.size() - 1)
	_apply_selection()

func _apply_selection() -> void:
	for i in _rows.size():
		(_rows[i] as Button).button_pressed = i == _selected
	if _selected >= 0 and _selected < _rows.size():
		_scroll.ensure_control_visible(_rows[_selected])

## Arrow keys are the list's cursor while the field keeps the keyboard. The
## raw input stage runs before GUI input, so the LineEdit never sees them. A
## modified arrow is left alone (Shift+arrow selects text).
func _input(event: InputEvent) -> void:
	if not visible or not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	if key.ctrl_pressed or key.alt_pressed or key.shift_pressed:
		return
	match key.keycode:
		KEY_DOWN: _move_selection(1)
		KEY_UP: _move_selection(-1)
		_: return
	get_viewport().set_input_as_handled()

func _activate_selected() -> void:
	if _selected < 0 or _selected >= _rows.size():
		return
	_choose(str(_rows[_selected].get_meta("command")))

## Close first, then run (unchanged contract): the command may open another
## overlay or focus a new pane, and that target must win the keyboard over the
## one this overlay gives back (`OverlayPanel.return_focus`).
func _choose(command: String) -> void:
	if command == "":
		return
	close()
	command_chosen.emit(command)

## One row: the glyph column, the name the row shows, and the chord it answers.
## The pressed state of the `SELECTED_ROW` variation is the cursor, so selecting
## a row never swaps its theme variation.
func _make_row(entry: Dictionary) -> Button:
	var command := str(entry["command"])
	var label := str(entry["label"])
	var action := str(entry["action"])
	var hint := ShortcutManager.chord(action) if action != "" else ""
	var variation: StringName = entry.get("variation", &"")

	var row := Button.new()
	row.name = "Row"
	row.focus_mode = Control.FOCUS_NONE
	row.toggle_mode = true
	row.theme_type_variation = UiTheme.SELECTED_ROW
	row.custom_minimum_size.y = ROW_HEIGHT
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.accessibility_name = label
	row.tooltip_text = label if hint == "" else "%s (%s)" % [label, hint]
	row.set_meta("command", command)
	row.set_meta("hint", hint)
	row.pressed.connect(_choose.bind(command))

	var body := HBoxContainer.new()
	body.name = "RowBody"
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_theme_constant_override("separation", UiTokens.SPACE_MD)
	row.add_child(body)
	body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	body.offset_left = UiTokens.SPACE_MD
	body.offset_right = -UiTokens.SPACE_MD

	var glyph := Label.new()
	glyph.name = "Glyph"
	glyph.text = str(entry["glyph"])
	glyph.add_theme_font_override("font", Icons.font_resource)
	glyph.add_theme_font_size_override("font_size", UiTokens.FS_CONTROL)
	glyph.custom_minimum_size.x = GLYPH_WIDTH
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glyph.theme_type_variation = variation
	body.add_child(glyph)

	var name_lbl := Label.new()
	name_lbl.name = "Name"
	name_lbl.text = label
	name_lbl.add_theme_font_size_override("font_size", UiTokens.FS_CONTROL)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_lbl.clip_text = true
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_lbl.theme_type_variation = variation
	body.add_child(name_lbl)

	var hint_lbl := Label.new()
	hint_lbl.name = "Hint"
	hint_lbl.text = hint
	hint_lbl.add_theme_font_size_override("font_size", UiTokens.FS_CAPTION)
	hint_lbl.theme_type_variation = UiTheme.MUTED_LABEL
	hint_lbl.size_flags_horizontal = Control.SIZE_SHRINK_END
	hint_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(hint_lbl)
	return row
