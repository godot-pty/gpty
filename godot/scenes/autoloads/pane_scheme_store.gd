extends BasePersistenceManager
# PaneSchemeStore — the user's own per-pane colour scheme, keyed by
# attachment_id.
#
# `user://pane_schemes.json` is the ONLY place a pane's own scheme lives, and
# only the pane settings UI writes it (the workspace's settings_applied handler
# is the single write path). A profile, a layout or a plugin tile never carries
# one: the settings table marks `pane_scheme` `file: false` and `ipc: false`,
# so a downloaded file cannot restyle a pane and an agent cannot either. The
# global dark/light pair is `SettingsManager`'s; this store is the pane's own
# exception to it.
#
# Keyed by attachment_id alone, like `PaneEnvStore`: the look belongs to the
# pane's role, so a builtin such as `agent-terminal` that reappears in another
# workspace keeps the scheme the user gave it - the same argument as env, and
# unlike the directory store, which names a repository.
#
# The file is still hand-editable, so the loader treats it like every other
# store: typed reads, an id-pattern key check, and size caps — a bad entry
# costs itself, not the file.

const SCHEME_FILE := "user://pane_schemes.json"

## Caps for hand-edited file content. The window's live pane ceiling is 96, so
## 128 entries covers pane churn between workspace deletions.
const MAX_ENTRIES := 128
const MAX_PATH_CHARS := 4096

var _schemes: Dictionary = {}

func _on_init():
	reload()

func reload():
	_schemes = {}
	var d = _read_file(SCHEME_FILE)
	for key in d:
		if not (key is String) or not _valid_id(key):
			continue
		if _schemes.size() >= MAX_ENTRIES:
			break
		var value := _as_string(d, key, "")
		if value == "" or value.length() > MAX_PATH_CHARS:
			continue
		_schemes[key] = value

## The pane's own scheme path, or "" when it follows the global pair.
func scheme_for(id: String) -> String:
	return str(_schemes.get(id, ""))

func has_scheme(id: String) -> bool:
	return _schemes.has(id)

## The pane settings UI's write path. An empty value removes the entry, so a
## cleared scheme falls back to the global pair. A path over the cap is
## refused, never truncated: a cut path names nothing.
func set_scheme(id: String, path: String) -> void:
	if not _valid_id(id):
		return
	var trimmed := path.strip_edges()
	if trimmed == "":
		remove_scheme(id)
		return
	if trimmed.length() > MAX_PATH_CHARS:
		return
	if str(_schemes.get(id, "")) == trimmed:
		return  # the debounced panel re-applies on every row edit
	_schemes[id] = trimmed
	_write_file(SCHEME_FILE, _schemes)

func remove_scheme(id: String) -> void:
	if _schemes.has(id):
		_schemes.erase(id)
		_write_file(SCHEME_FILE, _schemes)

## attachment_id shape — the same `[a-z][a-z0-9_-]{0,31}` the pane sanitizer
## enforces, so an entry can never outlive the ids the panes actually carry.
static func _valid_id(id: String) -> bool:
	var re := RegEx.create_from_string("^[a-z][a-z0-9_-]{0,31}$")
	return re.search(id) != null
