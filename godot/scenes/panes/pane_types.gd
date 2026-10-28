class_name PaneTypes
# Registry of all pane types. Maps _pane_type() discriminator strings
# to display metadata. Consumers access PaneTypes.ALL directly.

static var ALL: Dictionary = {
	"terminal":    {"name": "Terminal",    "icon": ">_", "shortcut": "Ctrl+Shift+N", "label_prefix": "T"},
	"code_viewer": {"name": "Code Viewer", "icon": "{}", "shortcut": "Ctrl+Shift+D", "label_prefix": "C", "receives_content": true},
	"file_tree":   {"name": "File Tree",   "icon": "/>", "shortcut": "Ctrl+Shift+T", "label_prefix": "F"},
	"inspector":   {"name": "Inspector",   "icon": "@",  "shortcut": "Ctrl+Shift+O", "label_prefix": "I", "receives_content": true},
	"reasoning":   {"name": "Reasoning",   "icon": "?",  "shortcut": "", "label_prefix": "R"},
	"cli_view":    {"name": "CLI View",    "icon": "$_", "shortcut": "", "label_prefix": "V"},
	"wiki":        {"name": "Wiki",        "icon": "[]", "shortcut": "", "label_prefix": "W"},
	"media":       {"name": "Media",       "icon": "|>", "shortcut": "", "label_prefix": "M"},
}

## Pane types whose body accepts a routed concept capture
## (`can_receive_content`). Single source of truth for the concept graph's
## action target picker — adding a receiver pane means flipping this flag
## beside the implementation, not editing a second list.
static func content_receivers() -> Array[String]:
	var out: Array[String] = []
	for key in ALL:
		if ALL[key].get("receives_content", false) == true:
			out.append(key)
	return out

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

## Caps for the Workspace Trust dialog: value length and total detail lines
## across the dialog. The content is file-supplied.
const TRUST_MAX_VALUE_LEN := 160
const TRUST_MAX_DETAIL_LINES := 24

## What an untrusted tile would run, one labelled fact per line, for the
## Workspace Trust dialog. Empty when the tile matches the caller's defaults.
##
## Consent is only informed if the user sees the program and arguments being
## approved — the summary sentence alone said "a different program" without
## saying which. Environment is deliberately absent: a file cannot supply env
## (restore strips `shell_env` with a notice; per-pane env is the user's own
## `PaneEnvStore`, written by the pane settings UI), so there is nothing to
## show. This is attacker-controlled file content rendered into a dialog, so
## it is escaped and capped.
static func untrusted_plan(td: Dictionary, default_program: String) -> PackedStringArray:
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
## defaults: a different program, or extra arguments. Both change what runs,
## so a restore gate must look at both — a `shell`-only check missed a tile
## that shipped `command` or an argv payload (`shell_args: ["-c", "…"]`).
## Environment is not a file decision: restore strips a tile's `shell_env`
## with a notice and never lets it reach a child, so there is no env clause
## here to trigger.
static func tile_spawns_untrusted(td: Dictionary, default_program: String) -> bool:
	var settings = td.get("settings", {})
	if not (settings is Dictionary):
		return false
	var program := str(settings.get("command", settings.get("shell", td.get("shell", ""))))
	if program != "" and program != default_program:
		return true
	var args = settings.get("shell_args", [])
	if args is Array and not args.is_empty():
		return true
	return false

## The canonical identity of what a tile would run: program + argv joined
## with U+001F. The consent store (TrustedStore) keys approvals on this, so
## a trust approval covers the exact spawn plan — the same derivation the
## gate above uses (`command` > `shell` > tile's legacy `shell`, plus
## `shell_args`), kept adjacent so the two can never drift. Empty when the
## tile names nothing to run.
static func tile_plan_key(td: Dictionary) -> String:
	var settings = td.get("settings", {})
	if not (settings is Dictionary):
		return ""
	var program := str(settings.get("command", settings.get("shell", td.get("shell", ""))))
	var parts: Array[String] = []
	if program != "":
		parts.append(program)
	var args = settings.get("shell_args", [])
	if args is Array:
		for a in args:
			if a is String:
				parts.append(a)
	if parts.is_empty():
		return ""
	return "\u001f".join(parts)

## Validate a saved tile dictionary from layout.json / profiles.
## Returns {} when the tile is unusable; otherwise a dictionary with
## sanitized `settings`, `type_name`, and clamped grid geometry.
## Layout grid, in abstract units: a pane's geometry is `col/row/cspan/rspan`
## in these units, and this is the ONLY definition — `TerminalManager`'s drag
## math, `workspace.gd`'s `_apply_layout`, and the sanitizer below all read it.
## A second copy once drifted from its twin and silently clamped every restored
## pane to a sliver (the layout divided by one unit while the tiles were in
## another), so nothing else may define its own.
const GRID := 60
## Smallest pane, in grid units (a tenth of the grid ≈ 100 px at 1000 px).
const MIN_TILE := 6

static func sanitize_tile(td, grid_size: int = GRID) -> Dictionary:
	if not (td is Dictionary):
		return {}
	var settings = td.get("settings", {})
	if not (settings is Dictionary):
		return {}
	settings = migrate_pane_settings(settings)
	var type_name = settings.get("type", "terminal")
	if not (type_name is String) or not ALL.has(type_name):
		return {}
	# A file's settings go through the closed per-type table: unknown keys,
	# wrong-typed values and app-only keys (env, scheme paths) are dropped and
	# reported, instead of reaching `PaneBody.apply_settings`'s property path.
	# The spawn keys are preserved verbatim for `_restore_into`, which validates
	# them itself (the trust gate + sanitize_shell); rows/cols are clamped by
	# the table's int rules now that only a terminal accepts them.
	var filtered := sanitize_settings(type_name, settings, SOURCE_FILE)
	var kept: Dictionary = filtered["settings"]
	# A spawn key is not a property: the restore path consumes it (and reports
	# its own drop for `shell_env`), so it must not count as an ignored setting.
	var dropped := PackedStringArray()
	for key in filtered["dropped"]:
		if not SPAWN_KEYS.has(key):
			dropped.append(key)
	for key in SPAWN_KEYS:
		if settings.has(key) and not kept.has(key):
			kept[key] = settings[key]
	var col: int = clamp_grid_int(td.get("col", 0), 0, grid_size - 1)
	var row: int = clamp_grid_int(td.get("row", 0), 0, grid_size - 1)
	var cspan: int = clamp_grid_int(td.get("cspan", grid_size), 1, grid_size)
	var rspan: int = clamp_grid_int(td.get("rspan", grid_size), 1, grid_size)
	cspan = mini(cspan, grid_size - col)
	rspan = mini(rspan, grid_size - row)
	return {
		"settings": kept, "type_name": type_name,
		"col": col, "row": row, "cspan": cspan, "rspan": rspan,
		"dropped": dropped,
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
	"close active", "spawn 16 terminals", "settings", "close all", "save", "load",
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


## Arguments that make `program` run `command` and exit.
##
## `cmd.exe` — the Windows default `cfg_shell_command` — spells the "run this
## and exit" flag `/c` and rejects the POSIX `-c`; every other shell gpty
## targets takes `-c`. The pane API runs commands through the user's configured
## shell, so this is the one place that difference lives.
static func shell_run_args(program: String, command: String) -> Array:
	var base := program.get_file().to_lower()
	if base == "cmd" or base == "cmd.exe":
		return ["/c", command]
	return ["-c", command]


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

# ── Pane settings a file may set ───────────────────────────────────────
#
# A tile's `settings` dictionary is attacker-controlled: it comes from
# workspaces.json, profiles.json and the JSON a plugin ships. It used to reach
# every exported property through `PaneBody._set_typed` (any String/int/float/
# bool), so a file could set `font_bold_path` and the next font reload ran
# `load()` on it - a `.tres` with an embedded script executes during load(),
# which Workspace Trust never saw because a font is not a spawn plan.
#
# The vocabulary is now closed per pane type. A key that is not in its table
# is dropped (and counted for the restore notice), a known key is coerced and
# clamped by its rule, and a rule marked `file: false` is refused to files: the
# user's own settings, the pane panel and the app's spawn options still set it
# through SOURCE_RUNTIME. The values are the pane's *saved* vocabulary
# (`_get_layout_state`) plus what the app itself applies; a new pane property
# meant to survive a layout must be added here, and
# `test_pane_settings.gd` fails when a saved key is not accepted.

const SOURCE_FILE := 0     ## workspaces.json / profiles.json / plugin JSON
const SOURCE_RUNTIME := 1  ## global settings, pane panel, spawn options

## The font-size range, shared by the settings rule and the pane panel's
## spinbox so the two cannot disagree.
const FONT_SIZE_MIN := 8
const FONT_SIZE_MAX := 32

## Shared by every pane type.
const COMMON_SETTINGS := {
	"type": {"kind": "text", "max": 32},          # discriminator; read, never set
	"pane_name": {"kind": "text", "max": 128},
	"attachment_id": {"kind": "id"},
	"tags": {"kind": "tags"},
	"font_size": {"kind": "int", "min": FONT_SIZE_MIN, "max": FONT_SIZE_MAX},
}

## Extensions the terminal font loader will read. Anything else - notably
## `.tres`/`.res`, which can carry a script - falls back to the bundled font.
const FONT_EXTENSIONS := ["ttf", "otf", "ttc", "woff", "woff2"]

## Keys `Workspace._restore_into` consumes itself instead of applying them as
## properties: the spawn program, its argv source and the env block it strips
## with its own notice. Kept verbatim by `sanitize_tile`; each is validated
## where it is used (the trust gate + `sanitize_shell`).
const SPAWN_KEYS := ["shell", "command", "shell_env"]

const TERMINAL_SETTINGS := {
	"rows": {"kind": "int", "min": 1, "max": PANE_MAX_ROWS},
	"cols": {"kind": "int", "min": 1, "max": PANE_MAX_COLS},
	"shell_args": {"kind": "argv"},
	"shell_command": {"kind": "shell", "file": false},
	"shell_env": {"kind": "text", "max": 65536, "file": false},
	"font_path": {"kind": "font_path"},
	# A file must not name a scheme: the read itself is capped and harmless,
	# but appearance paths are the user's, not a shared layout's. The pane
	# panel and the global setting (runtime) still set it.
	"color_scheme_path": {"kind": "scheme_path", "file": false},
	"cursor_shape": {"kind": "int", "min": 0, "max": 2},
	"cursor_blink": {"kind": "bool"},
	"cursor_blink_speed": {"kind": "float", "min": 0.1, "max": 2.0},
	"cursor_color": {"kind": "color"},
	"scroll_lines": {"kind": "int", "min": 1, "max": 10},
	"max_fps": {"kind": "int", "min": 0, "max": 240},
	"default_fg": {"kind": "color"},
	"default_bg": {"kind": "color"},
	"beam_cursor_width": {"kind": "int", "min": 1, "max": 8},
	"underline_cursor_height": {"kind": "int", "min": 1, "max": 8},
	"focus_border_color": {"kind": "color", "file": false},
	"selection_color": {"kind": "color", "file": false},
	"scrollback_indicator_color": {"kind": "color", "file": false},
}

const CODE_VIEWER_SETTINGS := {
	"file_path": {"kind": "text", "max": 4096},
	"language": {"kind": "text", "max": 64},
	"view_mode": {"kind": "text", "max": 32},
}

const FILE_TREE_SETTINGS := {
	"root_path": {"kind": "text", "max": 4096},
	"open_in": {"kind": "text", "max": 32},
}

const INSPECTOR_SETTINGS := {
	"backend": {"kind": "text", "max": 32},
	"command": {"kind": "argv"},
	"auto_run": {"kind": "bool"},
	"accept_concept_captures": {"kind": "bool"},
	"system_prompt": {"kind": "text", "max": 65536},
	"model": {"kind": "text", "max": 128},
}

const REASONING_SETTINGS := {
	"source_attachment_id": {"kind": "id"},
}

const CLI_VIEW_SETTINGS := {
	"command": {"kind": "shell"},
	"shell_args": {"kind": "argv"},
}

const WIKI_SETTINGS := {
	"vault_path": {"kind": "text", "max": 4096},
	"view_mode": {"kind": "text", "max": 32},
	"open_note": {"kind": "text", "max": 512},
	"graph": {"kind": "bool"},
}

const MEDIA_SETTINGS := {
	"file_path": {"kind": "text", "max": 4096},
	"volume_db": {"kind": "float", "min": -40.0, "max": 6.0},
	"muted": {"kind": "bool"},
	"loop": {"kind": "bool"},
}

const PANE_SETTINGS := {
	"terminal": TERMINAL_SETTINGS,
	"code_viewer": CODE_VIEWER_SETTINGS,
	"file_tree": FILE_TREE_SETTINGS,
	"inspector": INSPECTOR_SETTINGS,
	"reasoning": REASONING_SETTINGS,
	"cli_view": CLI_VIEW_SETTINGS,
	"wiki": WIKI_SETTINGS,
	"media": MEDIA_SETTINGS,
}

## The closed key table for one pane type (common + its own).
static func settings_schema(type_name: String) -> Dictionary:
	var schema: Dictionary = COMMON_SETTINGS.duplicate()
	var own = PANE_SETTINGS.get(type_name)
	if own is Dictionary:
		schema.merge(own)
	return schema

## Filter a settings dictionary through `type_name`'s table.
##
## Returns `{"settings": Dictionary, "dropped": PackedStringArray}`. `dropped`
## names every key that was refused - unknown to the type, wrong-typed, out of
## range, or reserved to the app when `source` is SOURCE_FILE - so the caller
## can tell the user once per load instead of silently changing their pane.
static func sanitize_settings(type_name: String, raw: Dictionary, source: int = SOURCE_RUNTIME) -> Dictionary:
	var schema := settings_schema(type_name)
	var out := {}
	var dropped := PackedStringArray()
	for key in raw:
		if not (key is String):
			continue
		var rule = schema.get(key)
		if not (rule is Dictionary):
			dropped.append(str(key))
			continue
		if source == SOURCE_FILE and rule.get("file", true) == false:
			dropped.append(key)
			continue
		var value = _value_for_rule(rule, raw[key])
		if value == null:
			dropped.append(key)
			continue
		out[key] = value
	return {"settings": out, "dropped": dropped}

## Coerce one value through its rule, or null when it must be dropped.
static func _value_for_rule(rule: Dictionary, v) -> Variant:
	match str(rule.get("kind", "")):
		"text":
			if not (v is String):
				return null
			var text: String = v
			if text.length() > int(rule.get("max", 128)) or text.contains("\uFFFD"):
				return null
			return text
		"int":
			if not (v is int or v is float):
				return null
			var f := float(v)
			if not is_finite(f):
				return null
			var lo := int(rule.get("min", 0))
			var hi := int(rule.get("max", lo))
			return clampi(int(clampf(f, float(lo), float(hi))), lo, hi)
		"float":
			if not (v is int or v is float):
				return null
			var f := float(v)
			if not is_finite(f):
				return null
			return clampf(f, float(rule.get("min", 0.0)), float(rule.get("max", 0.0)))
		"bool":
			return v if v is bool else null
		"color":
			# Colors saved to JSON are "(r, g, b, a)" strings; the pane parses
			# them (`TerminalPane._restore_color_strings`). Both forms pass.
			if v is Color:
				return v
			if v is String and _is_color_string(v):
				return v
			return null
		"id":
			if not (v is String):
				return null
			if v == "":
				return ""  # `ensure_attachment_id` fills it
			var clean := sanitize_attachment_id(v)
			return clean if clean != "" else null
		"tags":
			return sanitize_tags(v) if v is Array else null
		"argv":
			return sanitize_shell_args(v) if v is Array else null
		"shell":
			if not (v is String):
				return null
			var program := sanitize_shell(v, "")
			return program if program != "" else null
		"font_path":
			if not (v is String):
				return null
			var path: String = v
			if path == "":
				return ""
			if path.length() > 4096 or path.contains("\uFFFD"):
				return null
			# `res://` and `user://` are "absolute" to Godot, but they are
			# virtual: a data value may only name a real filesystem file. The
			# bundled fonts are `res://` constants no file ever supplies.
			if path.begins_with("res://") or path.begins_with("user://"):
				return null
			if not path.is_absolute_path() or not font_extension_ok(path):
				return null
			return path
		"scheme_path":
			if not (v is String):
				return null
			var scheme: String = v
			if scheme.length() > 4096 or scheme.contains("\uFFFD"):
				return null
			return scheme
	return null

static func _is_color_string(v: String) -> bool:
	var s := v.strip_edges()
	if not (s.begins_with("(") and s.ends_with(")")):
		return false
	var parts := s.substr(1, s.length() - 2).split(",", false)
	if parts.size() < 3:
		return false
	for part in parts:
		if not part.strip_edges().is_valid_float():
			return false
	return true

## True when `path` names a font file the loader may read (by extension).
static func font_extension_ok(path: String) -> bool:
	return FONT_EXTENSIONS.has(path.get_extension().to_lower())

## A `FileDialog` filter string for every extension the font loader reads, so
## the pickers and the loader cannot drift apart.
static func font_filter() -> String:
	var parts := PackedStringArray()
	for ext in FONT_EXTENSIONS:
		parts.append("*." + ext)
	return ", ".join(parts)
