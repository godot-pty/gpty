class_name Icons

# All icons sourced from Phosphor Regular (MIT). Codepoints are BMP PUA (U+E000-U+F8FF).

const font_resource := preload("res://assets/fonts/Phosphor-Regular.ttf")

## Style one glyph button and give it its accessible name.
##
## The name is a required argument, not a separate call: a Button is named
## from its `text` before its tooltip, every glyph here is a private-use
## codepoint, and a newly added icon button is exactly the kind of site a
## convention loses. The parameter makes the compiler ask for the words.
static func icon_button(btn: Button, accessible_name: String) -> void:
	btn.add_theme_font_override("font", font_resource)
	# The glyph is a heading, not body text: an icon button renders at this size
	# on every chrome surface, and the engine's 16 px default is what it used.
	btn.add_theme_font_size_override("font_size", UiTokens.FS_HEADING)
	btn.accessibility_name = accessible_name

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
