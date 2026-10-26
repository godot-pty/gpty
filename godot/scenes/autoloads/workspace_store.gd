extends BasePersistenceManager
# WorkspaceStore — persists named workspaces (tab sets) to user://workspaces.json.
#
# Replaces LayoutManager: one layout file became N named pane sets.
# import_legacy_layout() is a one-shot migration reader for the old
# user://layout.json format.

const FILE = "user://workspaces.json"
const LEGACY_FILE = "user://layout.json"
const MAX_NAME_LENGTH = 32
const MAX_CWD_LENGTH = 4096


func load() -> Dictionary:
	var d = _read_file(FILE)
	if d.is_empty():
		return {"active": 0, "workspaces": []}
	var raw: Array = _as_array(d, "workspaces", [])
	var workspaces: Array[Dictionary] = []
	for item in raw:
		if not (item is Dictionary):
			continue
		workspaces.append({
			"name": sanitize_name(str(_as_string(item, "name", ""))),
			# The directory is a workspace instance's own setting. Empty
			# means "inherit gpty's directory", which is also what every
			# workspace did before this field existed.
			"cwd": sanitize_cwd(str(_as_string(item, "cwd", ""))),
			# A workspace whose `layout` is not a list used to abort the whole
			# load (a typed parameter rejects it), taking every other
			# workspace with it.
			"layout": _typed_tiles(_as_array(item, "layout", [])),
		})
	# An empty list would make the clamp range (0, -1), which is itself a
	# GDScript error; an empty store is a valid store.
	var active: int = clampi(_as_int(d, "active", 0), 0, maxi(workspaces.size() - 1, 0))
	return {"active": active, "workspaces": workspaces}


func save(active: int, workspaces: Array[Dictionary]):
	var out: Array[Dictionary] = []
	for ws in workspaces:
		out.append({
			"name": sanitize_name(str(_as_string(ws, "name", ""))),
			"cwd": sanitize_cwd(str(_as_string(ws, "cwd", ""))),
			"layout": _typed_tiles(_as_array(ws, "layout", [])),
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
	return _typed_tiles(_as_array(d, "tiles", []))


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


## A workspace name no name in `taken` uses yet: `base` when free, else
## " 2", " 3" … The suffix is applied *after* the length cap, because
## sanitizing the composed string would slice a 32-character base's suffix off
## and hand back a name that is taken again - the loop would never end.
func unique_name(base: String, taken: Dictionary) -> String:
	var clean := sanitize_name(base)
	var candidate := clean
	var n := 2
	while taken.has(candidate):
		var suffix := " %d" % n
		candidate = sanitize_name(clean.left(MAX_NAME_LENGTH - suffix.length()).strip_edges() + suffix)
		n += 1
	return candidate


## A workspace directory is accepted only as an absolute, bounded string with
## no control bytes. It is not a spawn surface — the pane layer re-checks that
## it exists before handing it to the PTY — but a hand-editable store must not
## smuggle arbitrary bytes across the FFI.
func sanitize_cwd(raw: String) -> String:
	var out := raw.strip_edges()
	if out == "" or out.length() > MAX_CWD_LENGTH:
		return ""
	for ch in out:
		var code := ch.unicode_at(0)
		if code < 32 or code == 127:
			return ""
	if not out.is_absolute_path():
		return ""
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
