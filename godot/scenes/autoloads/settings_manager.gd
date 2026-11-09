extends BasePersistenceManager

const SETTINGS_FILE = "user://settings.json"

## The window modes, in the order the index means them: the desktop's own frame,
## gPTY's borderless title bar, fullscreen. The stored value is the index, so
## these labels are display-only and an old settings file needs no migration.
const WINDOW_MODE_LABELS := ["System Frame", "Borderless", "Fullscreen"]
## What the window-mode dropdown is, and one sentence per mode saying what it
## draws (`WindowChrome.apply_mode` is what the values actually do).
const WINDOW_MODE_TITLE := "Window Mode"
const WINDOW_MODE_HINT := "System Frame: the desktop draws the window frame and its controls. Borderless: gPTY's own title bar, with no desktop frame. Fullscreen: fills the screen and keeps that title bar."
## The chrome's colour mode: an index into `APPEARANCE_LABELS`.
const APPEARANCE_DARK := 0
const APPEARANCE_LIGHT := 1
const APPEARANCE_SYSTEM := 2
const APPEARANCE_LABELS := ["Dark", "Light", "Follow system"]
## The chrome colour settings that default to a token, keyed by settings key.
## A stored value equal to either set's default has never been customised, so a
## palette switch carries it instead of pinning the surface it was saved from.
const CHROME_COLOR_TOKENS := {
	"wrapper_bg": "BG",
	"title_bar_bg": "SURFACE_RAISED",
	"wrapper_border": "BORDER",
	"sidebar_bg": "SIDEBAR",
	"focus_border": "TERMINAL_FOCUS",
	"selection": "SELECTION",
	"scrollback_indicator": "SCROLLBACK_INDICATOR",
}
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
# The palette is not constant, so these defaults are `apply_appearance()`'s to
# re-derive: they start on the dark set (or whatever is active when the autoload
# is created) and follow the mode until the user picks a colour.
var cfg_wrapper_bg: Color = _chrome_default("wrapper_bg")
var cfg_title_bar_bg: Color = _chrome_default("title_bar_bg")
var cfg_wrapper_border: Color = _chrome_default("wrapper_border")
var cfg_sidebar_bg: Color = _chrome_default("sidebar_bg")
var cfg_focus_border: Color = _chrome_default("focus_border")
var cfg_selection: Color = _chrome_default("selection")
var cfg_scrollback_indicator: Color = _chrome_default("scrollback_indicator")
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
## Which chrome colour set is active: `APPEARANCE_DARK`, `APPEARANCE_LIGHT`, or
## `APPEARANCE_SYSTEM` (the desktop's own preference).
var cfg_appearance_mode := APPEARANCE_DARK

## Emitted when the resolved mode moves — a settings save, or the desktop theme
## flipping while `Follow system` is selected. The workspace rebuilds its Theme
## and re-pushes every colour it owns.
signal appearance_changed(is_dark: bool)

## The desktop's dark-mode answer. A seam, so a test can model a desktop that
## reports light, dark, or nothing at all — a platform or a session without the
## query answers `true`, the app's own default.
var system_is_dark: Callable = func() -> bool:
	return DisplayServer.is_dark_mode() if DisplayServer.is_dark_mode_supported() else true

## -1 until the first `apply_appearance()`, so that call always resolves.
var _applied_appearance := -1

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
	var window := get_window()
	if window != null and not window.size_changed.is_connected(_on_window_resized):
		window.size_changed.connect(_on_window_resized)
	apply_appearance()
	# The desktop theme flip arrives through the engine's message loop; the
	# dispatch is deferred so the palette switch runs on the main thread like
	# every other settings apply.
	if DisplayServer.is_dark_mode_supported():
		DisplayServer.set_system_theme_change_callback(_on_system_theme_changed)

func _on_system_theme_changed() -> void:
	if cfg_appearance_mode == APPEARANCE_SYSTEM:
		apply_appearance.call_deferred()

## Whether the chrome should be dark right now.
func is_dark_appearance() -> bool:
	match cfg_appearance_mode:
		APPEARANCE_LIGHT:
			return false
		APPEARANCE_SYSTEM:
			return bool(system_is_dark.call())
		_:
			return true

## Resolve the mode, select the palette, and carry every uncustomised chrome
## colour to it. Idempotent: the signal fires only when the answer moves, so a
## settings save that did not touch the appearance costs no theme rebuild.
func apply_appearance() -> void:
	var dark := is_dark_appearance()
	UiPalette.use(UiPalette.MODE_DARK if dark else UiPalette.MODE_LIGHT)
	_carry_chrome_defaults()
	if _applied_appearance != -1 and (_applied_appearance == 1) == dark:
		return
	_applied_appearance = 1 if dark else 0
	appearance_changed.emit(dark)

## A chrome colour equal to either set's default has never been chosen by the
## user, so it follows the new set instead of pinning the surface it was loaded
## from (a store written by a light run still switches back to dark).
func _carry_chrome_defaults() -> void:
	for key in CHROME_COLOR_TOKENS:
		var token: String = CHROME_COLOR_TOKENS[key]
		var current: Color = get("cfg_" + key)
		if current == UiPalette.dark().color(token) or current == UiPalette.light().color(token):
			set("cfg_" + key, UiPalette.active().color(token))

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
	cfg_wrapper_bg = _color_from_hex(_as_string(d, "wrapper_bg", ""), _chrome_default("wrapper_bg"))
	cfg_title_bar_bg = _color_from_hex(_as_string(d, "title_bar_bg", ""), _chrome_default("title_bar_bg"))
	cfg_wrapper_border = _color_from_hex(_as_string(d, "wrapper_border", ""), _chrome_default("wrapper_border"))
	cfg_sidebar_bg = _color_from_hex(_as_string(d, "sidebar_bg", ""), _chrome_default("sidebar_bg"))
	cfg_focus_border = _color_from_hex(_as_string(d, "focus_border", ""), _chrome_default("focus_border"))
	cfg_selection = _color_from_hex(_as_string(d, "selection", ""), _chrome_default("selection"))
	cfg_scrollback_indicator = _color_from_hex(_as_string(d, "scrollback_indicator", ""), _chrome_default("scrollback_indicator"))
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
	cfg_appearance_mode = clampi(_as_int(d, "appearance_mode", APPEARANCE_DARK), APPEARANCE_DARK, APPEARANCE_SYSTEM)

func save_settings():
	var d = {"cursor_shape": cfg_cursor_shape, "cursor_blink": cfg_cursor_blink, "cursor_blink_speed": cfg_cursor_blink_speed, "scroll_lines": cfg_scroll_lines, "default_rows": cfg_default_rows, "default_cols": cfg_default_cols, "beam_width": cfg_beam_width, "underline_height": cfg_underline_height, "wrapper_bg": cfg_wrapper_bg.to_html(), "title_bar_bg": cfg_title_bar_bg.to_html(), "wrapper_border": cfg_wrapper_border.to_html(), "sidebar_bg": cfg_sidebar_bg.to_html(), "focus_border": cfg_focus_border.to_html(), "selection": cfg_selection.to_html(), "scrollback_indicator": cfg_scrollback_indicator.to_html(), "color_scheme": cfg_color_scheme_path, "max_fps": cfg_max_fps, "font_path": cfg_font_path, "font_size": cfg_font_size, "shell_command": cfg_shell_command, "shell_env": cfg_shell_env, "show_titlebar": cfg_show_titlebar, "window_mode": cfg_window_mode, "window_position": {"x": cfg_window_position.x, "y": cfg_window_position.y}, "window_size": {"x": cfg_window_size.x, "y": cfg_window_size.y}}
	d["reasoning_max_turns"] = cfg_reasoning_max_turns
	d["reasoning_max_turn_bytes"] = cfg_reasoning_max_turn_bytes
	d["check_updates"] = cfg_check_updates
	d["ui_scale"] = cfg_ui_scale
	d["appearance_mode"] = cfg_appearance_mode
	d["history_lines"] = cfg_history_lines
	_write_file(SETTINGS_FILE, d)
	# The palette follows the setting before anyone hears about the save, so a
	# listener that pushes colours reads the set this file just chose.
	apply_appearance()
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

## `cfg_ui_scale` as a factor: what the user asked for, before the window's cap.
func ui_scale_factor() -> float:
	return float(cfg_ui_scale) / 100.0

## The factor the window actually gets. See `applied_ui_scale_percent`.
func applied_ui_scale_factor() -> float:
	return float(applied_ui_scale_percent()) / 100.0

## `cfg_ui_scale`, capped so the layout space (`window pixels / scale`) never
## falls under `UiTokens.MIN_LAYOUT`: below it the Settings card is clipped and a
## pane title runs under its own buttons. Never under 100 % -- a window already
## smaller than the floor needs the small-window work, not a smaller interface.
## The setting keeps the user's request; the Appearance row prints
## `shown at N %` when this answers below it.
func applied_ui_scale_percent() -> int:
	var w := get_window()
	return capped_ui_scale_percent(cfg_ui_scale, w.size if w != null else Vector2i.ZERO)

## `requested` capped for a `window_size`-pixel window. Static and pure, so the
## rule is testable without a real window.
static func capped_ui_scale_percent(requested: int, window_size: Vector2i) -> int:
	var ceiling := UiTokens.ui_scale_ceiling(window_size)
	if ceiling < 0:
		return requested
	return clampi(requested, 100, maxi(ceiling, 100))

## Push the applied scale at the window.
##
## `content_scale_factor` is what "UI scale" has to mean here: Godot scales the
## whole interface uniformly, layout space shrinking while the pixel grid stays
## put, so hard-coded minimum sizes and margins grow with the type. Multiplying
## each token font size instead would leave every `custom_minimum_size` at its
## old pixel size, which is exactly the clipping a dense display produces. The
## resize this causes is what re-lays the workspace out. A no-change guard keeps
## the `size_changed` the assignment emits from re-entering this function.
func apply_ui_scale() -> void:
	var w := get_window()
	if w == null:
		return
	var factor := applied_ui_scale_factor()
	if is_equal_approx(w.content_scale_factor, factor):
		return
	w.content_scale_factor = factor

## A resize changes what the layout has room for, so the cap moves with it: a
## window dragged smaller steps the scale down and dragging it back restores the
## user's choice.
func _on_window_resized() -> void:
	apply_ui_scale()

## A chrome colour's default from the active palette, by settings key. The field
## initializers and `load_settings`' fallbacks both go through it, so one table
## says which token a setting defaults to and no initializer reads the palette
## directly (which would pin the mode it was created under --
## `scripts/check-theme-tokens`).
static func _chrome_default(key: String) -> Color:
	return UiPalette.active().color(CHROME_COLOR_TOKENS[key])

## A stored `{"x": .., "y": ..}` pair, or `fallback` when it is not one.
func _window_vec(d: Dictionary, key: String, fallback: Vector2i) -> Vector2i:
	var v = _as_dict(d, key, {})
	if v.is_empty():
		return fallback
	return Vector2i(_as_int(v, "x", fallback.x), _as_int(v, "y", fallback.y))

func _color_from_hex(hex: String, fallback: Color) -> Color:
	if hex == "": return fallback
	return Color.from_string(hex, fallback)
