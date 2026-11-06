class_name Icons

# All icons sourced from Phosphor Regular (MIT). Codepoints are BMP PUA (U+E000-U+F8FF).

const font_resource := preload("res://assets/fonts/Phosphor-Regular.ttf")

## The child `Label` an icon button draws its glyph with.
const GLYPH_NAME := "Glyph"

## Style one glyph button: one treatment for every icon-only control.
##
## The glyph is a codepoint, and the engine composes a button's exposed name as
## `"<explicit name>: <text>"`, so a glyph left in `Button.text` reaches a
## screen reader as a private-use character. It is therefore drawn by a child
## `Label` (`Glyph`) and the button's own `text` stays empty: the exposed name is
## the words alone. `Icons.glyph` reads the codepoint back and `Icons.set_glyph`
## swaps it at runtime — the only way a constructed icon button changes what it
## shows.
##
## The name is a required argument, not a separate call: a newly added icon
## button is exactly the kind of site a convention loses, and the parameter makes
## the compiler ask for the words. `variation` tints the glyph (a Button's own
## font colours cannot reach the child Label).
static func icon_button(btn: Button, glyph: String, accessible_name: String, variation := &"") -> void:
	btn.text = ""
	btn.theme_type_variation = UiTheme.ICON_BUTTON
	btn.custom_minimum_size.x = maxf(btn.custom_minimum_size.x, UiTokens.BUTTON_MIN_WIDTH)
	btn.accessibility_name = accessible_name
	var label := _labeled_glyph(btn)
	if label != null:
		_fill(label, glyph, accessible_name, variation)
		return
	# The Label is fully set up before it enters the tree: an element's exposed
	# name is the snapshot taken when it is created, so a Label added first would
	# publish an empty name and then never pick the words up.
	label = _new_glyph_label()
	_fill(label, glyph, accessible_name, variation)
	btn.add_child(label)

## The codepoint an icon button draws, `""` when it draws none (a text button,
## or a glyph button built before this helper existed).
static func glyph(btn: Button) -> String:
	var label := _labeled_glyph(btn)
	return label.text if label != null else ""

## Change what a constructed icon button draws, keeping it the same element.
## The child's exposed name follows the button's, so callers that rename with
## the glyph (`WindowChrome._sync_max_button`) set `accessibility_name` first.
static func set_glyph(btn: Button, glyph: String) -> void:
	var label := _labeled_glyph(btn)
	if label == null:
		icon_button(btn, glyph, btn.accessibility_name)
		return
	label.text = glyph
	label.accessibility_name = btn.accessibility_name

static func _labeled_glyph(btn: Button) -> Label:
	var existing := btn.get_node_or_null(NodePath(GLYPH_NAME))
	return existing as Label if existing is Label else null

## The glyph `Label`'s shape: decoration centred over the button, taking no
## pointer, no focus and no layout space of its own.
static func _new_glyph_label() -> Label:
	var label := Label.new()
	label.name = GLYPH_NAME
	label.add_theme_font_override("font", font_resource)
	# The glyph is a heading, not body text: an icon button renders at this size
	# on every chrome surface, and the engine's 16 px default is what it used.
	label.add_theme_font_size_override("font_size", UiTokens.FS_HEADING)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label

static func _fill(label: Label, glyph: String, accessible_name: String, variation: StringName) -> void:
	label.text = glyph
	label.accessibility_name = accessible_name
	label.theme_type_variation = variation

const CLOSE    = "\uE4F6"  # x
const DELETE   = "\uE4A6"  # trash
const SEARCH   = "\uE30C"  # magnifying-glass
const MINIMIZE = "\uE32A"  # minus
const RESTORE  = "\uE0A2"  # arrows-out
const COLLAPSE = "\uE138"  # caret-left
const EXPAND   = "\uE13A"  # caret-right
const ADD      = "\uE3D4"  # plus
const SETTINGS = "\uE272"  # gear-six
const FOLDER   = "\uE24A"  # folder (a directory picker, not a settings surface)
const NEW_WORKSPACE = "\uE5DE"  # arrow-square-out (open a profile in its own workspace)
const RESET    = "\uE038"  # arrow-counter-clockwise (pane type swap)
const SWAP     = "\uE0A0"  # arrows-left-right (position swap)
const MAXIMIZE_WIN = "\uE0A2"  # arrows-out (expand/fullscreen)
const RESTORE_WIN = "\uE09A"  # arrows-in (restore from fullscreen)
const WINDOW_MODE = "\uE32E"  # monitor (window mode cycling)
const CHECK_CIRCLE = "\uE184"  # check-circle (agent state: completed)
const X_CIRCLE = "\uE4F8"  # x-circle (agent state: failed)
const WARNING = "\uE4E0"  # warning, the triangle (agent state: needs-attention)
const SPINNER = "\uE66A"  # spinner (agent state: working, frame 1)
const SPINNER_GAP = "\uE66C"  # spinner-gap (agent state: working, frame 2)
const CIRCLE_NOTCH = "\uEB44"  # circle-notch (agent state: working, frame 3)
