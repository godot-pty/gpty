extends PaneBody
class_name TerminalPane
# gpty Terminal Pane — Control-based node for focus + rendering.

const CURSOR_BLINK_INTERVAL = 0.5
const SCROLL_LINES = 3
@export var scroll_lines: int = SCROLL_LINES
const PADDING = 4
const FOCUS_BORDER_COLOR = Color(0.4, 0.7, 1.0, 0.3)
const FOCUS_BORDER_WIDTH = 2.0
const SELECTION_COLOR = Color(0.3, 0.5, 1.0, 0.4)
const SCROLLBACK_INDICATOR_COLOR = Color.YELLOW
const BEAM_CURSOR_WIDTH = 2
const UNDERLINE_CURSOR_HEIGHT = 3
const PRINTABLE_ASCII_MIN = 32
const SEARCH_HIGHLIGHT_COLOR = Color(1.0, 0.8, 0.0, 0.35)
const SEARCH_ACTIVE_COLOR = Color(1.0, 0.5, 0.0, 0.5)
const PRINTABLE_ASCII_MAX = 126

@export var beam_cursor_width: int = BEAM_CURSOR_WIDTH
@export var underline_cursor_height: int = UNDERLINE_CURSOR_HEIGHT
@export var focus_border_color: Color = FOCUS_BORDER_COLOR
@export var selection_color: Color = SELECTION_COLOR
@export var scrollback_indicator_color: Color = SCROLLBACK_INDICATOR_COLOR
var color_scheme_path: String = "":
	set(value):
		color_scheme_path = value
		if _terminal != null:
			_apply_stored_scheme()



@export var shell_command: String = "/bin/bash"
@export var shell_env := ""
@export var rows: int = 24
@export var cols: int = 80

@export var font_path: String = "res://fonts/DejaVuSansMono.ttf":
	set(value):
		font_path = value
		if _font != null:
			_reload_fonts()
			_recompute_cell_metrics()
@export var font_bold_path: String = "res://fonts/DejaVuSansMono-Bold.ttf"
@export var font_italic_path: String = "res://fonts/DejaVuSansMono-Oblique.ttf"

@export var cursor_shape: int = 0
@export var cursor_color: Color = Color(0.8, 0.8, 0.8, 0.7)
@export var cursor_blink: bool = true
@export var cursor_blink_speed: float = CURSOR_BLINK_INTERVAL

@export var default_fg: Color = Color(0.8, 0.8, 0.8)
@export var default_bg: Color = Color(0.12, 0.12, 0.12)

@export var max_fps: int = 0:
	set(value):
		max_fps = value
		var target = float(max_fps) if max_fps > 0 else (DisplayServer.screen_get_refresh_rate() if DisplayServer.screen_get_refresh_rate() > 0 else 60.0)
		_sync_interval = 1.0 / target

var _terminal: GptyTerminal
var _font_bold: Font
var _font_italic: Font
var _cell_cache: Dictionary = {}
var _cell_w: float = 0.0
var _cell_h: float = 0.0
var _cursor_blink_timer: float = 0.0
var _cursor_visible: bool = true
var _last_title: String = ""
var _selecting: bool = false
var _sel_start: Vector2i = Vector2i(-1, -1)
var _sel_end: Vector2i = Vector2i(-1, -1)
var _last_grid_gen: int = -1
var _fetch_ms: int = 0
var _draw_ms: int = 0

var _resize_pending: bool = false
var _resize_timer: float = 0.0
const RESIZE_DEBOUNCE = 0.05
var _time_since_sync: float = 0.0
var _search_bar: LineEdit
var _search_visible: bool = false
var _search_results: Dictionary = {}  # {count, rows: Array, cols: Array, current: int}
var _search_error: String = ""
var _sync_interval: float = 1.0 / 60.0

func _ready():
	super._ready()
	_terminal = GptyTerminal.new()
	_terminal.name = "GptyTerminal"
	add_child(_terminal)
	_terminal.start_shell(shell_command, rows, cols, shell_env)

	if color_scheme_path != "":
		_apply_stored_scheme()

	_font = _load_font(font_path, "res://fonts/DejaVuSansMono.ttf")
	_font_bold = _load_font(font_bold_path, "res://fonts/DejaVuSansMono-Bold.ttf")
	_font_italic = _load_font(font_italic_path, "res://fonts/DejaVuSansMono-Oblique.ttf")

	_recompute_cell_metrics()

	focus_mode = Control.FOCUS_CLICK
	clip_contents = true

	# Search bar (hidden by default)
	_search_bar = LineEdit.new()
	_search_bar.name = "SearchBar"
	_search_bar.placeholder_text = "Search (regex)..."
	_search_bar.visible = false
	_search_bar.anchor_left = 0.0; _search_bar.anchor_right = 1.0
	_search_bar.anchor_bottom = 1.0; _search_bar.offset_bottom = 0
	_search_bar.offset_top = -36
	_search_bar.text_changed.connect(_on_search_text_changed)
	_search_bar.text_submitted.connect(_on_search_submitted)
	_search_bar.gui_input.connect(_on_search_bar_input)
	add_child(_search_bar)

func _on_resize():
	if _terminal == null or _cell_w == 0: return
	var new_cols = maxi(int((size.x - PADDING) / _cell_w), 1)
	var new_rows = maxi(int((size.y - PADDING) / _cell_h), 1)
	if new_cols != cols or new_rows != rows:
		cols = new_cols; rows = new_rows
		_resize_pending = true
		_resize_timer = 0.0

func _notification(what):
	if what == NOTIFICATION_RESIZED: _on_resize()

func _get_layout_state() -> Dictionary:
	var state = super._get_layout_state()
	state.merge({
		"shell": shell_command, "rows": rows, "cols": cols,
		"shell_env": shell_env, "font_path": font_path,
		"color_scheme_path": color_scheme_path,
		"cursor_shape": cursor_shape, "cursor_blink": cursor_blink,
		"cursor_blink_speed": cursor_blink_speed, "cursor_color": cursor_color,
		"scroll_lines": scroll_lines, "max_fps": max_fps,
		"default_fg": default_fg, "default_bg": default_bg,
		"beam_cursor_width": beam_cursor_width,
		"underline_cursor_height": underline_cursor_height,
	})
	return state

func apply_settings(settings: Dictionary):
	# Restore serialized Color values from JSON round-trips.
	# Layout JSON stores Colors as "(r, g, b, a)" strings.
	_restore_color_strings(settings)
	super.apply_settings(settings)
	if settings.has("rows") or settings.has("cols"):
		if _terminal != null:
			_terminal.resize_grid(rows, cols)

func _restore_color_strings(dict: Dictionary):
	for key in ["default_fg", "default_bg", "cursor_color", "focus_border_color", "selection_color", "scrollback_indicator_color"]:
		var v = dict.get(key)
		if not (v is String): continue
		var s: String = v.strip_edges()
		# Format from JSON: "(r, g, b, a)" — strip parens, parse floats
		if s.begins_with("(") and s.ends_with(")"):
			s = s.substr(1, s.length() - 2)
		var parts = s.split(",", false)
		if parts.size() >= 3:
			dict[key] = Color(float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]) if parts.size() > 3 else 1.0)
func _reload_fonts():
	_font = _load_font(font_path, "res://fonts/DejaVuSansMono.ttf")
	_font_bold = _load_font(font_bold_path, "res://fonts/DejaVuSansMono-Bold.ttf")
	_font_italic = _load_font(font_italic_path, "res://fonts/DejaVuSansMono-Oblique.ttf")

func _apply_stored_scheme():
	if _terminal == null: return
	var path = color_scheme_path
	if path == "" or not FileAccess.file_exists(path):
		_terminal.set_palette("")
		return
	var f = FileAccess.open(path, FileAccess.READ)
	if not f: return
	var hex_csv = f.get_as_text().strip_edges().replace("\n", ",").replace(" ", "")
	_terminal.set_palette(hex_csv)

func _load_font(path: String, fallback: String) -> Font:
	var f: Font
	if path != "" and ResourceLoader.exists(path): f = load(path)
	else: f = load(fallback)
	f.fixed_size = font_size
	return f

func _recompute_cell_metrics():
	_font.fixed_size = font_size
	_font_bold.fixed_size = font_size
	_font_italic.fixed_size = font_size
	_cell_w = _font.get_char_size('W'.unicode_at(0), font_size).x
	_cell_h = _font.get_height(font_size)
	custom_minimum_size = Vector2(PADDING * _cell_w + PADDING, _cell_h * 2 + PADDING)

func _process(delta):
	if cursor_blink:
		_cursor_blink_timer += delta
		if _cursor_blink_timer > cursor_blink_speed:
			_cursor_blink_timer = 0.0
			_cursor_visible = not _cursor_visible
			_request_cursor_redraw()
	else:
		_cursor_visible = true

	if _resize_pending:
		_resize_timer += delta
		if _resize_timer >= RESIZE_DEBOUNCE:
			_resize_pending = false
			_terminal.resize_grid(rows, cols)

	_time_since_sync += delta
	if _time_since_sync >= _sync_interval:
		_time_since_sync = 0.0
		var gen = _terminal.get_grid_generation()
		if gen != _last_grid_gen:
			_last_grid_gen = gen
			var t0 = Time.get_ticks_msec()
			# Damage tracking: fetch only modified cells unless the cache is empty (force full pack)
			var updates = _terminal.get_grid_updates_packed(_cell_cache.is_empty())
			if updates.get("is_full", true):
				# Full grid sync (e.g. initial load, resize, or massive scroll)
				_cell_cache = updates
			else:
				# Partial sync: incrementally merge damaged cells into existing arrays
				var indices: PackedInt32Array = updates["indices"]
				var chars: Array = updates["chars"]
				var fg: PackedColorArray = updates["fg"]
				var bg: PackedColorArray = updates["bg"]
				var attrs: PackedInt32Array = updates["attrs"]
				var grid_cols: int = _cell_cache["cols"]
				var cc_chars: Array = _cell_cache["chars"]
				var cc_fg: PackedColorArray = _cell_cache["fg"]
				var cc_bg: PackedColorArray = _cell_cache["bg"]
				var cc_attrs: PackedInt32Array = _cell_cache["attrs"]
				for i in indices.size():
					var idx: int = indices[i]
					var r: int = int(idx / float(grid_cols))
					var c: int = idx % grid_cols
					var old_str: String = cc_chars[r]
					# Update the packed strings natively (bypasses full array recreation)
					cc_chars[r] = old_str.substr(0, c) + chars[i] + old_str.substr(c + 1)
					cc_fg[idx] = fg[i]
					cc_bg[idx] = bg[i]
					cc_attrs[idx] = attrs[i]
			_fetch_ms = Time.get_ticks_msec() - t0
			_cursor_visible = true
			_cursor_blink_timer = 0.0
		queue_redraw()
	_draw_ms = 0  # will be set on next _draw() call
	var t = _terminal.get_title()
	if t != _last_title and t != "":
		_last_title = t
		var display_title = pane_name if pane_name != "" else t
		title_changed.emit(display_title)

func _request_cursor_redraw() -> void:
	queue_redraw()

func _grid_offset() -> Vector2:
	var gc: int = _cell_cache["cols"]
	var gr: int = _cell_cache["rows"]
	var tw = gc * _cell_w; var th = gr * _cell_h
	return Vector2(2 + maxf((size.x - PADDING - tw) / 2.0, 0), 2 + maxf((size.y - PADDING - th) / 2.0, 0))

func _draw():
	var t0 = Time.get_ticks_msec()
	if _cell_cache.is_empty() or _cell_cache.get("rows", 0) == 0:
		_draw_ms = Time.get_ticks_msec() - t0
		return

	var off = _grid_offset()
	var baseline = _font.get_ascent(font_size)

	draw_rect(Rect2(Vector2.ZERO, size), default_bg)
	_draw_cells(off, baseline)

	# Focus border
	if has_focus():
		draw_rect(Rect2(0, 0, size.x, size.y), focus_border_color, false, FOCUS_BORDER_WIDTH)

	# Cursor
	if _cursor_visible:
		_draw_cursor(off, baseline)

	# Scrollback indicator
	var so = _terminal.get_scroll_offset()
	if so > 0:
		draw_string(_font, Vector2(off.x + _cell_w * 0.5, off.y + _cell_h * 0.5),
			"[Scroll: %d/%d lines]" % [so, _terminal.get_history_size()],
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, scrollback_indicator_color)

	# Selection
	if _sel_start.x >= 0 and _sel_end.x >= 0:
		_draw_selection(off)

	# Search highlights
	_draw_search_highlights(off)
	_draw_ms = Time.get_ticks_msec() - t0

func _draw_cells(off: Vector2, baseline: float):
	var grid: Dictionary = _cell_cache
	if grid.is_empty(): return
	var n_rows: int = grid["rows"]; var n_cols: int = grid["cols"]
	var chars: Array = grid["chars"]
	var fg_arr: PackedColorArray = grid["fg"]; var bg_arr: PackedColorArray = grid["bg"]
	var attrs: PackedInt32Array = grid["attrs"]

	# ── Step C: Batched backgrounds ──
	# Collapse ~n_rows×n_cols draw_rect calls into ~50 by merging
	# consecutive cells with the same background color.
	for r in n_rows:
		var c: int = 0
		while c < n_cols:
			var idx: int = r * n_cols + c
			var bg: Color = bg_arr[idx] as Color
			var start_c: int = c
			c += 1
			while c < n_cols:
				var next_bg: Color = bg_arr[r * n_cols + c] as Color
				if next_bg != bg: break
				c += 1
			# One rect for the entire run of same-background cells
			draw_rect(Rect2(off.x + start_c * _cell_w, off.y + r * _cell_h, (c - start_c) * _cell_w, _cell_h), bg)

	# ── Full text + underline pass ──
	var skip_next = false
	for r in n_rows:
		skip_next = false
		for c in n_cols:
			if skip_next:
				skip_next = false
				continue
			var idx = r * n_cols + c
			var ch: String = chars[r][c]
			var fg: Color = fg_arr[idx] as Color
			var a: int = attrs[idx]
			if a & 16 != 0: skip_next = true
			if a & 8 != 0: var _tmp = fg; fg = bg_arr[idx] as Color

			if ch != " " and ch != "":
				var uf = _font
				if a & 1 != 0: uf = _font_bold
				if a & 2 != 0: uf = _font_italic
				draw_string(uf, Vector2(off.x + c * _cell_w, off.y + r * _cell_h + baseline), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, fg)

			if a & 4 != 0:  # underline
				draw_line(Vector2(off.x + c * _cell_w, off.y + r * _cell_h + baseline + 2), Vector2(off.x + (c + 1) * _cell_w, off.y + r * _cell_h + baseline + 2), fg, 1.0)
func _draw_cursor(off: Vector2, baseline: float):
	var cr = _terminal.get_cursor_row(); var cc = _terminal.get_cursor_col()
	if cr < 0 or cc < 0: return
	var cx = off.x + cc * _cell_w; var cy = off.y + cr * _cell_h
	var cursor_ch = ""
	if cr < _cell_cache.get("rows", 0) and cc < _cell_cache.get("cols", 0):
		var chars: Array = _cell_cache["chars"]
		cursor_ch = chars[cr][cc]

	match cursor_shape:
		0:
			draw_rect(Rect2(cx, cy, _cell_w, _cell_h), cursor_color)
			if cursor_ch != " " and cursor_ch != "":
				draw_string(_font, Vector2(cx, cy + baseline), cursor_ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.BLACK)
		1:
			draw_rect(Rect2(cx, cy + _cell_h - underline_cursor_height, _cell_w, underline_cursor_height), cursor_color)
		2:
			draw_rect(Rect2(cx, cy, beam_cursor_width, _cell_h), cursor_color)
		_:
			draw_rect(Rect2(cx, cy, _cell_w, _cell_h), cursor_color)
			if cursor_ch != " " and cursor_ch != "":
				draw_string(_font, Vector2(cx, cy + baseline), cursor_ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.BLACK)

func _draw_selection(off: Vector2):
	var p0 = _sel_start; var p1 = _sel_end
	if p1.y < p0.y or (p1.y == p0.y and p1.x < p0.x):
		p0 = _sel_end; p1 = _sel_start
	var sr0 = p0.y; var sr1 = p1.y
	for r in range(sr0, sr1 + 1):
		var gcols: int = _cell_cache["cols"]; var grows: int = _cell_cache["rows"]
		if r < 0 or r >= grows: continue
		var cb = p0.x if r == sr0 else 0
		var ce = (p1.x if r == sr1 else gcols - 1) + 1
		for c in range(cb, ce):
			if c >= 0 and c < gcols:
				draw_rect(Rect2(off.x + c * _cell_w, off.y + r * _cell_h, _cell_w, _cell_h), selection_color)


func _get_selected_text() -> String:
	if _sel_start.x < 0 or _sel_end.x < 0 or _cell_cache.is_empty(): return ""
	var p0 = _sel_start; var p1 = _sel_end
	if p1.y < p0.y or (p1.y == p0.y and p1.x < p0.x):
		p0 = _sel_end; p1 = _sel_start
	var sr0 = p0.y; var sr1 = p1.y
	var lines: Array[String] = []
	for r in range(sr0, sr1 + 1):
		var gcols: int = _cell_cache["cols"]; var grows: int = _cell_cache["rows"]
		if r < 0 or r >= grows: continue
		var chars: Array = _cell_cache["chars"]
		var cb = maxi(0, p0.x if r == sr0 else 0)
		var ce = mini(gcols - 1, p1.x if r == sr1 else gcols - 1)
		var line = ""
		for c in range(cb, ce + 1):
			line += chars[r][c]
		lines.append(line.rstrip(" "))
	return "\n".join(lines)

func _gui_input(event):
	if event is InputEventKey and ShortcutManager.is_shortcut(event) and not _is_copy_paste(event):
		return
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		_handle_mouse(event)
	elif event is InputEventKey and event.pressed:
		_handle_keyboard(event)

func _handle_mouse(event: InputEvent):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if event.ctrl_pressed:
					_check_click_concept(event.position)
					accept_event(); return
				grab_focus(); _selecting = true
				_sel_start = _mouse_to_cell(event.position); _sel_end = _sel_start; queue_redraw()
			else: _selecting = false; queue_redraw()
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed: _terminal.scroll_up(scroll_lines)
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed: _terminal.scroll_down(scroll_lines)
	if event is InputEventMouseMotion and _selecting:
		_sel_end = _mouse_to_cell(event.position); queue_redraw()

func _is_copy_paste(event: InputEventKey) -> bool:
	return (event.keycode == KEY_C or event.keycode == KEY_V) and event.ctrl_pressed and event.shift_pressed

func _get_clipboard_text() -> String:
	return DisplayServer.clipboard_get()

func _clear_selection():
	_sel_start = Vector2i(-1, -1)
	_sel_end = Vector2i(-1, -1)
	queue_redraw()

func _send_to_term(text: String):
	_terminal.send_text(text)

func _send_line_to_term(text: String):
	_terminal.send_line(text)
func _handle_keyboard(event: InputEventKey):
	# Search bar escape — close search
	if _search_visible and event.keycode == KEY_ESCAPE:
		_close_search()
		accept_event(); return
	# Ctrl+F toggles search bar
	if event.keycode == KEY_F and event.ctrl_pressed:
		_toggle_search()
		accept_event(); return
	if event.keycode == KEY_C and event.ctrl_pressed and event.shift_pressed:
		# Copy-only: always consume the event so it can never fall through
		# to a workspace shortcut. No selection → silent no-op.
		var st = _get_selected_text()
		if st != "":
			DisplayServer.clipboard_set(st)
		_clear_selection()
		accept_event()
		return
	if event.keycode == KEY_V and event.ctrl_pressed and event.shift_pressed:
		var cl = _get_clipboard_text()
		if cl != "": _send_to_term(cl)
		accept_event(); return

	if event.keycode == KEY_PAGEUP: _terminal.scroll_up(rows); accept_event(); return
	if event.keycode == KEY_PAGEDOWN: _terminal.scroll_down(rows); accept_event(); return
	if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
		_clear_selection()
		_send_line_to_term(""); _terminal.scroll_reset(); accept_event(); return
	_terminal.scroll_reset()
	# Try Rust keymap first (arrows, F-keys, Home, End, etc.)
	var bytes = _terminal.key_to_bytes(event.keycode, event.shift_pressed, event.alt_pressed, event.ctrl_pressed, event.meta_pressed)
	if bytes.size() > 0:
		_clear_selection()
		_send_to_term(bytes.get_string_from_ascii())
		accept_event(); return
	# Fall back to unicode + Ctrl+letter path
	var tx = _key_to_text(event)
	if tx != "":
		_clear_selection()
		if event.alt_pressed and not event.ctrl_pressed:
			tx = char(0x1b) + tx
		_send_to_term(tx)
	accept_event()

func _mouse_to_cell(pos: Vector2) -> Vector2i:
	var off = _grid_offset()
	return Vector2i(int((pos.x - off.x) / _cell_w), int((pos.y - off.y) / _cell_h))

func _key_to_text(event: InputEventKey) -> String:
	# Ctrl+letter → ASCII control character
	if event.ctrl_pressed and event.keycode >= KEY_A and event.keycode <= KEY_Z:
		return char(event.keycode - KEY_A + 1)
	# Printable unicode (handled by keymap if it was a special key)
	if event.unicode >= 32 and event.unicode != 127:
		return char(event.unicode)
	return ""
func _on_search_bar_input(event):
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_close_search()
		_search_bar.accept_event()
		return

func _toggle_search():
	_search_visible = not _search_visible
	_search_bar.visible = _search_visible
	if _search_visible:
		_search_bar.grab_focus()
		_search_bar.select_all()
	else:
		_search_results.clear()
		_search_error = ""
		queue_redraw()

func _close_search():
	_search_visible = false
	_search_bar.visible = false
	_search_results.clear()
	_search_error = ""
	queue_redraw()
	grab_focus()

func _on_search_text_changed(new_text: String):
	_do_search(new_text)

func _on_search_submitted(_new_text: String):
	if _search_results.get("count", 0) > 0:
		_jump_to_match(1)  # next match

func _do_search(pattern: String):
	if pattern == "":
		_search_results.clear()
		_search_error = ""
		queue_redraw()
		return
	var result = _terminal.search_grid(pattern)
	if result.has("error"):
		_search_error = result["error"]
		_search_results.clear()
	else:
		_search_error = ""
		_search_results = result
		_search_results["current"] = -1
	queue_redraw()

func _jump_to_match(direction: int):
	var count: int = _search_results.get("count", 0)
	if count == 0: return
	var rows_arr: Array = _search_results["rows"]
	var current: int = _search_results.get("current", -1)
	current = (current + direction) % count
	if current < 0: current = count - 1
	_search_results["current"] = current

	# Scroll to center the matched line in the viewport
	var match_row: int = rows_arr[current]
	var history: int = _terminal.get_history_size()
	var target_offset: int = clampi(history - match_row + int(rows / 2.0), 0, history)
	var cur_offset: int = _terminal.get_scroll_offset()
	var delta: int = target_offset - cur_offset
	if delta > 0:
		_terminal.scroll_up(delta)
	elif delta < 0:
		_terminal.scroll_down(-delta)
	queue_redraw()

func _draw_search_highlights(off: Vector2):
	if _search_results.is_empty(): return
	var count: int = _search_results.get("count", 0)
	if count == 0: return
	var rows_arr: Array = _search_results["rows"]
	var cols_arr: Array = _search_results["cols"]
	var current: int = _search_results.get("current", -1)
	var history: int = _terminal.get_history_size()
	var display_offset: int = _terminal.get_scroll_offset()
	var n_cols: int = _cell_cache.get("cols", 0)

	for i in count:
		var match_row: int = rows_arr[i]
		# Convert from scrollback-relative to display-relative
		# match_row=0 means top of scrollback = Line(-history)
		# Display top = Line(-display_offset)
		var display_row: int = match_row - (history - display_offset)
		if display_row < 0 or display_row >= rows: continue
		var match_col: int = cols_arr[i]
		if match_col < 0 or match_col >= n_cols: continue
		var color = SEARCH_ACTIVE_COLOR if i == current else SEARCH_HIGHLIGHT_COLOR
		draw_rect(Rect2(off.x + match_col * _cell_w, off.y + display_row * _cell_h, _cell_w, _cell_h), color)

# ── Clickable concepts ────────────────────────────────────────────────

func _check_click_concept(pos: Vector2):
	var cell = _mouse_to_cell(pos)
	var r = cell.y; var c = cell.x
	if r < 0 or c < 0: return
	var chars: Array = _cell_cache.get("chars", [])
	if r >= chars.size(): return
	var row_str: String = chars[r]
	if c >= row_str.length(): return
	# Trim trailing spaces to get the meaningful text
	var line = row_str.strip_edges(false, true)
	if line == "": return
	# Match against the Rust engine's compiled regexes (Rust regex only —
	# no PCRE backtracking). Values are shell-quoted by the engine.
	var hits = _terminal.match_concepts_on_line(line)
	for hit in hits:
		var cmd: String = hit.get("cmd", "")
		if cmd != "":
			_send_line_to_term(cmd)
			return

func _pane_type() -> String:
	return "terminal"

func _default_title() -> String:
	return shell_command.get_file() if shell_command else "terminal"

func _build_pane_settings_ui(panel: Control) -> Control:
	var v = VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)

	# ── Shared pane controls ──
	var name_le = LineEdit.new()
	name_le.text = pane_name
	name_le.placeholder_text = _default_title()
	_make_row(v, "Name:", name_le, panel)

	var font_spin = SpinBox.new()
	font_spin.min_value = 8; font_spin.max_value = 32
	font_spin.value = font_size
	_make_row(v, "Font size:", font_spin, panel)

	v.add_child(HSeparator.new())

	# ── Shell ──
	var env_te = TextEdit.new()
	env_te.text = shell_env
	env_te.placeholder_text = "KEY=value (one per line)"
	env_te.custom_minimum_size = Vector2(0, 60)
	env_te.add_theme_font_size_override("font_size", 11)
	env_te.text_changed.connect(func(): panel._debounce_timer.start())
	var env_lbl = Label.new()
	env_lbl.text = "Environment:"
	env_lbl.add_theme_font_size_override("font_size", 12)
	v.add_child(env_lbl)
	v.add_child(env_te)

	v.add_child(HSeparator.new())

	# ── Cursor ──
	var cursor_shape_opt = OptionButton.new()
	cursor_shape_opt.add_item("Block (\u2588)")
	cursor_shape_opt.add_item("Underline (_)")
	cursor_shape_opt.add_item("Beam (|)")
	cursor_shape_opt.selected = cursor_shape
	_make_row(v, "Cursor:", cursor_shape_opt, panel)

	var cursor_blink_cb = CheckBox.new()
	cursor_blink_cb.text = "Cursor blink"
	cursor_blink_cb.button_pressed = cursor_blink
	cursor_blink_cb.toggled.connect(func(_p): panel._debounce_timer.start())
	v.add_child(cursor_blink_cb)

	var blink_spin = SpinBox.new()
	blink_spin.min_value = 0.1; blink_spin.max_value = 2.0
	blink_spin.step = 0.1; blink_spin.value = cursor_blink_speed
	_make_row(v, "Blink speed:", blink_spin, panel)

	var cursor_color_btn = ColorPickerButton.new()
	cursor_color_btn.color = cursor_color
	_make_row(v, "Cursor color:", cursor_color_btn, panel)

	var beam_spin = SpinBox.new()
	beam_spin.min_value = 1; beam_spin.max_value = 8
	beam_spin.value = beam_cursor_width
	_make_row(v, "Beam width:", beam_spin, panel)

	var uline_spin = SpinBox.new()
	uline_spin.min_value = 1; uline_spin.max_value = 8
	uline_spin.value = underline_cursor_height
	_make_row(v, "Underline height:", uline_spin, panel)

	v.add_child(HSeparator.new())

	# ── Grid ──
	var rows_spin = SpinBox.new()
	rows_spin.min_value = 10; rows_spin.max_value = 100
	rows_spin.value = rows
	_make_row(v, "Rows:", rows_spin, panel)

	var cols_spin = SpinBox.new()
	cols_spin.min_value = 40; cols_spin.max_value = 200
	cols_spin.value = cols
	_make_row(v, "Cols:", cols_spin, panel)

	var scroll_spin = SpinBox.new()
	scroll_spin.min_value = 1; scroll_spin.max_value = 10
	scroll_spin.value = scroll_lines
	_make_row(v, "Scroll lines:", scroll_spin, panel)

	v.add_child(HSeparator.new())

	# ── Appearance ──
	var fg_btn = ColorPickerButton.new()
	fg_btn.color = default_fg
	_make_row(v, "Default FG:", fg_btn, panel)

	var bg_btn = ColorPickerButton.new()
	bg_btn.color = default_bg
	_make_row(v, "Default BG:", bg_btn, panel)

	# Font path picker — stored as metadata to avoid closure capture issues
	var font_btn = Button.new()
	font_btn.text = font_path.get_file()
	font_btn.set_meta("path", font_path)
	font_btn.clip_text = true
	font_btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	font_btn.pressed.connect(func():
		var dlg = FileDialog.new()
		dlg.access = FileDialog.ACCESS_FILESYSTEM
		dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		dlg.current_path = font_btn.get_meta("path", "")
		dlg.add_filter("*.ttf", "TrueType Fonts")
		dlg.file_selected.connect(func(path: String):
			font_btn.set_meta("path", path)
			font_btn.text = path.get_file()
			panel._debounce_timer.start()
			dlg.queue_free())
		dlg.canceled.connect(dlg.queue_free)
		panel.add_child(dlg)
		dlg.popup_centered())
	_make_row(v, "Font:", font_btn, panel)

	# Color scheme picker — stored as metadata to avoid closure capture issues
	var scheme_btn = Button.new()
	scheme_btn.text = color_scheme_path.get_file() if color_scheme_path != "" else "(none)"
	scheme_btn.set_meta("path", color_scheme_path)
	scheme_btn.clip_text = true
	scheme_btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	scheme_btn.pressed.connect(func():
		var dlg = FileDialog.new()
		dlg.access = FileDialog.ACCESS_FILESYSTEM
		dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		dlg.current_path = scheme_btn.get_meta("path", "")
		dlg.add_filter("*.txt; *.json; *.csv", "Scheme files")
		dlg.file_selected.connect(func(path: String):
			scheme_btn.set_meta("path", path)
			scheme_btn.text = path.get_file()
			panel._debounce_timer.start()
			dlg.queue_free())
		dlg.canceled.connect(dlg.queue_free)
		panel.add_child(dlg)
		dlg.popup_centered())
	_make_row(v, "Color scheme:", scheme_btn, panel)

	# ── Gather func ──
	panel._gather_func = func():
		return {
			"pane_name": name_le.text.strip_edges(),
			"font_size": int(font_spin.value),
			"shell_env": env_te.text,
			"cursor_shape": cursor_shape_opt.selected,
			"cursor_blink": cursor_blink_cb.button_pressed,
			"cursor_blink_speed": blink_spin.value,
			"cursor_color": cursor_color_btn.color,
			"beam_cursor_width": int(beam_spin.value),
			"underline_cursor_height": int(uline_spin.value),
			"rows": int(rows_spin.value),
			"cols": int(cols_spin.value),
			"scroll_lines": int(scroll_spin.value),
			"default_fg": fg_btn.color,
			"default_bg": bg_btn.color,
			"font_path": font_btn.get_meta("path", ""),
			"color_scheme_path": scheme_btn.get_meta("path", ""),
		}

	return v

func _make_row(parent: VBoxContainer, label: String, control: Control, panel: Control):
	var hb = HBoxContainer.new()
	var lbl = Label.new(); lbl.text = label
	lbl.add_theme_font_size_override("font_size", 12)
	hb.add_child(lbl)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(control)
	parent.add_child(hb)
	if control is SpinBox:
		control.value_changed.connect(func(_v: float): panel._debounce_timer.start())
	elif control is LineEdit:
		control.text_changed.connect(func(_s: String): panel._debounce_timer.start())
	elif control is OptionButton:
		control.item_selected.connect(func(_idx: int): panel._debounce_timer.start())
	elif control is ColorPickerButton:
		control.color_changed.connect(func(_c: Color): panel._debounce_timer.start())
