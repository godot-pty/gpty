extends PaneBody
class_name TerminalPane
# gpty Terminal Pane — Control-based node for focus + rendering.

## The tiered agent state changed (emitted from the slow poll). The workspace
## is the only listener: it dispatches the pane contract
## (`PaneBody.on_agent_state_changed`) to this terminal and every pane that
## observes it. The badge is applied through that same hook, so there is one
## path from tracker to display.
signal agent_state_changed(state: String)

const CURSOR_BLINK_INTERVAL = 0.5
const SCROLL_LINES = 3
@export var scroll_lines: int = SCROLL_LINES
const PADDING = 4
const FOCUS_BORDER_WIDTH = 2.0
const BEAM_CURSOR_WIDTH = 2
const UNDERLINE_CURSOR_HEIGHT = 3
const PRINTABLE_ASCII_MIN = 32
const PRINTABLE_ASCII_MAX = 126
## Cell attribute bits, packed by the Rust grid reader (`get_grid_updates_packed`).
## SGR 7 is deliberately absent: `CellInfo::paint_colors` has already swapped
## `fg`/`bg` before packing, so the color arrays are paint-ready and the draw
## pass must not swap them again.
const ATTR_BOLD := 1
const ATTR_ITALIC := 2
const ATTR_UNDERLINE := 4
## Set on the first cell of a wide character; the next cell is its spacer.
const ATTR_WIDE := 16

@export var beam_cursor_width: int = BEAM_CURSOR_WIDTH
@export var underline_cursor_height: int = UNDERLINE_CURSOR_HEIGHT
# No `= <constant>` defaults: a token is not a compile-time constant once the
# palette switches, so `_init` reads the active set and `apply_to_terminal`
# re-pushes these on every settings and appearance change.
@export var focus_border_color: Color
@export var selection_color: Color
@export var scrollback_indicator_color: Color

func _init() -> void:
	focus_border_color = UiPalette.active().TERMINAL_FOCUS
	selection_color = UiPalette.active().SELECTION
	scrollback_indicator_color = UiPalette.active().SCROLLBACK_INDICATOR
var color_scheme_path: String = "":
	set(value):
		color_scheme_path = value
		# Before the child exists there is no palette to set: the start path
		# applies the stored scheme itself.
		if _started:
			_apply_stored_scheme()



## Defaults to this platform's shell: a pane built from nothing must still be
## spawnable, and `/bin/bash` is a path `validate_executable` refuses on Windows
## ("relative executable path") — the reset and the settings default both have to
## agree with what a fresh install would use.
@export var shell_command: String = SettingsManager.default_shell_command()
@export var shell_args: Array = []  # program arguments; ["-c", cmd] = run through shell
@export var shell_env := ""
## The owning workspace's directory. Set by the workspace before this pane
## enters the tree, and deliberately never part of a profile or saved tile:
## a profile is a layout template, while the directory belongs to the
## workspace instance. Empty inherits gpty's own directory.
var workspace_cwd := ""
## The grid a child is born at when its tile cannot hold the minimum grid
## (`_start_child_if_ready`). In every normal tile the fitted pixel size wins:
## these are the pre-layout fallback, never a size the pane keeps.
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
## Selected cells for drawing, as packed (row, first column, last column)
## triples in viewport coordinates. The selection itself lives in the grid —
## alacritty rotates it with the text — so this is a projection of it for the
## current scroll offset, refreshed by `_refresh_selection`.
var _sel_cells: PackedInt32Array = PackedInt32Array()
var _last_grid_gen: int = -1
var _fetch_ms: int = 0
var _draw_ms: int = 0

var _resize_pending: bool = false
var _resize_timer: float = 0.0
## Whether the child exists. False from `_ready` until the first layout pass
## (`_start_child_if_ready`): a fresh pane reports size (0,0) until its
## container sorts, and a grid chosen before that is the 24x80 guess a TUI
## snapshots and keeps.
var _started := false
## Whether the grid has positioned this pane's tile (`mark_tile_laid_out`).
## A tile that was never positioned is only as big as the container's minimum,
## which is not a size to spawn a child at.
var _laid_out := false
## The process frame `_apply_layout` marked the tile on. The container sorts at
## the end of that frame, so the body's size is only final on the next one -
## `_process` uses this to start a pane whose size never changed (a tile that
## clamps the body to its minimum) without ever reading a stale size.
var _laid_out_frame := -1
## Input that arrived before the child did, in order, with its kind
## (`{"line": bool, "text": String}`) and its cap (the inject API's own
## per-call limit). A queued line must go through `send_line` at flush, not
## raw bytes: `StdinInput::Line` is what feeds typed-input concept triggers
## (`engine.rs`), so re-sending it as text would quietly drop them. Flushed
## immediately after `start_shell`.
var _pending_input: Array[Dictionary] = []
var _pending_bytes := 0
const MAX_PENDING_INPUT := 65536
const RESIZE_DEBOUNCE = 0.05
const MIN_COLS = 8
const MIN_ROWS = 3
var _time_since_sync: float = 0.0
var _search_bar: LineEdit
var _search_visible: bool = false
var _search_results: Dictionary = {}  # {count, rows: Array, cols: Array, current: int}
var _search_error: String = ""
var _scope_btn: Button
var _scope_history: bool = false
var _history_results: Array = []  # [[line_num, text], ...]
## The result row the keyboard cursor is on, or -1.
var _history_cursor: int = -1
## Lines persisted for this pane, so an empty result can say whether the pane
## has any history at all.
var _history_stored_lines: int = 0
var _history_panel: ScrollContainer
var _history_list: VBoxContainer
var _search_strip: PanelContainer
var _search_count: Label
var _search_prev: Button
var _search_next: Button
## The return-to-live control, shown while the viewport is scrolled off live
## output. A Button child, so its click is pane chrome even when the child owns
## the mouse.
var _scroll_end_btn: Button
var _sync_interval: float = 1.0 / 60.0
## Title and agent-state reads are FFI calls that allocate and take the grid
## mutex; they change on OSC title / event arrival, not per frame.
const SLOW_POLL_INTERVAL := 0.25
var _slow_poll_timer: float = 0.0

## Accessible-output cadence. Announcements are for a pane the user is NOT
## reading: the grid must be quiet for `A11Y_SETTLE_MS` (a command's output
## arrives over many frames) and the push itself is limited to one per
## `A11Y_PUSH_MS`, so a flood cannot become a speech flood.
const A11Y_SETTLE_MS := 500
const A11Y_PUSH_MS := 1000
## Where the pane's published text nodes live (see `A11y.announce_host`).
var _a11y_host: Control
## When the grid last changed; a push waits for this to settle.
var _a11y_changed_ms: int = 0
var _a11y_push_ms: int = -A11Y_PUSH_MS
## The value last pushed, so an idle pane does not re-push every window.
var _a11y_last_value: String = ""

## Grid work (fetch + repaint) a pane may spend per frame before it starts
## looking at the grid less often, in ms. Under flood the damage covers the
## screen every frame: the fetch packs thousands of cells across the FFI and
## the merge rebuilds a row string per damaged cell — that, not the drawing,
## is what locks the UI thread up. A quarter of a 60 Hz frame, so four panes
## may each be at their limit and still leave the frame mostly free. The pane
## is unreadable at that rate, and the damage tracker coalesces everything
## into the newest grid state, so a slower cadence costs latency and nothing
## else.
const PANE_WORK_BUDGET_MS := 4
## Longest grid cadence the flood back-off may stretch a pane to (~10/s).
const MAX_SYNC_INTERVAL := 0.1
## How long a scroll or search jump keeps the pane exempt from the back-off.
const VIEW_INPUT_GRACE_MS := 500
## Stretch added to `_sync_interval` while a pane is over budget. Grows
## geometrically, recovers as soon as a sync finds nothing new.
var _sync_backoff: float = 0.0
## When the user last changed the view themselves. Autonomous output must not
## push a pane the user is scrolling into the flood cadence: that work is
## bounded by how fast the user scrolls, and it is the one case where the
## repaint rate is visible. Starts far in the past so a fresh pane is never
## exempt.
var _view_input_ms: int = -1_000_000

## Mark a view change the user asked for (wheel, PageUp/Down, search jump).
func _note_view_input():
	_view_input_ms = Time.get_ticks_msec()

## Mouse reporting the child process has enabled, read from the grid
## (`GptyTerminal.get_mouse_mode`). The bit values are the FFI contract with
## `gpty_core::term::MOUSE_MODE_*`: click = DECSET 1000, drag = 1002,
## motion = 1003, SGR encoding = 1006. Zero — the common case — means the pane
## owns mouse events.
const MOUSE_MODE_CLICK := 1
const MOUSE_MODE_DRAG := 2
const MOUSE_MODE_MOTION := 4
const MOUSE_MODE_SGR := 8
## Protocol button codes. 64+ are the wheel; 3 is "no button" in a motion
## report, and the legacy encoding's release code.
const WHEEL_BUTTON_BASE := 64
const NO_BUTTON := 3
## Modifier bits for the encoder (the protocol adds 4/8/16 for shift/alt/ctrl).
const MOD_SHIFT := 1
const MOD_ALT := 2
const MOD_CTRL := 4
## Added to the button code of a motion report (xterm's "32 = motion" bit). It
## is what tells the app a report is the pointer *moving* rather than a button
## going down: without it a drag under 1002 is byte-for-byte a press, and the
## app re-presses at every cell instead of extending a drag.
const MOTION_FLAG := 32
## Highest cell the legacy X10 encoding can address.
const LEGACY_CELL_MAX := 223

## Encode one mouse report for the child process.
##
## `button` is the protocol button code, `cell` is 1-based, `mods` is the
## `MOD_*` bitmask, and `released` selects the release form. `motion` marks a
## pointer-moved report (a drag under 1002, any move under 1003) and adds
## `MOTION_FLAG`; a motion report is never a release. SGR (DECSET 1006)
## is used when the app asked for it; otherwise the legacy X10 form. Returns
## "" when the event cannot be expressed: X10 offsets coordinates by 32 and
## caps them at 223, and reporting a different cell than the one clicked would
## be worse than dropping the event.
static func encode_mouse_report(
	mode: int, released: bool, button: int, cell: Vector2i, mods: int,
	motion := false
) -> String:
	var addends := 0
	if mods & MOD_SHIFT != 0: addends += 4
	if mods & MOD_ALT != 0: addends += 8
	if mods & MOD_CTRL != 0: addends += 16
	if motion: addends += MOTION_FLAG
	if mode & MOUSE_MODE_SGR != 0:
		return "\u001b[<%d;%d;%d%s" % [
			button + addends, cell.x, cell.y, "m" if released else "M"]
	if cell.x > LEGACY_CELL_MAX or cell.y > LEGACY_CELL_MAX:
		return ""
	var cb := (NO_BUTTON if released else button) + addends
	return "\u001b[M%s%s%s" % [char(32 + cb), char(32 + cell.x), char(32 + cell.y)]

## Protocol button code for a Godot mouse button, or -1 when the button is not
## part of the mouse protocol.
static func _protocol_button(button_index: int) -> int:
	match button_index:
		MOUSE_BUTTON_LEFT: return 0
		MOUSE_BUTTON_MIDDLE: return 1
		MOUSE_BUTTON_RIGHT: return 2
		MOUSE_BUTTON_WHEEL_UP: return 64
		MOUSE_BUTTON_WHEEL_DOWN: return 65
		MOUSE_BUTTON_WHEEL_LEFT: return 66
		MOUSE_BUTTON_WHEEL_RIGHT: return 67
	return -1

## Protocol button code for the buttons held during a motion event.
static func _motion_button(button_mask: int) -> int:
	if button_mask & MOUSE_BUTTON_MASK_LEFT != 0: return 0
	if button_mask & MOUSE_BUTTON_MASK_MIDDLE != 0: return 1
	if button_mask & MOUSE_BUTTON_MASK_RIGHT != 0: return 2
	return NO_BUTTON

## Mouse reporting the child process has enabled (the grid's bitmask). A plain
## GDScript method so tests can drive the pane without a live child process.
func _mouse_mode() -> int:
	return _terminal.get_mouse_mode() if _terminal != null else 0

## Take keyboard focus if this pane is in the tree. Synthesized events (tests)
## and events during layout churn reach a pane that is not in the tree yet,
## where grab_focus() is an engine error and does nothing anyway.
func _take_focus():
	if is_inside_tree():
		grab_focus()

## Whether destroying this pane would stop work that is still running.
##
## Two liveness states count, and the status document keeps them apart. While
## the terminal task runs, the answer is its foreground sample: Unix reports
## the PTY's process group, so a background job does not count, and a platform
## that cannot report one (Windows/ConPTY) reads a live shell as possibly
## busy — the alternative is ending work silently. A task that ended can
## still leave its child running (`running: false`, `exit_reason:
## task_ended`): nothing samples a foreground job for that pane any more, and
## teardown still SIGKILLs its process group, so the process is known to be
## alive and the close asks.
##
## The status sample is refreshed by the engine's 200 ms child poll, so a
## command started and closed within that window reads as idle — the close is
## a human action measured in seconds, not a race the dialog has to win.
func has_running_work() -> bool:
	if _terminal == null:
		return false
	return running_work_from_status(JSON.parse_string(str(_terminal.get_status())))

## The pure half of `has_running_work`, so the decision is testable without a
## live child. `running` alone is not the answer: it means "an exit code is
## still to come" — deliberately false for a pane whose task died, so a
## waiter stops waiting — and such a pane can still own a running process.
static func running_work_from_status(status: Variant) -> bool:
	if not (status is Dictionary):
		return false
	if bool(status.get("running", false)):
		var foreground = status.get("foreground_job")
		return foreground == null or bool(foreground)
	return bool(status.get("child_alive", false))

## Commit buffered scrollback before the pane goes away. Output lines are
## queued and written by a background thread, and the process may exit without
## running Rust destructors, so the tail would otherwise be missing from the
## pane's restored scrollback on the next launch.
func _exit_tree():
	# The GptyTerminal child has already left the tree by the time the pane's
	# _exit_tree runs (children are notified first), so no inside-tree test.
	if _terminal != null:
		_terminal.flush_history()


func _ready():
	super._ready()
	# The published text lives on the tile's title bar: a pane body is a leaf in
	# the exposed tree (its own children are not published — measured on the
	# 4.7.2 export, 2026-11-05), while the bar's children are.
	_a11y_host = A11y.announce_host(self)
	# Entering the pane reads the screen that is on it; the tick announces
	# output only while the pane is not focused.
	focus_entered.connect(_on_a11y_focus_entered)
	_terminal = GptyTerminal.new()
	_terminal.name = "GptyTerminal"
	add_child(_terminal)
	# Per-pane env is the user's own store, keyed by this pane's id — final
	# here, because attachment-id renames run before the wrapper enters the
	# tree. The base below was applied by the settings pipeline (the user's
	# global env); the store entry, when present, overlays it.
	var own_env := PaneEnvStore.env_for(attachment_id)
	if own_env != "":
		shell_env = own_env

	_font = _load_font(font_path, "res://fonts/DejaVuSansMono.ttf")
	_font_bold = _load_font(font_bold_path, "res://fonts/DejaVuSansMono-Bold.ttf")
	_font_italic = _load_font(font_italic_path, "res://fonts/DejaVuSansMono-Oblique.ttf")

	_recompute_cell_metrics()

	focus_mode = Control.FOCUS_CLICK
	clip_contents = true

	# Search strip (hidden by default) — anchored to the pane's TOP edge. It sat
	# on the bottom edge and covered the prompt and the last two output rows;
	# the top rows are the oldest visible output, and the prompt stays readable
	# while a search runs.
	_search_strip = PanelContainer.new()
	_search_strip.name = "SearchStrip"
	_search_strip.theme_type_variation = UiTheme.RAISED_PANEL
	_search_strip.visible = false
	_search_strip.anchor_left = 0.0; _search_strip.anchor_right = 1.0
	_search_strip.anchor_top = 0.0; _search_strip.anchor_bottom = 0.0
	_search_strip.offset_left = 6; _search_strip.offset_right = -6
	_search_strip.offset_top = 6; _search_strip.offset_bottom = 42
	add_child(_search_strip)
	var strip_row := HBoxContainer.new()
	strip_row.name = "SearchRow"
	strip_row.add_theme_constant_override("separation", UiTokens.SPACE_SM)
	_search_strip.add_child(strip_row)

	# Search scope toggle (Live grid / persisted history)
	_scope_btn = Button.new()
	_scope_btn.name = "ScopeBtn"
	_scope_btn.text = "Live"
	_scope_btn.tooltip_text = "Search scope: this screen, or the pane's saved history"
	_scope_btn.custom_minimum_size.x = 60
	# A tab stop, and `_on_scope_toggled` hands the field the keyboard back, so
	# reaching the History scope no longer needs the pointer.
	_scope_btn.focus_mode = Control.FOCUS_ALL
	_scope_btn.pressed.connect(_on_scope_toggled)
	strip_row.add_child(_scope_btn)

	_search_bar = LineEdit.new()
	_search_bar.name = "SearchBar"
	_search_bar.placeholder_text = "Search (regex)..."
	_search_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_bar.text_changed.connect(_on_search_text_changed)
	_search_bar.text_submitted.connect(_on_search_submitted)
	_search_bar.gui_input.connect(_on_search_bar_input)
	strip_row.add_child(_search_bar)

	# `n/m`: the highlighted match's ordinal out of the count — `0/m` until the
	# first jump, `Invalid pattern` when the engine refused the expression (the
	# error was set and never shown before).
	_search_count = Label.new()
	_search_count.name = "SearchCount"
	_search_count.custom_minimum_size.x = 72
	_search_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_search_count.add_theme_font_size_override("font_size", UiTokens.FS_CAPTION)
	_search_count.theme_type_variation = UiTheme.MUTED_LABEL
	_search_count.mouse_filter = Control.MOUSE_FILTER_STOP  # the tooltip's hover target
	strip_row.add_child(_search_count)

	# Enter and Shift+Enter step from the field, and focus returns to the field
	# so typing never stops; the declaration is what makes the focus audit count
	# these two as answered rather than as oversights.
	_search_prev = Button.new()
	_search_prev.name = "SearchPrev"
	_search_prev.focus_mode = Control.FOCUS_NONE
	KeyboardFocus.declare_mouse_only(_search_prev, "Enter / Shift+Enter step matches from the field")
	_search_prev.tooltip_text = "Previous match (Shift+Enter)"
	Icons.icon_button(_search_prev, Icons.COLLAPSE, "Previous match")
	_search_prev.pressed.connect(_on_search_step.bind(-1))
	strip_row.add_child(_search_prev)

	_search_next = Button.new()
	_search_next.name = "SearchNext"
	_search_next.focus_mode = Control.FOCUS_NONE
	KeyboardFocus.declare_mouse_only(_search_next, "Enter / Shift+Enter step matches from the field")
	_search_next.tooltip_text = "Next match (Enter)"
	Icons.icon_button(_search_next, Icons.EXPAND, "Next match")
	_search_next.pressed.connect(_on_search_step.bind(1))
	strip_row.add_child(_search_next)

	# History search results panel (below the strip).
	_history_panel = ScrollContainer.new()
	_history_panel.name = "HistoryResults"
	_history_panel.theme_type_variation = UiTheme.RAISED_PANEL
	_history_panel.visible = false
	_history_panel.anchor_left = 0.0; _history_panel.anchor_right = 1.0
	_history_panel.anchor_top = 0.0; _history_panel.anchor_bottom = 0.0
	_history_panel.offset_left = 6; _history_panel.offset_right = -6
	_history_panel.offset_top = 48; _history_panel.offset_bottom = 246
	_history_list = VBoxContainer.new()
	_history_list.name = "Results"
	_history_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_history_panel.add_child(_history_list)
	add_child(_history_panel)

	# The return-to-live control: a real Button child, so Godot's picking
	# delivers its click before `_handle_mouse` reaches the mouse-reporting
	# branch — the arrow stays pane chrome in a TUI that owns the mouse, the
	# search strip's rule. It never takes focus or sends input.
	_scroll_end_btn = Button.new()
	_scroll_end_btn.name = "ScrollToBottom"
	_scroll_end_btn.visible = false
	_scroll_end_btn.anchor_left = 1.0; _scroll_end_btn.anchor_right = 1.0
	_scroll_end_btn.anchor_top = 1.0; _scroll_end_btn.anchor_bottom = 1.0
	_scroll_end_btn.offset_left = -30; _scroll_end_btn.offset_right = -6
	_scroll_end_btn.offset_top = -30; _scroll_end_btn.offset_bottom = -6
	_scroll_end_btn.focus_mode = Control.FOCUS_NONE
	KeyboardFocus.declare_mouse_only(_scroll_end_btn, "PageDown, the wheel or typing return to live output")
	_scroll_end_btn.tooltip_text = "Return to live output"
	Icons.icon_button(_scroll_end_btn, Icons.CARET_DOWN, "Return to live output")
	_scroll_end_btn.pressed.connect(_on_scroll_end_pressed)
	add_child(_scroll_end_btn)

	_start_child_if_ready()

## The grid `size` can show, or `Vector2i.ZERO` when it cannot hold the minimum
## grid. The spawn and the resize debounce share it, so the size a child is born
## at is exactly the size the debounce would settle on, and both refuse the
## same transient layouts.
func _grid_for_size(px: Vector2) -> Vector2i:
	if _cell_w <= 0.0 or _cell_h <= 0.0:
		return Vector2i.ZERO
	var fitted_cols := int((px.x - PADDING) / _cell_w)
	var fitted_rows := int((px.y - PADDING) / _cell_h)
	if fitted_cols < MIN_COLS or fitted_rows < MIN_ROWS:
		return Vector2i.ZERO
	return Vector2i(fitted_cols, fitted_rows)

## Spawn the child at the size the pane is drawn at, once: called from `_ready`
## (a pane that already has a size), from `_on_resize` on the first laid-out
## size (no debounce - the tile has never had another size), from `_process` one
## frame after the layout marked the tile, and it is the only place
## `start_shell` is called.
func _start_child_if_ready() -> void:
	if _started or _terminal == null or _cell_w <= 0.0:
		return
	var fitted := _grid_for_size(size)
	if fitted != Vector2i.ZERO:
		cols = fitted.x
		rows = fitted.y
	elif _laid_out and size.x > 0.0 and size.y > 0.0:
		# A tile too small to hold the minimum grid still gets a shell: born at
		# the pane's configured grid and corrected by the next real size. The
		# debounce refuses to *shrink* to such a size for the same reason, so
		# both paths use one threshold.
		pass
	else:
		# No laid-out size yet (the container has not sized the body, or the
		# grid has never positioned this tile): wait for one.
		return
	_started = true
	_terminal.start_shell(shell_command, rows, cols, shell_env, attachment_id, SettingsManager.cfg_history_lines, JSON.stringify(shell_args), workspace_cwd)
	if color_scheme_path != "":
		_apply_stored_scheme()
	_flush_pending_input()

## `Workspace._apply_layout` gave this pane's tile the rect it is drawn at. The
## container sorts at the end of that frame, so `_process` waits for the next
## one before trusting `size`.
func mark_tile_laid_out() -> void:
	_laid_out = true
	_laid_out_frame = Engine.get_process_frames()

func _on_resize():
	if _terminal == null or _cell_w == 0: return
	if not _started:
		# The first real size a pane gets is the one it is drawn at: start the
		# child there instead of at the pre-layout guess, and arm no debounce -
		# the tile has never held another size, so there is nothing to settle.
		_start_child_if_ready()
		return
	# Transient layout states (collapsed sizes during splits, minimize, or
	# restore) must not collapse the grid into a tiny rewrap. Layout noise
	# computes to 4x2 cells; a real tile (grid layout guarantees >= 1/6 of
	# the window) is never below these floors, so reject anything smaller.
	if _grid_for_size(size) == Vector2i.ZERO:
		return
	_resize_pending = true
	_resize_timer = 0.0

func _notification(what):
	if what == NOTIFICATION_RESIZED: _on_resize()

func _get_layout_state() -> Dictionary:
	var state = super._get_layout_state()
	# `shell_env` is deliberately absent: a saved file must not carry env.
	# The pane's own env lives in PaneEnvStore, keyed by attachment_id.
	state.merge({
		"shell": shell_command, "shell_args": shell_args.duplicate(),
		"rows": rows, "cols": cols,
		# `color_scheme_path` is deliberately absent: a file may not name a
		# scheme (PaneTypes keeps it runtime-only), and on restore the global
		# appearance is applied after the tile anyway, so a saved value never
		# took effect. The pane panel and Settings → Appearance still set it.
		"cursor_shape": cursor_shape, "cursor_blink": cursor_blink,
		"cursor_blink_speed": cursor_blink_speed, "cursor_color": cursor_color,
		"scroll_lines": scroll_lines, "max_fps": max_fps,
		"default_fg": default_fg, "default_bg": default_bg,
		"beam_cursor_width": beam_cursor_width,
		"underline_cursor_height": underline_cursor_height,
	})
	# Only a font the user chose is saved: the bundled default is a `res://`
	# constant the pane already starts with, and a data value may not name one.
	if not font_path.begins_with("res://"):
		state["font_path"] = font_path
	return state

func apply_settings(settings: Dictionary):
	# Restore serialized Color values from JSON round-trips.
	# Layout JSON stores Colors as "(r, g, b, a)" strings.
	_restore_color_strings(settings)
	super.apply_settings(settings)
	if settings.has("shell_args"):
		# Untrusted layout data: sanitize before it reaches a spawn.
		shell_args = PaneTypes.sanitize_shell_args(settings.get("shell_args"))
	# Colors, cursor shape and metrics are all read in _draw(); the grid
	# generation does not move for them, so repaint once here.
	queue_redraw()

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

## Largest scheme file read. A palette is 16 short hex colours; anything past
## this is not a scheme, and the read happens on the GUI thread.
const SCHEME_MAX_BYTES := 1 << 14

## Apply the pane's colour scheme file. The path is data: `TextRead` gates it
## to an absolute regular file and caps the read, so a scheme entry cannot make
## the pane read a device, a FIFO, or a huge file.
func _apply_stored_scheme():
	if _terminal == null: return
	var path = color_scheme_path
	if path == "":
		_terminal.set_palette("")
		return
	var r := TextRead.read_prefix(path, SCHEME_MAX_BYTES)
	if not r.ok:
		_terminal.set_palette("")
		return
	var hex_csv: String = str(r.text).strip_edges().replace("\n", ",").replace("\r", ",").replace(" ", "")
	_terminal.set_palette(hex_csv)

## Load one of the three font faces. `path` is data (a saved or global
## setting) and never reaches a resource loader: `TerminalFonts` reads bytes.
## `fallback` is a bundled `res://` constant and is the only `load()` path.
func _load_font(path: String, fallback: String) -> Font:
	var f := TerminalFonts.load_for(path, fallback)
	f.fixed_size = font_size
	return f

func _recompute_cell_metrics():
	_font.fixed_size = font_size
	_font_bold.fixed_size = font_size
	_font_italic.fixed_size = font_size
	_cell_w = _font.get_char_size('W'.unicode_at(0), font_size).x
	_cell_h = _font.get_height(font_size)
	custom_minimum_size = Vector2(PADDING * _cell_w + PADDING, _cell_h * 2 + PADDING)
	# Glyph metrics changed: existing cells must be redrawn even when the
	# derived rows/cols happen to be unchanged.
	queue_redraw()

func _process(delta):
	if not _started and _laid_out and Engine.get_process_frames() > _laid_out_frame:
		# The container sorts at the end of the frame that marked the tile, so
		# the body's size is final only now. This is also the only path that
		# starts a pane whose size never changes - a tile that cannot hold the
		# minimum grid clamps the body to its minimum, and laying that out
		# raises no resize. A hidden workspace does not process, so this never
		# fires for one.
		_start_child_if_ready()

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
			var fitted := _grid_for_size(size)
			if fitted == Vector2i.ZERO:
				# Size collapsed between event and apply — keep waiting for
				# the stable geometry instead of applying a tiny grid.
				_resize_timer = 0.0
			else:
				_resize_pending = false
				# Recompute from the CURRENT size so the grid applies the
				# final stable geometry, never an intermediate cascade size.
				if fitted.x != cols or fitted.y != rows:
					# Keep the debounce armed until the backend reports it took
					# the size. A refused resize answers false (poisoned grid
					# lock) and a panic in the call never returns at all — the
					# GDScript VM aborts this function at the FFI boundary — so
					# in both cases cols/rows must keep the size the grid really
					# holds, or the pane renders at dimensions the backend never
					# applied and the comparison above never asks again.
					_resize_pending = true
					_resize_timer = 0.0
					if _terminal.resize_grid(fitted.y, fitted.x):
						cols = fitted.x
						rows = fitted.y
						_resize_pending = false

	_time_since_sync += delta
	if _time_since_sync >= _sync_interval + _sync_backoff:
		_time_since_sync = 0.0
		var gen = _terminal.get_grid_generation()
		if gen != _last_grid_gen:
			_last_grid_gen = gen
			_a11y_changed_ms = Time.get_ticks_msec()
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
			# A sync that cost more than the pane's frame budget (measured:
			# this fetch plus the repaint it just queued, which is the
			# previous frame's `_draw_ms`) stretches the next cadence — unless
			# the user is the one driving the view right now.
			var user_driving := Time.get_ticks_msec() - _view_input_ms < VIEW_INPUT_GRACE_MS
			if not user_driving and _fetch_ms + _draw_ms > PANE_WORK_BUDGET_MS:
				_sync_backoff = minf(
					maxf(_sync_backoff * 2.0, _sync_interval),
					maxf(MAX_SYNC_INTERVAL - _sync_interval, 0.0))
			_cursor_visible = true
			_cursor_blink_timer = 0.0
			# The selection is grid-space: a scroll or new output moves its
			# viewport rows without changing the selection itself.
			_refresh_selection()
			_sync_scroll_end_button()
			# Repaint only when the grid actually changed. Every other
			# visual trigger queues its own redraw (cursor blink, selection,
			# search, settings, metric changes), and scroll/resize/palette
			# all bump the generation. Repainting unconditionally here made
			# every visible pane rebuild its full canvas command list every
			# frame — the fetch was damage-tracked, the draw was not.
			queue_redraw()
		else:
			# Nothing new since the last look: the pane has caught up, so walk
			# the cadence back toward the configured interval.
			_sync_backoff = maxf(_sync_backoff * 0.5 - _sync_interval, 0.0)
	_draw_ms = 0  # will be set on next _draw() call
	_slow_poll_timer += delta
	if _slow_poll_timer >= SLOW_POLL_INTERVAL:
		_slow_poll_timer = 0.0
		var t = _terminal.get_title()
		if t != _last_title and t != "":
			_last_title = t
			var display_title = pane_name if pane_name != "" else t
			title_changed.emit(display_title)
		_poll_agent_state()
	# The badge animates every frame; only its state source is throttled.
	_animate_badge(delta)
	_a11y_tick(Time.get_ticks_msec())

# ── Accessible output ──────────────────────────────────────────────────
# A custom-drawn grid has no text element, so its content is exposed as the
# element's value (`A11y.set_text`) and published as text nodes on the tile's
# title bar (`A11y.publish`). `_cell_cache` is damage-tracked and already
# reflects the scroll offset and selection, so the value is the visible screen
# — no second read of the backend, and nothing that can disagree with the draw.

## The drawn grid as plain text: one line per viewport row, right-trimmed,
## trailing empty rows dropped.
func visible_text() -> String:
	var chars: Array = _cell_cache.get("chars", [])
	var lines: Array = []
	for i in chars.size():
		lines.append(str(chars[i]).strip_edges(false, true))
	while not lines.is_empty() and str(lines[lines.size() - 1]) == "":
		lines.remove_at(lines.size() - 1)
	return "\n".join(lines)


## The newest non-empty line — one sentence for a live announcement, never the
## whole buffer.
func _last_output_line() -> String:
	var chars: Array = _cell_cache.get("chars", [])
	for i in range(chars.size() - 1, -1, -1):
		var line := str(chars[i]).strip_edges()
		if line != "":
			return line
	return ""


func _a11y_tick(now: int) -> void:
	if not A11y.enabled():
		return
	if now - _a11y_changed_ms < A11Y_SETTLE_MS:
		return
	if now - _a11y_push_ms < A11Y_PUSH_MS:
		return
	_a11y_push_ms = now
	# The value tracks the screen whether or not the pane is focused: a reader
	# user who is in the pane reads it from the element. Only the *announcement*
	# waits for a background pane — a focused one is being worked in, and the
	# shell already echoes.
	_push_accessibility_value()
	if has_focus():
		return
	A11y.publish(_a11y_host, A11y.LIVE_NAME,
		A11y.one_line(_last_output_line()), A11y.LIVE_POLITE)


func _on_a11y_focus_entered() -> void:
	# Focus asks "what is on this screen now": force the next push even when
	# the text has not changed since the last one.
	_a11y_last_value = ""
	_push_accessibility_value()


func _push_accessibility_value() -> void:
	# Before the first sync the cache has no geometry: a "0 rows" description
	# is worse than none.
	var rows := int(_cell_cache.get("rows", 0))
	var cols := int(_cell_cache.get("cols", 0))
	if rows > 0 and cols > 0:
		accessibility_description = "%d rows, %d columns" % [rows, cols]
	var text := visible_text()
	if text == _a11y_last_value:
		return
	_a11y_last_value = text
	# The visible grid reaches AT as a readable text node (its name is the
	# content); the live line above is the announcement. `set_text` records the
	# value too, for the adapter that maps element values.
	A11y.set_text(self, text)
	A11y.publish(_a11y_host, A11y.TEXT_NAME, text)

# ── Agent-state badge (display only) ───────────────────────────────────
# Mirrors the tiered AgentState tracker from the engine. The badge never
# feeds decisions — it is a projection of what the terminal declared.
var _badge_label: Label = null
var _badge_state := ""
var _badge_anim := 0.0

const BADGE_SPINNER_FRAMES := [Icons.SPINNER, Icons.SPINNER_GAP, Icons.CIRCLE_NOTCH]

## Every agent state's badge, in one table. The glyph is the signal that has to
## survive a colour-vision deficiency, a monochrome screenshot and a screen
## reader, so `failed` and `needs-attention` carry different *shapes*
## (X-circle vs warning triangle) instead of the one warning glyph tinted red
## or amber. `label` is both the hover tooltip and the accessible name: the
## glyph is a private-use codepoint, so without it a screen reader reads out
## nothing usable. `role` names the palette token, resolved when the badge is
## applied, so a light chrome gets its own semantic colours. `idle` is absent
## on purpose - it hides the badge.
const BADGE_STATES := {
	"completed": {"glyph": Icons.CHECK_CIRCLE, "role": "SUCCESS", "label": "Completed"},
	"failed": {"glyph": Icons.X_CIRCLE, "role": "DANGER", "label": "Failed"},
	"needs-attention": {"glyph": Icons.WARNING, "role": "WARNING", "label": "Needs attention"},
	"working": {"glyph": Icons.SPINNER_GAP, "role": "ACCENT", "label": "Working"},
}

## Read the terminal's declared agent state. Called from the slow poll — the
## state changes on event arrival, not per frame, and each read crosses FFI.
##
## `_badge_state` is what this terminal's hook was last *delivered* (see
## `on_agent_state_changed`), so a read only reports a delta against it. The
## one read before any delivery is adopted silently: the workspace's prime
## scan owns the entry delivery, and announcing the spawn state here as well
## told every follower the same value twice.
func _poll_agent_state():
	var state := _terminal.get_agent_state()
	if state == _badge_state:
		return
	var delivered := _badge_state != ""
	_badge_state = state
	if delivered:
		agent_state_changed.emit(state)

## The terminal observes itself: the tiered tracker is this pane's own state.
func agent_state_source_id() -> String:
	return attachment_id

## Contract hook — the badge is applied here, not in the poll, so the badge
## and any custom pane's observation travel the same workspace dispatch. The
## delivery is recorded too: this hook is where the terminal learns what it
## has been told, and `_poll_agent_state` reports only deltas against it.
func on_agent_state_changed(state: String) -> void:
	_badge_state = state
	_apply_badge(state)

func _animate_badge(delta: float):
	_badge_anim += delta
	match _badge_state:
		"working":
			if _badge_label and _badge_label.visible:
				# Spinner illusion: cycle three notch glyphs at ~8 fps.
				var frame := int(_badge_anim * 8.0) % BADGE_SPINNER_FRAMES.size()
				_badge_label.text = BADGE_SPINNER_FRAMES[frame]
		"needs-attention":
			if _badge_label and _badge_label.visible:
				# Pulsing amber at ~1.2 Hz.
				_badge_label.modulate.a = 0.55 + 0.45 * sin(_badge_anim * TAU * 1.2)

func _apply_badge(state: String):
	var label := _resolve_badge()
	if label == null:
		return
	_badge_label = label
	_badge_anim = 0.0
	var spec: Dictionary = BADGE_STATES.get(state, {})
	if spec.is_empty():
		_badge_label.visible = false
		_badge_label.modulate = Color.WHITE
		# A hidden badge must not keep announcing the state it last showed.
		_badge_label.tooltip_text = ""
		_badge_label.accessibility_name = ""
		return
	_badge_label.visible = true
	_badge_label.text = str(spec["glyph"])
	_badge_label.modulate = UiPalette.active().color(str(spec["role"]))
	_badge_label.tooltip_text = str(spec["label"])
	_badge_label.accessibility_name = str(spec["label"])

func _resolve_badge() -> Label:
	var parent := get_parent()
	if parent == null:
		return null
	var tb := parent.get_node_or_null("TitleBar")
	if tb == null:
		return null
	return tb.get_node_or_null("StateBadge")

func _request_cursor_redraw() -> void:
	queue_redraw()

func _grid_offset() -> Vector2:
	# Before the first grid sync the cache is empty; return a neutral
	# offset so mouse handling and hit-testing stay safe.
	if _cell_cache.is_empty():
		return Vector2(2, 2)
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
		# The search strip covers the pane's first two rows, so the indicator
		# moves below it while the strip is open instead of vanishing under it.
		var indicator_row := 2.5 if _search_visible else 0.5
		draw_string(_font, Vector2(off.x + _cell_w * 0.5, off.y + _cell_h * indicator_row),
			"[Scroll: %d/%d lines]" % [so, _terminal.get_history_size()],
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, scrollback_indicator_color)

	# Selection
	if not _sel_cells.is_empty():
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

	# ── Text + underline pass: glyph runs ──
	# Consecutive cells that share font, color, and underline state go out as
	# ONE draw_string. Per-cell calls were the per-frame cost: a full 80×24
	# pane issued up to ~1 900 canvas items per repaint, nearly all of them a
	# single glyph in a color the neighbor already used.
	for r in n_rows:
		var c := 0
		# The cell after a wide character is its zero-width spacer.
		var wide_prev := false
		while c < n_cols:
			var idx: int = r * n_cols + c
			var a: int = attrs[idx]
			var ch: String = chars[r][c]
			if wide_prev or ch == " " or ch == "":
				# The old per-cell pass drew an underline for EVERY cell
				# carrying the attribute, spaces included; a text run stops at
				# a space, so an underlined space inside an underlined phrase
				# is drawn here. A wide character's spacer is not a cell of
				# its own and never was.
				if a & ATTR_UNDERLINE != 0 and not wide_prev:
					var seg_fg: Color = fg_arr[idx] as Color
					var seg_y: float = off.y + r * _cell_h + baseline + 2
					draw_line(Vector2(off.x + c * _cell_w, seg_y),
						Vector2(off.x + (c + 1) * _cell_w, seg_y), seg_fg, 1.0)
				wide_prev = a & ATTR_WIDE != 0
				c += 1
				continue
			var run_font = _font
			if a & ATTR_BOLD != 0: run_font = _font_bold
			if a & ATTR_ITALIC != 0: run_font = _font_italic
			var run_fg: Color = fg_arr[idx] as Color
			var run_underline: bool = a & ATTR_UNDERLINE != 0
			var text := ch
			var wide: bool = a & ATTR_WIDE != 0
			var run_end := c + 1
			# Extend while the next cell matches — and stop on a wide
			# character, whose spacer must not be drawn.
			while run_end < n_cols and not wide:
				var nidx: int = r * n_cols + run_end
				var nch: String = chars[r][run_end]
				if nch == " " or nch == "": break
				var na: int = attrs[nidx]
				var nfg: Color = fg_arr[nidx] as Color
				if nfg != run_fg or (na & ATTR_UNDERLINE != 0) != run_underline: break
				var nfont = _font
				if na & ATTR_BOLD != 0: nfont = _font_bold
				if na & ATTR_ITALIC != 0: nfont = _font_italic
				if nfont != run_font: break
				text += nch
				wide = na & ATTR_WIDE != 0
				run_end += 1
			var x: float = off.x + c * _cell_w
			var y: float = off.y + r * _cell_h + baseline
			draw_string(run_font, Vector2(x, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, run_fg)
			if run_underline:
				draw_line(Vector2(x, y + 2), Vector2(x + text.length() * _cell_w, y + 2), run_fg, 1.0)
			wide_prev = wide
			c = run_end

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
	for i in range(0, _sel_cells.size(), 3):
		var row: int = _sel_cells[i]
		var c0: int = _sel_cells[i + 1]
		var c1: int = _sel_cells[i + 2]
		draw_rect(Rect2(
			off.x + c0 * _cell_w, off.y + row * _cell_h,
			(c1 - c0 + 1) * _cell_w, _cell_h), selection_color)


## Selected text, read from the grid rows: text scrolled out of the viewport
## is still part of the copy.
func _get_selected_text() -> String:
	if _terminal == null:
		return ""
	return _terminal.get_selection_text()

func _gui_input(event):
	if event is InputEventKey and ShortcutManager.is_shortcut(event) and not _is_copy_paste(event):
		return
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		_handle_mouse(event)
	elif event is InputEventKey and event.pressed:
		_handle_keyboard(event)

func _handle_mouse(event: InputEvent):
	# A child process that turned on mouse tracking (DECSET 1000/1002/1003)
	# owns these events: they are its input, not the pane's. Shift bypasses
	# reporting (the xterm convention) so text selection stays reachable, and
	# events the tracking mode does not cover fall through to the pane.
	var mode := _mouse_mode()
	if mode != 0 and not event.shift_pressed:
		if _report_mouse_event(event, mode):
			return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_take_focus(); _selecting = true
				_select_at(_mouse_to_cell(event.position))
			else: _selecting = false; queue_redraw()
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_note_view_input()
			_terminal.scroll_up(scroll_lines)
			_sync_scroll_end_button()
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_note_view_input()
			_terminal.scroll_down(scroll_lines)
			_sync_scroll_end_button()
	if event is InputEventMouseMotion and _selecting:
		_extend_selection_to(_mouse_to_cell(event.position))

## Forward a mouse event to the child process. Returns true when the event
## went to the app — the pane then leaves selection and scrollback alone.
##
## Only the events the enabled tracking mode covers are forwarded: with 1000
## (click) a drag still selects text, with 1002 a drag belongs to the app, and
## 1003 additionally reports motion with no button held.
func _report_mouse_event(event: InputEvent, mode: int) -> bool:
	var tracking := mode & (MOUSE_MODE_CLICK | MOUSE_MODE_DRAG | MOUSE_MODE_MOTION)
	if tracking == 0:
		return false
	var cell := _mouse_to_cell(event.position)
	if cell.x < 0 or cell.y < 0:
		return false
	var mods := 0
	if event.shift_pressed: mods |= MOD_SHIFT
	if event.alt_pressed: mods |= MOD_ALT
	if event.ctrl_pressed: mods |= MOD_CTRL
	var point := cell + Vector2i.ONE  # the protocol is 1-based
	if event is InputEventMouseButton:
		var button := _protocol_button(event.button_index)
		if button < 0:
			return false
		if event.pressed:
			_take_focus()
		if button >= WHEEL_BUTTON_BASE:
			# Wheel events are press-only; their release is swallowed.
			if event.pressed:
				_send_to_term(encode_mouse_report(mode, false, button, point, mods))
			return true
		_send_to_term(encode_mouse_report(mode, not event.pressed, button, point, mods))
		return true
	if event is InputEventMouseMotion:
		var button := _motion_button(event.button_mask)
		var held := button != NO_BUTTON
		if held and mode & (MOUSE_MODE_DRAG | MOUSE_MODE_MOTION) == 0:
			return false
		if not held and mode & MOUSE_MODE_MOTION == 0:
			return false
		_send_to_term(encode_mouse_report(mode, false, button, point, mods, true))
		return true
	return false

## What a paste may carry: everything except C0 controls other than newline and
## tab, and DEL. Both branches of `build_paste_payload` go through this one
## filter, so they cannot drift apart.
##
## The bracketed branch needs it as much as the plain one. A bracketed paste is
## terminated by `ESC[201~`, and that terminator would come from the clipboard,
## so text containing it ends the paste early and everything after it - a
## newline included - arrives as typed input (the "pastejacking" shape, which
## any web page can plant with a copy-to-clipboard button). Dropping ESC removes
## that hole and every other sequence a bracketed application would interpret
## as input. A bare CR goes too: the PTY turns it into Enter. Newlines and tabs
## stay, because a multi-line paste into a shell is a normal thing to want.
static var _paste_control_re: RegEx = null

static func _paste_text(text: String) -> String:
	# Compiled once and cached: this runs on every paste, and the bracketed
	# branch is the common one (readline asks for DECSET 2004 by itself).
	if _paste_control_re == null:
		# C0 minus tab (0x09) and newline (0x0a), plus DEL.
		_paste_control_re = RegEx.create_from_string("[\\x00-\\x08\\x0b-\\x1f\\x7f]")
	return _paste_control_re.sub(text, "", true)

## Payload for a paste, given whether the application asked for bracketed
## paste (DECSET 2004).
##
## With bracketed paste the application receives the filtered text wrapped in
## `ESC[200~`/`ESC[201~` and can insert it as a block instead of treating
## newlines as Enter and control bytes as commands. Without it nothing can
## distinguish pasted text from typing, so the same filter is the whole guard.
static func build_paste_payload(text: String, bracketed: bool) -> String:
	var safe := _paste_text(text)
	if bracketed:
		return "\u001b[200~" + safe + "\u001b[201~"
	return safe

## Whether the child asked for bracketed paste. Split out so a test can
## drive the paste path without a live application on the other end (same
## shape as `_mouse_mode`).
func _is_bracketed_paste() -> bool:
	return _terminal != null and _terminal.is_bracketed_paste()

func _is_copy_paste(event: InputEventKey) -> bool:
	return _is_chord(event, &"term:copy") or _is_chord(event, &"term:paste")

## Whether `event` is a declared pane-local chord. `InputMap.has_action` is
## checked first: `InputEvent.is_action` on a missing action logs an engine
## error, which the GUT gate counts as a failure.
static func _is_chord(event: InputEvent, action: StringName) -> bool:
	return InputMap.has_action(action) and event.is_action(action, true)

func _get_clipboard_text() -> String:
	return DisplayServer.clipboard_get()

func _clear_selection():
	if _terminal != null:
		_terminal.selection_clear()
	_sel_cells = PackedInt32Array()
	queue_redraw()

## Start a selection at a viewport cell. A drag past the grid edge clamps to
## the nearest cell, and a pane with no grid yet ignores the press.
func _select_at(cell: Vector2i):
	var c := _clamp_to_grid(cell)
	if c.x < 0:
		return
	_terminal.selection_start(c.y, c.x)
	_refresh_selection()
	queue_redraw()

## Extend the live selection to a viewport cell.
func _extend_selection_to(cell: Vector2i):
	var c := _clamp_to_grid(cell)
	if c.x < 0:
		return
	_terminal.selection_extend(c.y, c.x)
	_refresh_selection()
	queue_redraw()

## Mouse coordinates outside the grid clamp to the nearest cell; a pane with
## no grid reports (-1, -1).
func _clamp_to_grid(cell: Vector2i) -> Vector2i:
	if cell.x < 0 or _terminal == null or _cell_cache.is_empty():
		return Vector2i(-1, -1)
	return Vector2i(
		clampi(cell.x, 0, int(_cell_cache["cols"]) - 1),
		clampi(cell.y, 0, int(_cell_cache["rows"]) - 1))

## Refresh the highlight's viewport cells from the grid selection. Scrolling
## and new output change these rows without touching the selection itself.
func _refresh_selection():
	if _terminal == null:
		_sel_cells = PackedInt32Array()
		return
	_sel_cells = _terminal.get_selection_cells()

## Return the viewport to live output. Split out so tests can observe when
## input asks for it: an unstarted grid makes the FFI call itself a no-op.
func _snap_to_bottom():
	_terminal.scroll_reset()
	_sync_scroll_end_button()

## The chevron is shown exactly while the view is scrolled off live output.
func _sync_scroll_end_button() -> void:
	if _scroll_end_btn == null or _terminal == null:
		return
	_scroll_end_btn.visible = _terminal.get_scroll_offset() > 0

## One click back to live output. The selection is grid-space, so the jump
## moves the highlight with its text; nothing here clears it.
func _on_scroll_end_pressed() -> void:
	_note_view_input()
	# The reset hides the control itself, so the two cannot disagree.
	_snap_to_bottom()
	_refresh_selection()
	queue_redraw()

func _send_to_term(text: String):
	if not _started:
		_buffer_input(text, false)
		return
	_terminal.send_text(text)

func _send_line_to_term(text: String):
	if not _started:
		_buffer_input(text, true)
		return
	_terminal.send_line(text)

## Hold input for a child that does not exist yet: `inject`/`broadcast` can
## reach a pane in the frame it was created, and writing then would reach a
## terminal with no session and vanish.
func _buffer_input(text: String, as_line: bool):
	var room := MAX_PENDING_INPUT - _pending_bytes
	if room <= 0:
		return
	var chunk := text.left(room)
	_pending_bytes += chunk.length()
	_pending_input.append({"line": as_line, "text": chunk})

func _flush_pending_input():
	if _pending_input.is_empty():
		return
	var queued := _pending_input
	_pending_input = []
	_pending_bytes = 0
	for seg in queued:
		if bool(seg["line"]):
			_terminal.send_line(str(seg["text"]))
		else:
			_terminal.send_text(str(seg["text"]))

func _handle_keyboard(event: InputEventKey):
	# Search bar escape — close search
	if _search_visible and event.keycode == KEY_ESCAPE:
		_close_search()
		accept_event(); return
	# The terminal's chords are declared in ShortcutManager (`term:*`), so this
	# handler and the About list read one spelling. Plain Ctrl+F is deliberately
	# NOT intercepted: it must keep flowing to the PTY (vim/less page-forward)
	# through the keymap/unicode path below — `is_action(…, true)` compares the
	# modifiers exactly, so only the chord reaches this branch. Auto-repeat is
	# consumed but ignored: holding the chord must not flip the bar on every
	# repeat.
	if _is_chord(event, &"term:search"):
		if not event.echo:
			_toggle_search()
		accept_event(); return
	if _is_chord(event, &"term:copy"):
		# Copy-only: always consume the event so it can never fall through
		# to a workspace shortcut. No selection → silent no-op.
		if not event.echo:
			var st = _get_selected_text()
			if st != "":
				DisplayServer.clipboard_set(st)
			_clear_selection()
		accept_event()
		return
	if _is_chord(event, &"term:paste"):
		# Consume repeats as well: falling through would reach _key_to_text
		# and send a literal ^V for every repeat of the chord.
		if not event.echo:
			var cl = _get_clipboard_text()
			if cl != "":
				_send_to_term(build_paste_payload(cl, _is_bracketed_paste()))
		accept_event(); return

	if event.keycode == KEY_PAGEUP:
		_note_view_input()
		_terminal.scroll_up(rows)
		_sync_scroll_end_button(); accept_event(); return
	if event.keycode == KEY_PAGEDOWN:
		_note_view_input()
		_terminal.scroll_down(rows)
		_sync_scroll_end_button(); accept_event(); return
	if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
		_clear_selection()
		_send_line_to_term(""); _snap_to_bottom(); accept_event(); return
	# Only input that reaches the child returns the view to live output: that
	# input is about to echo at the bottom. A bare modifier press (Ctrl or
	# Shift on the way to Shift+Ctrl+C) sends nothing, so a scrolled-back
	# view — and the selection anchored to what it shows — must stay put.
	# Try Rust keymap first (arrows, F-keys, Home, End, etc.)
	var bytes = _terminal.key_to_bytes(event.keycode, event.shift_pressed, event.alt_pressed, event.ctrl_pressed, event.meta_pressed)
	if bytes.size() > 0:
		_clear_selection()
		_snap_to_bottom()
		_send_to_term(bytes.get_string_from_ascii())
		accept_event(); return
	# Fall back to unicode + Ctrl+letter path
	var tx = _key_to_text(event)
	if tx != "":
		_clear_selection()
		_snap_to_bottom()
		if event.alt_pressed and not event.ctrl_pressed:
			tx = char(0x1b) + tx
		_send_to_term(tx)
	accept_event()

func _mouse_to_cell(pos: Vector2) -> Vector2i:
	if _cell_cache.is_empty() or _cell_w == 0:
		return Vector2i(-1, -1)
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
## The strip owns the arrow keys while it is open: letting them through reaches
## `_handle_keyboard`, which sends an arrow sequence to the child and snaps the
## view to the bottom. In the Live scope they are consumed and do nothing; in
## the History scope they move the results cursor.
func _on_search_bar_input(event):
	if not (event is InputEventKey) or not (event as InputEventKey).pressed:
		return
	var key := event as InputEventKey
	if key.keycode in [KEY_UP, KEY_DOWN]:
		if _scope_history:
			_move_history_cursor(-1 if key.keycode == KEY_UP else 1)
		_search_bar.accept_event()
		return
	if key.shift_pressed and key.keycode in [KEY_ENTER, KEY_KP_ENTER]:
		# Shift+Enter steps back; plain Enter stays the LineEdit's own submit.
		_jump_to_match(-1)
		_search_bar.accept_event()
		return
	if key.keycode == KEY_ESCAPE:
		_close_search()
		_search_bar.accept_event()
		return

func _toggle_search():
	_search_visible = not _search_visible
	_search_strip.visible = _search_visible
	# The panel is visible iff the History scope has something to say; a fresh
	# open has no results in the list yet.
	_history_panel.visible = _scope_history and _history_list.get_child_count() > 0
	if _search_visible:
		_search_bar.grab_focus()
		_search_bar.select_all()
	else:
		_search_results.clear()
		_search_error = ""
		_clear_history_results()
		queue_redraw()
	_refresh_search_count()

func _close_search():
	_search_visible = false
	_search_strip.visible = false
	_search_results.clear()
	_search_error = ""
	_clear_history_results()
	queue_redraw()
	_refresh_search_count()
	grab_focus()

## Step through the matches from the strip's two buttons. Focus returns to the
## field so a click never stops the typing.
func _on_search_step(direction: int) -> void:
	_jump_to_match(direction)
	_search_bar.grab_focus()

## `n/m` on the strip: the highlighted ordinal out of the count, `0/m` before
## the first jump, or the engine's refusal. Hidden in the history scope, whose
## own results panel carries the answer.
func _refresh_search_count() -> void:
	var live := _search_visible and not _scope_history
	_search_count.visible = live
	_search_prev.visible = live
	_search_next.visible = live
	if not live:
		return
	if _search_error != "":
		_search_count.text = "Invalid pattern"
		_search_count.theme_type_variation = UiTheme.DANGER_LABEL
		_search_count.tooltip_text = _search_error
		return
	_search_count.theme_type_variation = UiTheme.MUTED_LABEL
	_search_count.tooltip_text = "Enter: next match · Shift+Enter: previous match"
	var count := int(_search_results.get("count", 0))
	var current := int(_search_results.get("current", -1))
	if count == 0:
		_search_count.text = "0/0"
	elif current < 0:
		_search_count.text = "0/%d" % count
	else:
		_search_count.text = "%d/%d" % [current + 1, count]

func _on_search_text_changed(new_text: String):
	_do_search(new_text)

func _on_search_submitted(_new_text: String):
	if _scope_history:
		# Enter copies the row the cursor shows, so the results never need the
		# pointer for the one action they exist for.
		if _history_cursor >= 0:
			_on_history_result_clicked(_history_cursor)
		return
	if _search_results.get("count", 0) == 0:
		return
	if int(_search_results.get("current", -1)) < 0:
		# First Enter after a search: select the first match *past* the
		# current view rather than index 0. Starting from 0 made the first
		# press look like a no-op whenever the opening match was already on
		# screen, which reads as "press Enter twice".
		_search_results["current"] = _first_unseen_match_index() - 1
	_jump_to_match(1)

## Index of the earliest match not already scrolled into view, or 0 when every
## match is visible. Mirrors `_jump_to_match`'s centering arithmetic so the two
## agree on where a match sits relative to the viewport.
func _first_unseen_match_index() -> int:
	var rows_arr: Array = _search_results.get("rows", [])
	var history: int = _terminal.get_history_size()
	var cur_offset: int = _terminal.get_scroll_offset()
	var half: int = int(rows / 2.0)
	for i in rows_arr.size():
		if history - int(rows_arr[i]) + half > cur_offset:
			return i
	return 0

func _on_scope_toggled():
	_scope_history = not _scope_history
	_scope_btn.text = "History" if _scope_history else "Live"
	_search_bar.placeholder_text = "Search (FTS5)..." if _scope_history else "Search (regex)..."
	_search_results.clear()
	_clear_history_results()
	queue_redraw()
	if _search_visible and _search_bar.text != "":
		_do_search(_search_bar.text)
	_refresh_search_count()
	# Toggling is a click on a tab stop; the keyboard goes back to the field so
	# the next keystroke keeps filtering.
	if _search_visible:
		_search_bar.grab_focus()

func _do_search(pattern: String):
	if pattern == "":
		_search_results.clear()
		_search_error = ""
		_clear_history_results()
		queue_redraw()
		_refresh_search_count()
		return
	if _scope_history:
		_do_history_search(pattern)
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
	_refresh_search_count()

func _do_history_search(pattern: String):
	var parsed = JSON.parse_string(str(_terminal.search_history(pattern, 100)))
	if parsed == null or not parsed is Dictionary:
		_search_error = "History search returned an unreadable response"
		_history_results = []
		_history_stored_lines = 0
		_rebuild_history_panel()
		_refresh_search_count()
		return
	_search_error = str(parsed.get("error", ""))
	_history_stored_lines = int(parsed.get("stored_lines", 0))
	_history_results = parsed.get("results", [])
	_rebuild_history_panel()
	_refresh_search_count()

func _rebuild_history_panel():
	_clear_history_list()
	_history_cursor = -1
	if _history_results.is_empty():
		# A failed query, a missing store and a genuine no-match all used to
		# look identical: an empty panel that never even appeared. Say which.
		var msg := _search_error
		if msg == "":
			msg = (
				"No line in this pane's saved history matches."
				if _history_stored_lines > 0
				else "No history stored for this pane yet."
			)
		var lbl := Label.new()
		lbl.text = msg
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.custom_minimum_size = Vector2(0, 24)
		_history_list.add_child(lbl)
	else:
		for entry in _history_results:
			var index := _history_list.get_child_count()
			var line_num: int = int(entry[0])
			var full_text: String = str(entry[1])
			var btn := Button.new()
			btn.text = "line %d: %s" % [line_num, full_text.left(200)]
			btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			# A tab stop with the palette's cursor: Up/Down walk the rows, Enter
			# copies the focused one, and `_history_cursor` holds the same value
			# whichever way the user got there.
			btn.focus_mode = Control.FOCUS_ALL
			btn.toggle_mode = true
			btn.theme_type_variation = UiTheme.SELECTED_ROW
			btn.tooltip_text = "Copy line %d to the clipboard (Enter)" % line_num
			btn.clip_text = true
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			btn.pressed.connect(_on_history_result_clicked.bind(index))
			btn.focus_entered.connect(_on_history_row_focused.bind(index))
			btn.gui_input.connect(_on_history_row_input.bind(btn))
			_history_list.add_child(btn)
	# Shown whenever the History scope is active with a query, so the
	# explanation for an empty list is visible rather than implied.
	_history_panel.visible = _scope_history and _search_visible

## The result rows in list order. The explanation row is a Label, not a row.
func _history_row_buttons() -> Array[Button]:
	var out: Array[Button] = []
	for c in _history_list.get_children():
		if c is Button:
			out.append(c as Button)
	return out

## Drop the list's children now rather than at the end of the frame: a queued
## child still reports as a child, and a cursor move in the same frame would
## count a row that is on its way out.
func _clear_history_list() -> void:
	for c in _history_list.get_children():
		_history_list.remove_child(c)
		c.queue_free()

## Show the cursor. A focused row sets the same cursor, so an arrow-walked list
## and a Tab-walked one cannot disagree about what Enter copies; the pressed
## state of `SELECTED_ROW` is the cursor, which is why the row's focus stylebox
## can stay empty.
func _apply_history_cursor() -> void:
	var rows := _history_row_buttons()
	for i in rows.size():
		rows[i].set_pressed_no_signal(i == _history_cursor)
	if _history_cursor >= 0 and _history_cursor < rows.size():
		_history_panel.ensure_control_visible(rows[_history_cursor])

## Up/Down from the field: move the cursor over the rows, clamped.
func _move_history_cursor(delta: int) -> void:
	var count := _history_row_buttons().size()
	if count == 0:
		return
	_history_cursor = KeyboardFocus.next_index(_history_cursor, count, delta)
	_apply_history_cursor()

func _on_history_row_focused(index: int) -> void:
	_history_cursor = index
	_apply_history_cursor()

## Up/Down on a focused row move focus, and with it the cursor, instead of
## reaching the child process as arrow keys.
func _on_history_row_input(event: InputEvent, row: Button) -> void:
	if not (event is InputEventKey) or not (event as InputEventKey).pressed:
		return
	var key := event as InputEventKey
	var step := 0
	match key.keycode:
		KEY_UP: step = -1
		KEY_DOWN: step = 1
		_: return
	row.accept_event()
	var rows := _history_row_buttons()
	var index := rows.find(row)
	if index < 0:
		return
	var next_i := KeyboardFocus.next_index(index, rows.size(), step)
	if next_i >= 0 and next_i != index:
		rows[next_i].grab_focus()

func _clear_history_results():
	_history_results.clear()
	_history_cursor = -1
	_clear_history_list()
	_history_panel.visible = false

## The one copy path: a click, a focused row's Enter and the field's Enter all
## arrive here, so the toast and the cursor always name the same row.
func _on_history_result_clicked(index: int) -> void:
	if index < 0 or index >= _history_results.size():
		return
	var entry: Array = _history_results[index]
	var line_num := int(entry[0])
	_history_cursor = index
	_apply_history_cursor()
	DisplayServer.clipboard_set(str(entry[1]))
	ToastManager.info("Copied line %d" % line_num)

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
		_note_view_input()
		_terminal.scroll_up(delta)
	elif delta < 0:
		_note_view_input()
		_terminal.scroll_down(-delta)
	_sync_scroll_end_button()
	queue_redraw()
	_refresh_search_count()

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
		# Read at draw time: the palette switches at runtime.
		var p := UiPalette.active()
		var color = p.SEARCH_ACTIVE if i == current else p.SEARCH_HIGHLIGHT
		draw_rect(Rect2(off.x + match_col * _cell_w, off.y + display_row * _cell_h, _cell_w, _cell_h), color)

## The process/grid document the pane API promises, unchanged for terminals.
func status_document() -> Variant:
	if _terminal == null:
		return null
	var parsed = JSON.parse_string(str(_terminal.get_status()))
	return parsed if parsed is Dictionary else null

func _pane_type() -> String:
	return "terminal"

func _default_title() -> String:
	return shell_command.get_file() if shell_command else "terminal"

func _build_pane_settings_ui(panel: Control) -> Control:
	var v = VBoxContainer.new()
	v.add_theme_constant_override("separation", UiTokens.SPACE_MD)

	# ── Shared pane controls ──
	var name_le = LineEdit.new()
	name_le.text = pane_name
	name_le.placeholder_text = _default_title()
	_make_row(v, "Name:", name_le, panel)

	var attach_le = LineEdit.new()
	attach_le.text = attachment_id
	attach_le.placeholder_text = "omp-terminal"
	_make_row(v, "Attachment ID:", attach_le, panel)
	# The one field that needs a sentence: it is how a command, an MCP tool
	# or an agent names this pane, and the old panel showed `pane-…` with no
	# explanation of what would read it.
	var attach_hint = Label.new()
	attach_hint.text = "The id IPC, MCP and agent commands address this pane by."
	attach_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	attach_hint.add_theme_font_size_override("font_size", UiTokens.FS_CAPTION)
	attach_hint.theme_type_variation = UiTheme.MUTED_LABEL
	v.add_child(attach_hint)

	var font_spin = SpinBox.new()
	font_spin.min_value = PaneTypes.FONT_SIZE_MIN; font_spin.max_value = PaneTypes.FONT_SIZE_MAX
	font_spin.value = font_size
	_make_row(v, "Font size:", font_spin, panel)

	v.add_child(HSeparator.new())

	# ── Shell ──
	var env_te = TextEdit.new()
	env_te.text = PaneEnvStore.env_for(attachment_id)
	env_te.placeholder_text = "KEY=value (one per line) — empty inherits the global environment"
	env_te.custom_minimum_size = Vector2(0, 60)
	env_te.add_theme_font_size_override("font_size", UiTokens.FS_CAPTION)
	env_te.text_changed.connect(func(): panel._debounce_timer.start())
	var env_lbl = Label.new()
	env_lbl.text = "Environment:"
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
	var cursor_lbl := _make_row(v, "Cursor color:", cursor_color_btn, panel)
	ColorSwatch.attach(cursor_lbl, cursor_color_btn)

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
	# No Rows/Cols controls: the pixel fit owns the grid. `rows`/`cols` are the
	# fallback for a tile that cannot hold the minimum grid, and they come from
	# a saved layout - not from a control that would look like it resizes the
	# live pane (it used to, and the next resize reverted it).
	var scroll_spin = SpinBox.new()
	scroll_spin.min_value = 1; scroll_spin.max_value = 10
	scroll_spin.value = scroll_lines
	_make_row(v, "Scroll lines:", scroll_spin, panel)

	v.add_child(HSeparator.new())

	# ── Appearance ──
	var fg_btn = ColorPickerButton.new()
	fg_btn.color = default_fg
	var fg_lbl := _make_row(v, "Default FG:", fg_btn, panel)
	ColorSwatch.attach(fg_lbl, fg_btn)

	var bg_btn = ColorPickerButton.new()
	bg_btn.color = default_bg
	var bg_lbl := _make_row(v, "Default BG:", bg_btn, panel)
	ColorSwatch.attach(bg_lbl, bg_btn)

	# Font path picker — stored as metadata to avoid closure capture issues
	var font_btn = Button.new()
	font_btn.text = font_path.get_file()
	font_btn.set_meta("path", font_path)
	font_btn.clip_text = true
	font_btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	font_btn.pressed.connect(func():
		var dlg := AppDialog.picker(panel, "Font", FileDialog.FILE_MODE_OPEN_FILE)
		dlg.current_path = font_btn.get_meta("path", "")
		dlg.add_filter(PaneTypes.font_filter(), "Fonts")
		dlg.file_selected.connect(func(path: String):
			font_btn.set_meta("path", path)
			font_btn.text = path.get_file()
			panel._debounce_timer.start()
			dlg.queue_free())
		dlg.canceled.connect(dlg.queue_free)
		dlg.popup_centered())
	_make_row(v, "Font:", font_btn, panel)

	# Color scheme picker — stored as metadata to avoid closure capture issues
	var scheme_btn = Button.new()
	scheme_btn.text = color_scheme_path.get_file() if color_scheme_path != "" else "(none)"
	scheme_btn.set_meta("path", color_scheme_path)
	scheme_btn.clip_text = true
	scheme_btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	scheme_btn.pressed.connect(func():
		var dlg := AppDialog.picker(panel, "Color scheme", FileDialog.FILE_MODE_OPEN_FILE)
		dlg.current_path = scheme_btn.get_meta("path", "")
		dlg.add_filter("*.txt; *.json; *.csv", "Scheme files")
		dlg.file_selected.connect(func(path: String):
			scheme_btn.set_meta("path", path)
			scheme_btn.text = path.get_file()
			panel._debounce_timer.start()
			dlg.queue_free())
		dlg.canceled.connect(dlg.queue_free)
		dlg.popup_centered())
	_make_row(v, "Color scheme:", scheme_btn, panel)

	# ── Gather func ──
	panel._gather_func = func():
		return {
			"pane_name": name_le.text.strip_edges(),
			"attachment_id": PaneTypes.sanitize_attachment_id(attach_le.text.strip_edges()),
			"font_size": int(font_spin.value),
			"shell_env": env_te.text,
			"cursor_shape": cursor_shape_opt.selected,
			"cursor_blink": cursor_blink_cb.button_pressed,
			"cursor_blink_speed": blink_spin.value,
			"cursor_color": cursor_color_btn.color,
			"beam_cursor_width": int(beam_spin.value),
			"underline_cursor_height": int(uline_spin.value),
			"scroll_lines": int(scroll_spin.value),
			"default_fg": fg_btn.color,
			"default_bg": bg_btn.color,
			"font_path": font_btn.get_meta("path", ""),
			"color_scheme_path": scheme_btn.get_meta("path", ""),
		}

	return v

func _make_row(parent: VBoxContainer, label: String, control: Control, panel: Control) -> Label:
	var hb = HBoxContainer.new()
	var lbl = Label.new(); lbl.text = label
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
	return lbl
