class_name PaneTypes
# Registry of all pane types. Maps _pane_type() discriminator strings
# to display metadata. Consumers access PaneTypes.ALL directly.

static var ALL: Dictionary = {
	"terminal":    {"name": "Terminal",    "icon": ">_", "shortcut": "Ctrl+Shift+N", "label_prefix": "T"},
	"code_viewer": {"name": "Code Viewer", "icon": "{}", "shortcut": "Ctrl+Shift+D", "label_prefix": "C"},
	"file_tree":   {"name": "File Tree",   "icon": "/>", "shortcut": "Ctrl+Shift+T", "label_prefix": "F"},
	"inspector":   {"name": "Inspector",   "icon": "@",  "shortcut": "Ctrl+Shift+O", "label_prefix": "I"},
	"reasoning":   {"name": "Reasoning",   "icon": "?",  "shortcut": "", "label_prefix": "R"},
}

## Clamp a layout value to [lo, hi]. Non-numeric values yield `lo`.
static func clamp_grid_int(v, lo: int, hi: int) -> int:
	if not (v is int or v is float):
		return lo
	return clampi(int(v), lo, hi)

## Ceiling for a stored pane grid. Mirrors the FFI clamp in
## `crates/gpty-gdext/src/lib.rs` (MAX_ROWS/MAX_COLS): several times the
## largest grid a real window produces, and far below anything that would
## allocate an unusable amount of memory for a saved tile.
const PANE_MAX_ROWS := 500
const PANE_MAX_COLS := 2000

## Caps for the Workspace Trust dialog: env lines and value length per tile,
## and total detail lines across the dialog. The content is file-supplied.
const TRUST_MAX_ENV_LINES := 8
const TRUST_MAX_VALUE_LEN := 160
const TRUST_MAX_DETAIL_LINES := 24

## What an untrusted tile would run, one labelled fact per line, for the
## Workspace Trust dialog. Empty when the tile matches the caller's defaults.
##
## Consent is only informed if the user sees the program, arguments, and
## environment entries being approved — the summary sentence alone said "a
## different environment" without saying which. This is attacker-controlled
## file content rendered into a dialog, so it is escaped and capped: every env
## entry keeps its "environment:" label (a value cannot forge a "program:"
## line), and a thousand-entry environment cannot build a dialog taller than
## the screen.
static func untrusted_plan(
	td: Dictionary, default_program: String, default_env: String
) -> PackedStringArray:
	var out := PackedStringArray()
	var settings = td.get("settings", {})
	if not (settings is Dictionary):
		return out
	var program := str(settings.get("command", settings.get("shell", td.get("shell", ""))))
	if program != "" and program != default_program:
		out.append("program: " + _trust_text(program))
	var args = settings.get("shell_args", [])
	if args is Array and not args.is_empty():
		var rendered: Array[String] = []
		for a in args:
			if a is String:
				rendered.append(_trust_text(a))
		if not rendered.is_empty():
			out.append("arguments: " + ", ".join(rendered))
	var env := str(settings.get("shell_env", "")).strip_edges()
	if env != "" and env != default_env.strip_edges():
		var lines := env.split("\n", false)
		var shown := 0
		for line in lines:
			if shown >= TRUST_MAX_ENV_LINES:
				out.append("environment: … %d more line(s)" % (lines.size() - shown))
				break
			out.append("environment: " + _trust_text(str(line)))
			shown += 1
	return out

## Escape a value for display in the trust dialog. Newlines are the dangerous
## case (they would forge an extra dialog line); the rest keeps a hostile value
## readable rather than invisible.
static func _trust_text(text: String) -> String:
	var escaped := (
		text.replace("\\", "\\\\")
			.replace("\n", "\\n")
			.replace("\r", "\\r")
			.replace("\t", "\\t")
			.replace("\u001b", "\\e")
	)
	if escaped.length() > TRUST_MAX_VALUE_LEN:
		escaped = escaped.left(TRUST_MAX_VALUE_LEN) + "…"
	return escaped

## True when a saved tile would spawn something other than the caller's
## defaults: a different program, extra arguments, or a different environment.
## All three change what runs, so a restore gate must look at all three — a
## `shell`-only check missed a tile that shipped `command`, an argv payload
## (`shell_args: ["-c", "…"]`), or an env-only payload.
static func tile_spawns_untrusted(td: Dictionary, default_program: String, default_env: String) -> bool:
	var settings = td.get("settings", {})
	if not (settings is Dictionary):
		return false
	var program := str(settings.get("command", settings.get("shell", td.get("shell", ""))))
	if program != "" and program != default_program:
		return true
	var args = settings.get("shell_args", [])
	if args is Array and not args.is_empty():
		return true
	var env := str(settings.get("shell_env", "")).strip_edges()
	if env != "" and env != default_env.strip_edges():
		return true
	return false

## Validate a saved tile dictionary from layout.json / profiles.
## Returns {} when the tile is unusable; otherwise a dictionary with
## sanitized `settings`, `type_name`, and clamped grid geometry.
static func sanitize_tile(td, grid_size: int = 12) -> Dictionary:
	if not (td is Dictionary):
		return {}
	var settings = td.get("settings", {})
	if not (settings is Dictionary):
		return {}
	settings = migrate_pane_settings(settings)
	var type_name = settings.get("type", "terminal")
	if not (type_name is String) or not ALL.has(type_name):
		return {}
	# Stored grid sizes are untrusted: without a ceiling a crafted tile
	# (`rows: 1000000`) allocates a grid of 10^12 cells at spawn. The Rust FFI
	# clamps again on the way in — this keeps absurd values out of the pane
	# object itself, where the settings dialog and save round-trip would
	# otherwise show them.
	if settings.has("rows"):
		settings["rows"] = clamp_grid_int(settings["rows"], 1, PANE_MAX_ROWS)
	if settings.has("cols"):
		settings["cols"] = clamp_grid_int(settings["cols"], 1, PANE_MAX_COLS)
	var col: int = clamp_grid_int(td.get("col", 0), 0, grid_size - 1)
	var row: int = clamp_grid_int(td.get("row", 0), 0, grid_size - 1)
	var cspan: int = clamp_grid_int(td.get("cspan", grid_size), 1, grid_size)
	var rspan: int = clamp_grid_int(td.get("rspan", grid_size), 1, grid_size)
	cspan = mini(cspan, grid_size - col)
	rspan = mini(rspan, grid_size - row)
	return {
		"settings": settings, "type_name": type_name,
		"col": col, "row": row, "cspan": cspan, "rspan": rspan,
	}

## Convert legacy Observer layouts before type validation. This keeps existing
## user layouts/profiles loadable after Observer becomes two explicit panes.
static func migrate_pane_settings(raw: Dictionary) -> Dictionary:
	var settings: Dictionary = raw.duplicate(true)
	if settings.get("type", "") == "observer":
		settings["type"] = (
			"reasoning" if settings.get("stream", "answer") == "thinking"
			else "inspector"
		)
		settings.erase("stream")
		settings.erase("auto_run")
		settings.erase("label")
		settings.erase("label_name")
	var attachment = settings.get("attachment_id", "")
	settings["attachment_id"] = sanitize_attachment_id(attachment)
	return settings

static var _attachment_id_re: RegEx = null

static func sanitize_attachment_id(v) -> String:
	if not (v is String) or v.length() > 32:
		return ""
	# Compiled once and cached: this runs for every tag and every restored
	# pane, so building the pattern per call was repeated work on the
	# layout-restore and profile-activation paths.
	if _attachment_id_re == null:
		_attachment_id_re = RegEx.new()
		_attachment_id_re.compile("^[a-z][a-z0-9_-]{0,31}$")
	return v if _attachment_id_re.search(v) != null else ""

## Generate a stable public id for panes created without a saved one.
## Matches the attachment_id pattern ([a-z][a-z0-9_-]{0,31}).
static func generate_attachment_id() -> String:
	const CHARS := "abcdefghijklmnopqrstuvwxyz0123456789"
	var s := "pane-"
	for _i in 8:
		s += CHARS[randi() % CHARS.length()]
	return s

## Sanitize a pane-tag list from untrusted layout/profile/IPC data.
## Each tag follows the attachment_id pattern; oversize/foreign values drop.
static func sanitize_tags(raw: Array) -> Array:
	var out: Array = []
	for t in raw:
		if t is String and out.size() < 16:
			var clean := sanitize_attachment_id(t)
			if clean != "" and not out.has(clean):
				out.append(clean)
	return out

## Action commands appended after the pane-type entries in the palette.
const PALETTE_ACTIONS: Array[String] = [
	"close active", "spawn 16 terminals", "settings", "reset layout", "save", "load",
]

## Build the full palette command list: one "new <type>" entry per pane type
## (in ALL iteration order) followed by PALETTE_ACTIONS.
## Single source of truth — workspace.gd and tests both call this.
static func build_palette_commands() -> Array[String]:
	var cmds: Array[String] = []
	for key in ALL:
		cmds.append("new " + ALL[key]["name"].to_lower())
	cmds.append_array(PALETTE_ACTIONS)
	return cmds

## Validate a shell command from layout/profile data. Non-strings,
## empty, oversized, or invalid-Unicode values fall back to `fallback`.
## Godot replaces decoded NUL bytes with U+FFFD before GDScript can inspect
## them, so reject that replacement marker instead of embedding `\u0000`.
static func sanitize_shell(v, fallback: String) -> String:
	if v is String and v != "" and v.length() <= 1024 and not v.contains("\uFFFD"):
		return v
	return fallback


## Sanitize program arguments from untrusted layout/profile data: array of
## non-empty strings ≤4096 chars without U+FFFD, capped at 32 entries.
static func sanitize_shell_args(raw) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	for a in raw:
		if a is String and a != "" and a.length() <= 4096 and not a.contains("\uFFFD"):
			out.append(a)
		if out.size() >= 32:
			break
	return out
