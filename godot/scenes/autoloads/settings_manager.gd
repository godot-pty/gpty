extends BasePersistenceManager

const SETTINGS_FILE = "user://settings.json"

const WRAPPER_BG_COLOR = UiTokens.BG
const TITLE_BAR_BG_COLOR = UiTokens.SURFACE_RAISED
const WRAPPER_BORDER_COLOR = UiTokens.BORDER
const SIDEBAR_BG_COLOR = UiTokens.SIDEBAR
const FOCUS_BORDER_COLOR = UiTokens.TERMINAL_FOCUS
const SELECTION_COLOR = UiTokens.SELECTION
const SCROLLBACK_INDICATOR_COLOR = UiTokens.SCROLLBACK_INDICATOR
const WINDOW_MODE_LABELS := ["OS", "Windowed", "Windowless"]
## The UI-scale steps the Appearance picker offers, in percent. 100 is the
## layout every measurement and screenshot was taken at; the ceiling matches the
## loader's clamp so a stored value cannot exceed what the picker can show.
const UI_SCALE_PRESETS := [100, 110, 125, 150, 175, 200]

var cfg_cursor_shape := 0
var cfg_cursor_blink := true
var cfg_cursor_blink_speed := 0.5
var cfg_scroll_lines := 3
var cfg_history_lines := 10000
var cfg_default_rows := 24
var cfg_default_cols := 80
var cfg_beam_width := 2
var cfg_underline_height := 3
var cfg_wrapper_bg := WRAPPER_BG_COLOR
var cfg_title_bar_bg := TITLE_BAR_BG_COLOR
var cfg_wrapper_border := WRAPPER_BORDER_COLOR
var cfg_sidebar_bg := SIDEBAR_BG_COLOR
var cfg_focus_border := FOCUS_BORDER_COLOR
var cfg_selection := SELECTION_COLOR
var cfg_scrollback_indicator := SCROLLBACK_INDICATOR_COLOR
var cfg_color_scheme_path := ""
var cfg_max_fps := 0
var cfg_font_path := "res://fonts/DejaVuSansMono.ttf"
var cfg_font_size := 14
var cfg_shell_command := default_shell_command()
var cfg_window_mode := 0
var cfg_show_titlebar := true
var cfg_window_position := Vector2i(100, 100)
var cfg_window_size := Vector2i(1920, 1080)
var cfg_shell_env := ""
var cfg_reasoning_max_turns := 16
var cfg_reasoning_max_turn_bytes := 65536
var cfg_check_updates := true
## Percent; the whole interface scales by this against the 100 % layout.
var cfg_ui_scale := 100

## The shell a fresh install opens panes with.
##
## Windows ships no POSIX shell at a predictable path, so a `/bin/bash` default
## there made `GptyTerminal.start_shell` refuse every pane — the path contains a
## separator and is not absolute on Windows, which `validate_executable` rejects
## ("relative executable path") — and the user got a pane that never ran
## anything. `%COMSPEC%` is the interpreter Windows itself would use; the bare
## name is the fallback when it is unset.
static func default_shell_command() -> String:
	if OS.get_name() == "Windows":
		var comspec := OS.get_environment("COMSPEC")
		return comspec if comspec != "" else "cmd.exe"
	return "/bin/bash"

signal settings_changed

func _on_init():
	load_settings()
	apply_ui_scale()

func load_settings():
	var d = _read_file(SETTINGS_FILE)
	if d.is_empty(): return
	# Every key goes through a typed read: the `_cfg_*` variables are typed, and
	# GDScript raises on assigning a wrongly typed JSON value to one, which
	# aborted the loader and silently dropped every key after it (and the next
	# save then wrote the defaults back over the file).
	cfg_cursor_shape = _as_int(d, "cursor_shape", 0)
	cfg_cursor_blink = _as_bool(d, "cursor_blink", true)
	cfg_cursor_blink_speed = _as_float(d, "cursor_blink_speed", 0.5)
	cfg_scroll_lines = _as_int(d, "scroll_lines", 3)
	cfg_history_lines = clampi(_as_int(d, "history_lines", 10000), 100, 100000)
	cfg_default_rows = _as_int(d, "default_rows", 24)
	cfg_default_cols = _as_int(d, "default_cols", 80)
	cfg_beam_width = _as_int(d, "beam_width", 2)
	cfg_underline_height = _as_int(d, "underline_height", 3)
	cfg_wrapper_bg = _color_from_hex(_as_string(d, "wrapper_bg", ""), WRAPPER_BG_COLOR)
	cfg_title_bar_bg = _color_from_hex(_as_string(d, "title_bar_bg", ""), TITLE_BAR_BG_COLOR)
	cfg_wrapper_border = _color_from_hex(_as_string(d, "wrapper_border", ""), WRAPPER_BORDER_COLOR)
	cfg_sidebar_bg = _color_from_hex(_as_string(d, "sidebar_bg", ""), SIDEBAR_BG_COLOR)
	cfg_focus_border = _color_from_hex(_as_string(d, "focus_border", ""), FOCUS_BORDER_COLOR)
	cfg_selection = _color_from_hex(_as_string(d, "selection", ""), SELECTION_COLOR)
	cfg_scrollback_indicator = _color_from_hex(_as_string(d, "scrollback_indicator", ""), SCROLLBACK_INDICATOR_COLOR)
	cfg_color_scheme_path = _as_string(d, "color_scheme", "")
	cfg_max_fps = _as_int(d, "max_fps", 0)
	cfg_window_mode = _as_int(d, "window_mode", 0)
	cfg_show_titlebar = _as_bool(d, "show_titlebar", true)
	cfg_window_position = _window_vec(d, "window_position", Vector2i(100, 100))
	cfg_window_size = _window_vec(d, "window_size", Vector2i(1920, 1080))
	cfg_font_path = _as_string(d, "font_path", "res://fonts/DejaVuSansMono.ttf")
	cfg_font_size = _as_int(d, "font_size", 14)
	cfg_shell_command = _as_string(d, "shell_command", default_shell_command())
	cfg_shell_env = _as_string(d, "shell_env", "")
	cfg_reasoning_max_turns = clampi(_as_int(d, "reasoning_max_turns", 16), 1, 64)
	cfg_reasoning_max_turn_bytes = clampi(_as_int(d, "reasoning_max_turn_bytes", 65536), 4096, 1048576)
	cfg_check_updates = _as_bool(d, "check_updates", true)
	# The floor is 100: the setting exists to make the interface bigger on a
	# dense display, and a stored value below it would lay the UI out smaller
	# than the layout was ever measured at.
	cfg_ui_scale = clampi(_as_int(d, "ui_scale", 100), 100, UI_SCALE_PRESETS.max())

func save_settings():
	var d = {"cursor_shape": cfg_cursor_shape, "cursor_blink": cfg_cursor_blink, "cursor_blink_speed": cfg_cursor_blink_speed, "scroll_lines": cfg_scroll_lines, "default_rows": cfg_default_rows, "default_cols": cfg_default_cols, "beam_width": cfg_beam_width, "underline_height": cfg_underline_height, "wrapper_bg": cfg_wrapper_bg.to_html(), "title_bar_bg": cfg_title_bar_bg.to_html(), "wrapper_border": cfg_wrapper_border.to_html(), "sidebar_bg": cfg_sidebar_bg.to_html(), "focus_border": cfg_focus_border.to_html(), "selection": cfg_selection.to_html(), "scrollback_indicator": cfg_scrollback_indicator.to_html(), "color_scheme": cfg_color_scheme_path, "max_fps": cfg_max_fps, "font_path": cfg_font_path, "font_size": cfg_font_size, "shell_command": cfg_shell_command, "shell_env": cfg_shell_env, "show_titlebar": cfg_show_titlebar, "window_mode": cfg_window_mode, "window_position": {"x": cfg_window_position.x, "y": cfg_window_position.y}, "window_size": {"x": cfg_window_size.x, "y": cfg_window_size.y}}
	d["reasoning_max_turns"] = cfg_reasoning_max_turns
	d["reasoning_max_turn_bytes"] = cfg_reasoning_max_turn_bytes
	d["check_updates"] = cfg_check_updates
	d["ui_scale"] = cfg_ui_scale
	d["history_lines"] = cfg_history_lines
	_write_file(SETTINGS_FILE, d)
	settings_changed.emit()

func apply_to_terminal(body: Control):
	body.apply_settings({
		"cursor_shape": cfg_cursor_shape,
		"cursor_blink": cfg_cursor_blink,
		"cursor_blink_speed": cfg_cursor_blink_speed,
		"scroll_lines": cfg_scroll_lines,
		"beam_cursor_width": cfg_beam_width,
		"underline_cursor_height": cfg_underline_height,
		"focus_border_color": cfg_focus_border,
		"selection_color": cfg_selection,
		"scrollback_indicator_color": cfg_scrollback_indicator,
		"color_scheme_path": cfg_color_scheme_path,
		"font_path": cfg_font_path,
		"font_size": cfg_font_size,
		"max_fps": cfg_max_fps,
		"shell_command": cfg_shell_command,
		"shell_env": cfg_shell_env,
	})

func apply_pane_settings(body: Control, settings: Dictionary):
	body.apply_settings(settings)

## The window's content scale, as a multiplier.
func ui_scale_factor() -> float:
	return float(cfg_ui_scale) / 100.0

## Push `cfg_ui_scale` at the window.
##
## `content_scale_factor` is what "UI scale" has to mean here: Godot scales the
## whole interface uniformly, layout space shrinking while the pixel grid stays
## put, so hard-coded minimum sizes and margins grow with the type. Multiplying
## each token font size instead would leave every `custom_minimum_size` at its
## old pixel size, which is exactly the clipping a dense display produces. The
## resize this causes is what re-lays the workspace out.
func apply_ui_scale() -> void:
	var w := get_window()
	if w != null:
		w.content_scale_factor = ui_scale_factor()

## A stored `{"x": .., "y": ..}` pair, or `fallback` when it is not one.
func _window_vec(d: Dictionary, key: String, fallback: Vector2i) -> Vector2i:
	var v = _as_dict(d, key, {})
	if v.is_empty():
		return fallback
	return Vector2i(_as_int(v, "x", fallback.x), _as_int(v, "y", fallback.y))

func _color_from_hex(hex: String, fallback: Color) -> Color:
	if hex == "": return fallback
	return Color.from_string(hex, fallback)
