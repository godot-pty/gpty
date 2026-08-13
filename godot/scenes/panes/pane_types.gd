class_name PaneTypes
# Registry of all pane types. Maps _pane_type() discriminator strings
# to display metadata. Consumers access PaneTypes.ALL directly.

static var ALL: Dictionary = {
	"terminal":    {"name": "Terminal",    "icon": ">_", "shortcut": "Ctrl+Shift+N", "label_prefix": "T"},
	"code_viewer": {"name": "Code Viewer", "icon": "{}", "shortcut": "Ctrl+Shift+D", "label_prefix": "C"},
	"file_tree":   {"name": "File Tree",   "icon": "/>", "shortcut": "Ctrl+Shift+T", "label_prefix": "F"},
	"observer":    {"name": "Observer",    "icon": "@",  "shortcut": "Ctrl+Shift+O", "label_prefix": "O"},
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

## Validate a shell command from layout/profile data. Non-strings,
## empty, oversized, or NUL-containing values fall back to `fallback`.
static func sanitize_shell(v, fallback: String) -> String:
	if v is String and v != "" and v.length() <= 1024 and not v.contains("\u0000"):
		return v
	return fallback
