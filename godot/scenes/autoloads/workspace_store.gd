extends BasePersistenceManager
# WorkspaceStore — persists named workspaces (tab sets) to user://workspaces.json.
#
# Replaces LayoutManager: one layout file became N named pane sets.
# import_legacy_layout() is a one-shot migration reader for the old
# user://layout.json format.

const FILE = "user://workspaces.json"
const LEGACY_FILE = "user://layout.json"
const MAX_NAME_LENGTH = 32


func load() -> Dictionary:
	var d = _read_file(FILE)
	if d.is_empty():
		return {"active": 0, "workspaces": []}
	var raw: Array = d.get("workspaces", [])
	var workspaces: Array[Dictionary] = []
	for item in raw:
		if not (item is Dictionary):
			continue
		workspaces.append({
			"name": sanitize_name(str(item.get("name", ""))),
			"layout": _typed_tiles(item.get("layout", [])),
		})
	var active: int = clampi(int(d.get("active", 0)), 0, workspaces.size() - 1)
	return {"active": active, "workspaces": workspaces}


func save(active: int, workspaces: Array[Dictionary]):
	var out: Array[Dictionary] = []
	for ws in workspaces:
		out.append({
			"name": sanitize_name(str(ws.get("name", ""))),
			"layout": _typed_tiles(ws.get("layout", [])),
		})
	var d = {
		"version": 1,
		"active": clampi(active, 0, out.size() - 1),
		"workspaces": out,
	}
	_write_file(FILE, d)


func import_legacy_layout() -> Array[Dictionary]:
	var d = _read_file(LEGACY_FILE)
	if d.is_empty():
		return []
	return _typed_tiles(d.get("tiles", []))


func sanitize_name(raw: String) -> String:
	var out := raw
	var cleaned := ""
	for ch in out:
		# Drop control characters (incl. newlines injected via JSON).
		if ch.unicode_at(0) < 32:
			continue
		cleaned += ch
	out = cleaned.strip_edges().left(MAX_NAME_LENGTH)
	if out == "":
		out = "Workspace"
	return out


func _typed_tiles(raw: Array) -> Array[Dictionary]:
	# JSON.parse returns untyped Arrays; typed assignment fails at runtime.
	# Build element-by-element. Tiles stay dicts — PaneTypes.sanitize_tile
	# still validates them at restore time (untrusted input).
	var result: Array[Dictionary] = []
	for item in raw:
		if item is Dictionary:
			result.append(item)
	return result
