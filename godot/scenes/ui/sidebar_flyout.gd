class_name SidebarFlyout
extends Control
## The icons mode's one section flyout: a raised card beside the 48 px rail
## holding the section whose icon was pressed. The section node is the live one
## from the sidebar (reparented, never copied), so its rows keep updating while
## the flyout is open.
##
## The catcher starts at the rail's right edge, not at the window's, so the rail
## stays clickable: another icon switches flyouts and Search/Settings reach the
## workspace. A click in the grid, Escape (the workspace's `_input`) or a
## completed action closes it. The card is opaque (`FLOATING_PANEL`), so the
## effect under the sidebar's rows never tints the flyout's text.

signal close_requested

const CARD_MAX_WIDTH := 320.0
## A section's scroll container has no minimum height of its own, so a purely
## content-sized card would be about its header tall. The floor is the height
## that shows a useful slice of the section; the clamp to the room still wins
## at the 560x340 floor.
const CARD_MIN_HEIGHT := 220.0
const EDGE := UiTokens.SPACE_LG

var _catcher: Control = null
var _card: Panel = null
var _body: VBoxContainer = null
var _content: Control = null
var _return_focus: Control = null
var _top := 0.0
var _bottom := 0.0

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 90
	visible = false

	_catcher = Control.new()
	_catcher.name = "Catcher"
	_catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	_catcher.gui_input.connect(_on_catcher_input)
	add_child(_catcher)

	_card = Panel.new()
	_card.name = "FlyoutCard"
	_card.theme_type_variation = UiTheme.FLOATING_PANEL
	_card.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_card)

	var margin := MarginContainer.new()
	UiTheme.margins(margin, UiTokens.SPACE_XXL)
	_card.add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_body = VBoxContainer.new()
	_body.name = "Body"
	_body.add_theme_constant_override("separation", UiTokens.SPACE_SM)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(_body)

	resized.connect(_layout_children)

## Show `section` in the card, anchored beside the rail between `top` and
## `bottom`. The caller has already detached the section from its column; and
## `close_flyout` + `Sidebar.release_section` put it back.
func open_for(section: Control, top: float, bottom: float, return_focus: Control) -> void:
	if section == null:
		return
	_content = section
	_top = maxf(top, 0.0)
	_bottom = maxf(bottom, _top + 80.0)
	_return_focus = return_focus
	_body.add_child(section)
	visible = true
	_layout_children()
	call_deferred("_focus_body")

func close_flyout(return_focus := true) -> void:
	if not visible:
		return
	visible = false
	_content = null
	if return_focus and _return_focus != null and is_instance_valid(_return_focus) \
			and _return_focus.is_visible_in_tree():
		_return_focus.grab_focus()
	_return_focus = null

func content() -> Control:
	return _content

func _layout_children() -> void:
	if _catcher == null or _card == null:
		return
	_catcher.position = Vector2(Sidebar.ICONS_WIDTH, 0)
	_catcher.size = Vector2(maxf(size.x - Sidebar.ICONS_WIDTH, 0.0), maxf(size.y, 0.0))
	if not visible:
		return
	var width := minf(CARD_MAX_WIDTH,
		maxf(120.0, size.x - Sidebar.ICONS_WIDTH - EDGE * 2.0))
	var room := maxf(80.0, _bottom - _top)
	var content_height := _body.get_combined_minimum_size().y + UiTokens.SPACE_XXL * 2.0
	var height := minf(maxf(maxf(content_height, CARD_MIN_HEIGHT), 80.0), room)
	_card.position = Vector2(Sidebar.ICONS_WIDTH, _top)
	_card.size = Vector2(width, height)

func _focus_body() -> void:
	if not visible or _body == null:
		return
	var first := KeyboardFocus.first_reachable(_body)
	if first != null:
		first.grab_focus()
	elif _return_focus != null and is_instance_valid(_return_focus):
		_return_focus.grab_focus()

func _on_catcher_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		close_requested.emit()
