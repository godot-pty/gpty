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

static func sanitize_attachment_id(v) -> String:
	if not (v is String) or v.length() > 32:
		return ""
	var valid := RegEx.new()
	valid.compile("^[a-z][a-z0-9_-]{0,31}$")
	return v if valid.search(v) != null else ""

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
