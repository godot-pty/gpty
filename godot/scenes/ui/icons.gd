class_name Icons

# All icons sourced from Phosphor Regular (MIT). Codepoints are BMP PUA (U+E000-U+F8FF).

const font_resource := preload("res://assets/fonts/Phosphor-Regular.ttf")

static func style_button(btn: Button) -> void:
	btn.add_theme_font_override("font", font_resource)

const CLOSE    = "\uE4F6"  # x
const DELETE   = "\uE4A6"  # trash
const MINIMIZE = "\uE32A"  # minus
const RESTORE  = "\uE0A2"  # arrows-out
const COLLAPSE = "\uE138"  # caret-left
const EXPAND   = "\uE13A"  # caret-right
const ADD      = "\uE3D4"  # plus
const SETTINGS = "\uE272"  # gear-six
const RESET    = "\uE038"  # arrow-counter-clockwise
const SWAP     = "\uE0A0"  # arrows-left-right
const POSITION_SWAP = "\uE1E9"  # shuffle
const MAXIMIZE_WIN = "\uE3C8"  # arrows-out (maximize to fullscreen)
const RESTORE_WIN = "\uE3C6"  # arrows-in (restore from fullscreen)
const WINDOW_MODE = "\uE24A"  # monitor (window mode cycling)
